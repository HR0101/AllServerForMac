import Foundation

struct LinkedFolderCandidate: Identifiable, Hashable {
    let id: String
    let conflictID: String
    let albumID: UUID?
    let albumName: String
    let albumType: AlbumType
    let folderPath: String
    let matchCount: Int
}

nonisolated struct LinkedFolderDirectoryEntry: Sendable {
  let url: URL
  let isDirectory: Bool
}

struct LinkedFolderConflict: Identifiable, Hashable {
    let id: String
    let albumID: UUID?
    let albumName: String
    let albumType: AlbumType
    let candidates: [LinkedFolderCandidate]
}
