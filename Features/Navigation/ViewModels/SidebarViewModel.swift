import Combine
import Foundation

/// サイドバーのアルバム階層と件数計算を管理するViewModelです．
@MainActor
final class SidebarViewModel: ObservableObject {
  @Published private(set) var trashedMediaIDs: Set<UUID> = []
  @Published private(set) var videoAlbumNodes: [SidebarAlbumNode] = []
  @Published private(set) var photoAlbumNodes: [SidebarAlbumNode] = []

  func refresh(videos: [VideoItem], albums: [Album]) {
    trashedMediaIDs = Set(videos.lazy.filter(\.isInTrash).map(\.id))

    let userAlbums = albums.filter {
      $0.name != LibraryViewModel.allVideosAlbumName
        && $0.name != LibraryViewModel.allPhotosAlbumName
    }
    videoAlbumNodes = buildAlbumTree(
      from: userAlbums.filter { $0.type != .photo }
    )
    photoAlbumNodes = buildAlbumTree(
      from: userAlbums.filter { $0.type == .photo }
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

  private func buildAlbumTree(from albums: [Album]) -> [SidebarAlbumNode] {
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
}
