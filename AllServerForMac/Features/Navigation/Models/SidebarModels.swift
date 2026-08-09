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

extension SidebarAlbumNode {
    /// アルバム名の "/" 区切りからフォルダ階層を組み立てる。
    /// サイドバーのツリーとフォルダ一覧画面が必ず同じ階層・同じ並び順を見るよう、
    /// 組み立てはここ1箇所だけで行う。
    static func buildTree(from albums: [Album]) -> [SidebarAlbumNode] {
        final class NodeBuilder {
            let id: String
            let name: String
            var album: Album?
            var children: [String: NodeBuilder] = [:]

            init(id: String, name: String) {
                self.id = id
                self.name = name
            }

            func makeNode() -> SidebarAlbumNode {
                SidebarAlbumNode(
                    id: id,
                    name: name,
                    album: album,
                    children: children.values
                        .map { $0.makeNode() }
                        .sorted {
                            $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        }
                )
            }
        }

        let root = NodeBuilder(id: "root", name: "root")

        for album in albums {
            let parts = album.name
                .components(separatedBy: "/")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }

            var current = root
            var currentPath = ""

            for (index, part) in parts.enumerated() {
                currentPath += (currentPath.isEmpty ? "" : "/") + part
                if current.children[part] == nil {
                    current.children[part] = NodeBuilder(id: currentPath, name: part)
                }
                guard let child = current.children[part] else { continue }
                current = child

                if index == parts.count - 1 {
                    current.album = album
                }
            }
        }

        return root.children.values
            .map { $0.makeNode() }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// "旅行/2024" のようなフォルダパスに対応するノードを探す。
    /// アルバムのリネーム（＝サイドバーでのドラッグ移動）でパスが消えることがあるため、
    /// 見つからない場合は nil を返して呼び出し側でフォールバックする。
    static func node(atPath path: String, in nodes: [SidebarAlbumNode]) -> SidebarAlbumNode? {
        let parts = path
            .components(separatedBy: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var currentLevel = nodes
        var found: SidebarAlbumNode?
        for part in parts {
            guard let match = currentLevel.first(where: { $0.name == part }) else { return nil }
            found = match
            currentLevel = match.children
        }
        return found
    }
}

struct AlbumDeletionRequest: Identifiable {
    let id = UUID()
    let albumIDs: [UUID]
}
