import Foundation

/// HTTPルートへ渡すライブラリの一貫スナップショット。videos と albums を別々のロックで
/// 読むと、その間の変更で「アルバムにはIDがあるのに動画リストに無い」ような不整合な
/// ペアになるため、必ず1つの値として原子的に読み書きする。
nonisolated struct LibrarySnapshotData {
    var videos: [VideoItem]
    var albums: [Album]
}
