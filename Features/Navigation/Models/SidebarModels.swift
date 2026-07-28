import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// サイドバーのアルバムをドラッグする際のペイロード。
/// フォルダは実体を持たず名前の "/" 区切りだけで表現されるため、
/// ドロップ側は名前の付け替え（LibraryViewModel.renameAlbums）で移動を実現する。
struct AlbumDragPayload: Codable, Transferable {
    /// 移動対象となる実アルバムのID群（フォルダごとドラッグした場合はその配下全部）
    var albumIDs: [UUID]
    /// フォルダそのものをドラッグした場合の、そのフォルダの完全パス（例: "旅行/2024年"）。
    /// 単体アルバムのドラッグの場合は nil（末尾の名前だけを残して移動先直下に置く）。
    var sourceFolderPath: String?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .allServerAlbumDrag)
    }
}

extension UTType {
    static let allServerAlbumDrag = UTType(exportedAs: "hr.AllServerForMac.album-drag-payload")
}

struct SidebarAlbumNode: Identifiable {
    let id: String
    let name: String
    let album: Album?
    let children: [SidebarAlbumNode]
}

struct AlbumDeletionRequest: Identifiable {
    let id = UUID()
    let albumIDs: [UUID]
}
