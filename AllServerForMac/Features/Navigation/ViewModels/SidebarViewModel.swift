import Combine
import Foundation

/// サイドバーのアルバム階層と件数計算を管理するViewModelです．
@MainActor
final class SidebarViewModel: ObservableObject {
  @Published private(set) var trashedMediaIDs: Set<UUID> = []
  @Published private(set) var videoAlbumNodes: [SidebarAlbumNode] = []
  @Published private(set) var photoAlbumNodes: [SidebarAlbumNode] = []

  /// サイドバーのツリーに載せるアルバム（システムアルバムを除き、動画/画像で棲み分ける）。
  /// フォルダ一覧画面も同じ絞り込みを使うので static にしている。
  static func treeAlbums(from albums: [Album], isPhoto: Bool) -> [Album] {
    albums.filter {
      $0.name != LibraryViewModel.allVideosAlbumName
        && $0.name != LibraryViewModel.allPhotosAlbumName
        && (($0.type == .photo) == isPhoto)
    }
  }

  func refresh(videos: [VideoItem], albums: [Album]) {
    trashedMediaIDs = Set(videos.lazy.filter(\.isInTrash).map(\.id))

    videoAlbumNodes = SidebarAlbumNode.buildTree(
      from: Self.treeAlbums(from: albums, isPhoto: false)
    )
    photoAlbumNodes = SidebarAlbumNode.buildTree(
      from: Self.treeAlbums(from: albums, isPhoto: true)
    )
  }

  func albumIDs(in node: SidebarAlbumNode) -> [UUID] {
    var ids = node.album.map { [$0.id] } ?? []
    ids.append(contentsOf: node.children.flatMap { albumIDs(in: $0) })
    return ids
  }

  func folderPath(
    containing albumID: UUID,
    in nodes: [SidebarAlbumNode],
    ancestors: [String] = []
  ) -> [String]? {
    for node in nodes {
      if node.children.isEmpty {
        if node.album?.id == albumID {
          return ancestors
        }
        continue
      }

      if node.album?.id == albumID {
        return ancestors + [node.id]
      }
      if let found = folderPath(
        containing: albumID,
        in: node.children,
        ancestors: ancestors + [node.id]
      ) {
        return found
      }
    }
    return nil
  }

}
