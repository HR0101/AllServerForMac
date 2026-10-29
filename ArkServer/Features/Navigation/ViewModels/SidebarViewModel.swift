import Combine
import Foundation

/// サイドバーのアルバム階層と件数計算を管理するViewModelです．
@MainActor
final class SidebarViewModel: ObservableObject {
  @Published private(set) var trashedMediaIDs: Set<UUID> = []
  @Published private(set) var videoAlbumNodes: [SidebarAlbumNode] = []
  @Published private(set) var photoAlbumNodes: [SidebarAlbumNode] = []
  /// 行ごとの要約（本数・合計時間・表紙）。アルバム行は album.id、フォルダ行は folderKey で引く。
  /// 描画のたびに全件を数え直さないよう、videos / albums が変わったときだけここで作る。
  @Published private(set) var albumSummaries: [UUID: AlbumSummary] = [:]
  @Published private(set) var folderSummaries: [String: AlbumSummary] = [:]

  /// 動画ツリーと画像ツリーで同名フォルダが両立しうるので、ツリーごとにキーを分ける
  /// （サイドバーのドロップ先・展開状態のキーと同じ書き方）。
  static func folderKey(path: String, isPhoto: Bool) -> String {
    (isPhoto ? "photo:" : "video:") + path
  }

  /// 一覧に出る実アルバムの数（システムアルバムを除く）。
  var albumCount: Int { albumSummaries.count }

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
    refreshSummaries(videos: videos)
  }

  private func refreshSummaries(videos: [VideoItem]) {
    let itemByID = AlbumSummary.itemIndex(videos)
    var albumResult: [UUID: AlbumSummary] = [:]
    var folderResult: [String: AlbumSummary] = [:]

    /// 配下をまとめて1回で集計する（ノードごとに配下を辿り直さない）。
    func walk(_ node: SidebarAlbumNode, isPhoto: Bool) -> AlbumSummary {
      var total = AlbumSummary()
      if let album = node.album {
        let own = AlbumSummary.of(album: album, itemByID: itemByID)
        albumResult[album.id] = own
        total.merge(own)
      }
      for child in node.children {
        total.merge(walk(child, isPhoto: isPhoto))
      }
      if !node.children.isEmpty {
        folderResult[Self.folderKey(path: node.id, isPhoto: isPhoto)] = total
      }
      return total
    }

    for node in videoAlbumNodes { _ = walk(node, isPhoto: false) }
    for node in photoAlbumNodes { _ = walk(node, isPhoto: true) }
    albumSummaries = albumResult
    folderSummaries = folderResult
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
