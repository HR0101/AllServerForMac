import Combine
import Foundation

/// Mac アプリ本体の「視聴位置」と「再生履歴」。
///
/// 実体は `WebSyncStore`（`websync.json`）で、ブラウザ UI と iOS / Android クライアントが
/// `/sync` 越しに読み書きしているものと同じ保管庫を共有する。Mac 本体もそこへ相乗りするので、
/// iPhone で途中まで観た動画を Mac で続きから再生できる（逆も同じ）。
///
/// 表示用の辞書（`progress` / `lastPlayed`）を再生のたびに更新すると、
/// ミニプレイヤーで裏に出している一覧が数秒おきに全再描画されてしまう。
/// そのため書き込みは即座に保管庫へ送りつつ、`@Published` への反映は
/// 動画の切り替え・一時停止・プレイヤーを閉じた時など区切りの良い所でだけ行う。
@MainActor
final class WatchStateStore: ObservableObject {

    /// 一覧のサムネイルに出す視聴済みバー用（秒）。
    @Published private(set) var progress: [UUID: Double] = [:]
    /// 「最後に再生した日時」での並べ替え用。
    @Published private(set) var lastPlayed: [UUID: Date] = [:]
    /// 再生履歴の並び（新しい順）。「再生履歴」アルバムはこの順番そのものが中身なので、
    /// 描画のたびに辞書を並べ替えずに済むよう、区切りの良い所で作り直して持っておく。
    @Published private(set) var historyOrder: [UUID] = []
    /// クライアント共有のお気に入り。**保管庫が知っている項目だけ**が入る
    /// （値が false のもの＝「外した」記録も含む）。知らない項目は欠損として扱い、
    /// 勝手に「お気に入りではない」と決めつけない。
    @Published private(set) var favorites: [UUID: Bool] = [:]

    /// 途中再開とみなす下限。数秒しか観ていない動画で毎回途中から始まるのを避ける。
    private let minimumResumeSeconds: Double = 5
    /// 末尾のこの秒数まで進んでいたら「観終わった」とみなし、位置を捨てる。
    private let finishedTailSeconds: Double = 10
    /// 再生中に保管庫へ書き込む最短間隔（秒）。
    private let recordIntervalSeconds: Double = 10
    /// 前回の記録位置からこれ未満しか動いていなければ書かない（秒）。
    private let recordMinimumDeltaSeconds: Double = 2

    private let store: WebSyncStore
    /// 保管庫の最新値。`@Published` はここから区切りの良い所で写す。
    private var liveProgress: [UUID: Double] = [:]
    private var liveLastPlayed: [UUID: Date] = [:]
    /// 表示用の辞書へまだ反映していない書き込みがあるか。
    private var hasUnpublishedChanges = false
    /// 動画ごとの最後に保管庫へ書いた時刻（間引き用）。
    private var lastRecordedAt: [UUID: Date] = [:]
    private var externalChangeObserver: NSObjectProtocol?

    init(store: WebSyncStore) {
        self.store = store
        reload()
        // 外部クライアント（ブラウザ・iPhone）が書き換えたら Mac の表示も追従させる。
        externalChangeObserver = NotificationCenter.default.addObserver(
            forName: WebSyncStore.didChangeExternallyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let externalChangeObserver {
            NotificationCenter.default.removeObserver(externalChangeObserver)
        }
    }

    // MARK: - 読み出し

    /// 途中から再開すべき位置。先頭付近と末尾付近は再開させない（nil を返す）。
    func resumeSeconds(for videoID: UUID, duration: TimeInterval) -> Double? {
        guard let seconds = liveProgress[videoID], seconds.isFinite else { return nil }
        guard seconds >= minimumResumeSeconds else { return nil }
        guard duration <= 0 || seconds < duration - finishedTailSeconds else { return nil }
        return seconds
    }

    /// 視聴済みバーの長さ（0...1）。観ていない動画は 0。
    func watchedFraction(for videoID: UUID, duration: TimeInterval) -> Double {
        guard duration > 0, let seconds = progress[videoID], seconds > 0 else { return 0 }
        return min(1, max(0, seconds / duration))
    }

    // MARK: - 書き込み

    /// 再生位置を記録する。`force` が false のときは間引く（再生中に毎秒呼ばれる想定）。
    func recordProgress(videoID: UUID, seconds: Double, duration: TimeInterval, force: Bool = false) {
        guard seconds.isFinite, seconds >= 0 else { return }

        // 末尾まで観たものは位置を捨てて「観終わった」扱いにする。
        // ブラウザ・iOS と同じく 0 を書き込むトゥームストーン方式（キーごと消すと
        // 他端末の古い記録とマージしたときに位置が復活してしまう）。
        //
        // 尺が末尾判定の幅より短い動画（ショートなど）は、そもそも resumeSeconds が
        // 再開位置を返さない。記録の上限（500件）を食うだけなので何も書かない。
        if duration > finishedTailSeconds, seconds >= duration - finishedTailSeconds {
            markFinished(videoID: videoID)
            return
        }
        guard duration > finishedTailSeconds else { return }

        if !force {
            if let previous = liveProgress[videoID], abs(previous - seconds) < recordMinimumDeltaSeconds { return }
            if let recordedAt = lastRecordedAt[videoID],
               Date().timeIntervalSince(recordedAt) < recordIntervalSeconds { return }
        }

        liveProgress[videoID] = seconds
        lastRecordedAt[videoID] = Date()
        hasUnpublishedChanges = true
        write(videoID: videoID, seconds: seconds)
    }

    /// 観終わった（または最初から観直したい）動画の位置を捨てる。
    func markFinished(videoID: UUID) {
        guard liveProgress[videoID] != 0 else { return }
        liveProgress[videoID] = 0
        lastRecordedAt[videoID] = Date()
        hasUnpublishedChanges = true
        write(videoID: videoID, seconds: 0)
    }

    /// 再生履歴の先頭へ積む（同じ動画は積み直し）。
    func recordHistory(videoID: UUID) {
        let now = Date()
        liveLastPlayed[videoID] = now
        hasUnpublishedChanges = true

        let key = videoID.uuidString
        let at = now.timeIntervalSince1970 * 1000
        store.updateLocally { doc in
            doc.history.removeAll { $0.id == key }
            doc.history.insert(WebSyncStore.HistoryEntry(id: key, at: at), at: 0)
            // 他端末で消した履歴が Mac の再生で蘇るのは正しい挙動なので、削除記録は消しておく。
            doc.historyRemoved[key] = nil
        }
    }

    /// お気に入りを付け外しする。視聴位置と違って回数が少ないので、間引かず即座に反映する。
    func setFavorite(videoIDs: [UUID], isFavorite: Bool) {
        guard !videoIDs.isEmpty else { return }
        let at = Date().timeIntervalSince1970 * 1000
        let keys = videoIDs.map(\.uuidString)
        store.updateLocally { doc in
            for key in keys {
                doc.favorites[key] = WebSyncStore.MarkEntry(on: isFavorite, at: at)
            }
        }
        var updated = favorites
        for id in videoIDs { updated[id] = isFavorite }
        favorites = updated
    }

    /// 再生履歴から個別に外す。ブラウザ・iOS と同じく「消した時刻」を残すので、
    /// 他の端末に残っている古い履歴とマージしても復活しない。
    func removeHistory(videoIDs: [UUID]) {
        guard !videoIDs.isEmpty else { return }
        let at = Date().timeIntervalSince1970 * 1000
        let keys = Set(videoIDs.map(\.uuidString))
        store.updateLocally { doc in
            doc.history.removeAll { keys.contains($0.id) }
            for key in keys { doc.historyRemoved[key] = at }
        }
        for id in videoIDs { liveLastPlayed[id] = nil }
        lastPlayed = liveLastPlayed
        historyOrder = Self.makeHistoryOrder(from: liveLastPlayed)
    }

    /// 再生履歴を空にする。視聴位置（続きから）は消さない。
    func clearHistory() {
        let ids = Array(liveLastPlayed.keys)
        guard !ids.isEmpty else { return }
        removeHistory(videoIDs: ids)
    }

    /// 溜めておいた変更を表示用の辞書へ反映する。動画の切り替えやプレイヤーを閉じた時に呼ぶ。
    func publishPendingChanges() {
        guard hasUnpublishedChanges else { return }
        hasUnpublishedChanges = false
        progress = liveProgress
        lastPlayed = liveLastPlayed
        historyOrder = Self.makeHistoryOrder(from: liveLastPlayed)
    }

    /// 新しい順。同時刻はどちらが先でも構わないが、並びが毎回入れ替わらないよう ID で決める。
    private static func makeHistoryOrder(from lastPlayed: [UUID: Date]) -> [UUID] {
        lastPlayed
            .sorted { left, right in
                left.value == right.value
                    ? left.key.uuidString < right.key.uuidString
                    : left.value > right.value
            }
            .map(\.key)
    }

    // MARK: - 内部

    private func write(videoID: UUID, seconds: Double) {
        let key = videoID.uuidString
        let at = Date().timeIntervalSince1970 * 1000
        store.updateLocally { doc in
            doc.progress[key] = WebSyncStore.ProgressEntry(t: seconds, at: at)
        }
    }

    /// 保管庫の中身を読み直し、表示用の辞書ごと入れ替える。
    private func reload() {
        let doc = store.snapshot()

        var progressByID: [UUID: Double] = [:]
        progressByID.reserveCapacity(doc.progress.count)
        for (key, entry) in doc.progress {
            guard let id = UUID(uuidString: key), entry.t > 0 else { continue }
            progressByID[id] = entry.t
        }

        var lastPlayedByID: [UUID: Date] = [:]
        lastPlayedByID.reserveCapacity(doc.history.count)
        for entry in doc.history {
            guard let id = UUID(uuidString: entry.id) else { continue }
            let date = Date(timeIntervalSince1970: entry.at / 1000)
            if let existing = lastPlayedByID[id], existing > date { continue }
            lastPlayedByID[id] = date
        }

        var favoritesByID: [UUID: Bool] = [:]
        favoritesByID.reserveCapacity(doc.favorites.count)
        for (key, entry) in doc.favorites {
            guard let id = UUID(uuidString: key) else { continue }
            favoritesByID[id] = entry.on
        }

        liveProgress = progressByID
        liveLastPlayed = lastPlayedByID
        hasUnpublishedChanges = false
        progress = progressByID
        lastPlayed = lastPlayedByID
        historyOrder = Self.makeHistoryOrder(from: lastPlayedByID)
        favorites = favoritesByID
    }
}
