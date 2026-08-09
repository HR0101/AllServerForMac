import Foundation

nonisolated struct DataContainer: Codable, Sendable {
    var videos: [VideoItem]
    var albums: [Album]
    var duplicateCheckStates: [UUID: DuplicateCheckState]?
    /// ライブラリJSONのスキーマ世代。古いビルドはこのキーを知らないまま読み書きして
    /// 新フィールドを黙って落とすため、少なくとも「自分より新しい形式か」を
    /// 新しいビルド側で検知できるようにしておく（nil は旧ビルドが書いたデータ）。
    var schemaVersion: Int? = nil
}

nonisolated enum LibraryLoadResult: Sendable {
  case loaded(DataContainer)
  case recovered(DataContainer)
  case empty
}

/// ロック付きの値ボックス。メインアクター側で書き込み、HTTPワーカースレッドから読む。
/// サーバーの各ルートが DispatchQueue.main.sync でライブラリを読むと、
/// Mac の UI が忙しいときに iOS への応答が止まり、逆にリクエストラッシュが
/// Mac の UI をカクつかせるため、ルートはこのスナップショット経由で読む。
