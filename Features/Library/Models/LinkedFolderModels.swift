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

struct LinkedFolderConflict: Identifiable, Hashable {
    let id: String
    let albumID: UUID?
    let albumName: String
    let albumType: AlbumType
    let candidates: [LinkedFolderCandidate]
}
