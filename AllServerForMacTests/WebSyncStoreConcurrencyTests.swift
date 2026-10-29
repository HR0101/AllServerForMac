import Foundation
import XCTest
@testable import AllServerForMac

/// `WebSyncStore.merge` の通知送出と `WatchStateStore` の受け取りが、
/// メインスレッドと `websync` キューを互いに待たせないことの確認（Issue #40）。
final class WebSyncStoreConcurrencyTests: XCTestCase {
  /// メインスレッドをわざと塞いでおく。`.main` のオブザーバーがあっても、
  /// ワーカー側の merge は完了を待たずに返らなければならない。
  /// 修正前の挙動は、固まらずにタイムアウトで失敗として検出する。
  @MainActor
  func testMergeDoesNotWaitForMainThreadObserver() async {
    let store = makeStore()
    let notified = expectation(description: "外部変更の通知が届く")
    let observer = NotificationCenter.default.addObserver(
      forName: WebSyncStore.didChangeExternallyNotification, object: nil, queue: .main
    ) { _ in notified.fulfill() }
    defer { NotificationCenter.default.removeObserver(observer) }

    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = store.merge(incoming: WebSyncStore.SyncDoc())
      finished.signal()
    }
    XCTAssertEqual(finished.wait(timeout: .now() + 2), .success,
                   "メインスレッドが通知を受けられない間も merge は返らなければならない")
    await fulfillment(of: [notified], timeout: 3)
  }

  /// 通知を受けた側は、別スレッドから保管庫を読めなければならない。
  /// 待ち時間に上限を付け、通知が保管庫のシリアルキューの内側で送られていれば検出する。
  @MainActor
  func testNotificationIsDeliveredAfterReleasingStoreQueue() async {
    let store = makeStore()
    let notified = expectation(description: "オブザーバーが確定済みの状態を読める")
    let id = UUID().uuidString
    let observer = NotificationCenter.default.addObserver(
      forName: WebSyncStore.didChangeExternallyNotification, object: nil, queue: nil
    ) { _ in
      XCTAssertTrue(Thread.isMainThread)
      let read = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        XCTAssertEqual(store.snapshot().progress[id]?.t, 42)
        read.signal()
      }
      XCTAssertEqual(read.wait(timeout: .now() + 2), .success,
                     "通知は websync キューを保持したまま送ってはならない")
      notified.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    DispatchQueue.global().async {
      var incoming = WebSyncStore.SyncDoc()
      incoming.progress[id] = .init(t: 42, at: Date().timeIntervalSince1970 * 1000)
      let response = store.merge(incoming: incoming)
      let decoded = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
      let progress = decoded?["progress"] as? [String: [String: Double]]
      XCTAssertEqual(progress?[id]?["t"], 42)
    }
    await fulfillment(of: [notified], timeout: 5)
  }

  /// merge 側の送り方とは別に、オブザーバー単体でも守る。
  /// バックグラウンドから直接 post されても、画面の再読み込みを積むだけでメインの完了は待たない。
  @MainActor
  func testWatchStateObserverDoesNotWaitForMainThread() async throws {
    let store = makeStore()
    let watchState = WatchStateStore(store: store)
    let id = UUID()
    store.updateLocally { doc in
      doc.progress[id.uuidString] = .init(t: 25, at: 1)
    }
    _ = store.snapshot() // ローカル書き込みの完了を待ってから post する。

    let posted = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      NotificationCenter.default.post(name: WebSyncStore.didChangeExternallyNotification, object: nil)
      posted.signal()
    }
    XCTAssertEqual(posted.wait(timeout: .now() + 2), .success,
                   "WatchStateStore は通知の送信側を MainActor の完了待ちにしてはならない")
    let deadline = Date().addingTimeInterval(3)
    while watchState.progress[id] != 25 && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(watchState.progress[id], 25)
  }

  /// 複数クライアントの merge と、メインスレッドからの snapshot を同時に走らせる。
  /// 修正前はここでデッドロックして固まる。
  @MainActor
  func testConcurrentMergesAndMainThreadSnapshotsKeepWatchStateCurrent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WebSyncStress-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WebSyncStore(rootURL: root)
    let watchState = WatchStateStore(store: store)
    let ids = (0..<4).map { _ in UUID() }
    let writesPerClient = 50
    let finished = expectation(description: "全クライアントの書き込みが完了する")
    finished.expectedFulfillmentCount = ids.count
    for id in ids {
      DispatchQueue.global().async {
        for step in 1...writesPerClient {
          var incoming = WebSyncStore.SyncDoc()
          let at = Double(step)
          incoming.progress[id.uuidString] = .init(t: Double(step), at: at)
          incoming.favorites[id.uuidString] = .init(on: step.isMultiple(of: 2), at: at)
          incoming.history = [.init(id: id.uuidString, at: at)]
          _ = store.merge(incoming: incoming)
        }
        finished.fulfill()
      }
    }
    // クライアントの書き込みや再読み込みと、メインスレッドでの実際の読み出しを交互に走らせる。
    for _ in 0..<100 {
      XCTAssertTrue(Thread.isMainThread)
      _ = store.snapshot()
      _ = store.snapshotData()
      try await Task.sleep(for: .milliseconds(1))
    }
    await fulfillment(of: [finished], timeout: 5)
    // ワーカーが積んだ post を流し切ってから、次のテストがオブザーバーを付ける。
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.main.async { continuation.resume() }
    }
    let deadline = Date().addingTimeInterval(3)
    while ids.contains(where: { watchState.progress[$0] != Double(writesPerClient) }) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    for id in ids {
      XCTAssertEqual(watchState.progress[id], Double(writesPerClient))
      XCTAssertEqual(watchState.favorites[id], true)
      let playedAt = try XCTUnwrap(watchState.lastPlayed[id])
      XCTAssertEqual(playedAt.timeIntervalSince1970, Double(writesPerClient) / 1000, accuracy: 0.000001)
    }
    XCTAssertEqual(Set(watchState.historyOrder), Set(ids))
    // merge は通知・返却の前に、文書全体の保存まで終えている。
    let restored = WebSyncStore(rootURL: root).snapshot()
    for id in ids {
      XCTAssertEqual(restored.progress[id.uuidString]?.t, Double(writesPerClient))
    }
  }

  /// ディスクに書かない保管庫（他のテストと衝突しない）。
  private func makeStore() -> WebSyncStore {
    WebSyncStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                 persistenceEnabled: false)
  }
}
