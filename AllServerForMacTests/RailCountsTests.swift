import Foundation
import Testing
@testable import AllServerForMac

/// レールの件数バッジが、お気に入り・ゴミ箱の操作に追従することの確認。
/// ストレージを持たないメモリ上のライブラリだけを使うので、実際のライブラリや視聴履歴には触れない。
struct RailCountsTests {
  @Test @MainActor
  func countsFollowFavoriteAndTrashChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RailCountsTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let library = LibraryViewModel(storageEnvironment: LibraryStorageEnvironment(
      moviesDirectory: { nil }, downloadsDirectory: { nil }, createDirectory: { _ in }
    ))
    let items = (0..<3).map { index in
      VideoItem(id: UUID(), originalFilename: "v\(index).mp4", internalFilename: "v\(index).mp4",
                duration: 60, importDate: Date(), creationDate: nil, fileHash: "h\(index)")
    }
    library.videos = items
    library.albums = [Album(id: UUID(), name: LibraryViewModel.allVideosAlbumName, videoIDs: items.map(\.id), type: .video)]
    let watchState = WatchStateStore(store: WebSyncStore(rootURL: root, persistenceEnabled: false))
    let model = RailCountsModel(dataManager: library, watchState: watchState)

    #expect(model.counts.videos == 3)
    #expect(model.counts.favorites == 0)
    #expect(model.counts.trash == 0)

    library.toggleFavorite(videoIDs: [items[0].id])
    try await Task.sleep(for: .milliseconds(900))
    #expect(model.counts.favorites == 1)

    library.moveToTrash(videoIDs: [items[0].id])
    try await Task.sleep(for: .milliseconds(900))
    // ゴミ箱へ移すとお気に入りは外れ、動画の件数からも除かれる。
    #expect(model.counts.favorites == 0)
    #expect(model.counts.trash == 1)
    #expect(model.counts.videos == 2)
  }
}
