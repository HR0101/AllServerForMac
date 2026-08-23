import Foundation

// MARK: - サーバー ⇔ クライアント間の API 契約（wire format）
//
// これらの型は Mac サーバー（AllServerForMac）と iOS クライアント（VideoPlayer）の
// 双方で共有される．以前は両アプリに別々に定義されており，フィールドのズレが
// そのまま API 破壊につながっていた．1 か所に集約することで契約を構造的に保証する．
//
// 日付は JSONEncoder/JSONDecoder の `.iso8601` 戦略でやり取りする（両側の取り決め）．

/// アルバム一覧（`GET /albums`）の 1 要素
public struct RemoteAlbumInfo: Codable, Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let videoCount: Int
  public let type: String?
  public let coverVideoID: String?

  public init(
    id: String,
    name: String,
    videoCount: Int,
    type: String?,
    coverVideoID: String? = nil
  ) {
    self.id = id
    self.name = name
    self.videoCount = videoCount
    self.type = type
    self.coverVideoID = coverVideoID
  }
}

/// アルバム内メディア一覧（`GET /albums/:id/videos`）の 1 要素
public struct RemoteVideoInfo: Codable, Identifiable, Hashable, Sendable {
  public let id: String
  public let filename: String
  public let duration: TimeInterval
  public let importDate: Date
  public let creationDate: Date?
  public let mediaType: String?
  public let parentAlbumID: String?
  /// 実ファイルのサイズ（バイト）．並べ替え「サイズ」用．旧サーバーは送らないので Optional．
  public let fileSize: Int64?
  /// 実ファイルの更新日時．並べ替え「変更日」用．旧サーバーは送らないので Optional．
  public let modificationDate: Date?
  /// 実ファイルの最終アクセス日時．並べ替え「最後に開いた日」用．旧サーバーは送らないので Optional．
  public let accessDate: Date?

  public init(
    id: String,
    filename: String,
    duration: TimeInterval,
    importDate: Date,
    creationDate: Date?,
    mediaType: String?,
    parentAlbumID: String? = nil,
    fileSize: Int64? = nil,
    modificationDate: Date? = nil,
    accessDate: Date? = nil
  ) {
    self.id = id
    self.filename = filename
    self.duration = duration
    self.importDate = importDate
    self.creationDate = creationDate
    self.mediaType = mediaType
    self.parentAlbumID = parentAlbumID
    self.fileSize = fileSize
    self.modificationDate = modificationDate
    self.accessDate = accessDate
  }

  /// `mediaType == "photo"` のとき写真．動画と写真で UI を分岐するために使う．
  public var isPhoto: Bool { mediaType == "photo" }
}

// MARK: - 差分動画

/// 差分動画の1グループ (`GET /albums/:id/variants`)。
///
/// 検出はサーバー側で行う。フレームを時刻ぴったりで何枚も起こす処理なので、
/// 実ファイルを持たないクライアントには渡しようがなく、渡せたとしても割に合わない。
public struct RemoteVariantGroup: Codable, Identifiable, Hashable, Sendable {
  public let id: String
  /// この束の尺（束の中はどれもほぼ同じ）。
  public let duration: TimeInterval
  /// 束に入っている動画。並びはサーバー側の判定順。
  public let videoIDs: [String]
  /// 何を根拠にまとまったのかを画面に出すための実測値。測れなければ nil。
  public let minFrameDistance: Double?
  public let maxFrameDistance: Double?
  public let minTitleSimilarity: Double?
  public let maxTitleSimilarity: Double?

  public init(
    id: String,
    duration: TimeInterval,
    videoIDs: [String],
    minFrameDistance: Double? = nil,
    maxFrameDistance: Double? = nil,
    minTitleSimilarity: Double? = nil,
    maxTitleSimilarity: Double? = nil
  ) {
    self.id = id
    self.duration = duration
    self.videoIDs = videoIDs
    self.minFrameDistance = minFrameDistance
    self.maxFrameDistance = maxFrameDistance
    self.minTitleSimilarity = minTitleSimilarity
    self.maxTitleSimilarity = maxTitleSimilarity
  }
}

/// 差分動画の探索結果 (`GET /albums/:id/variants`)。
///
/// 1本あたり数秒かかるフレームの展開を挟むため、その場では今わかっているぶんだけを返し、
/// 残りは裏で作る。クライアントは `state` が `ready` になるまで繰り返し尋ねる
/// （`/video/:id/prepare` と同じ形）。`groups` は途中でも入っているので、
/// 見つかったものから先に触れる。
public struct RemoteVariantScanResult: Codable, Hashable, Sendable {
  public static let scanningState = "scanning"
  public static let readyState = "ready"

  public let state: String
  /// 指紋を作り終えた本数と、作る必要がある本数。
  public let scanned: Int
  public let total: Int
  public let groups: [RemoteVariantGroup]

  public var isReady: Bool { state == Self.readyState }

  public init(state: String, scanned: Int, total: Int, groups: [RemoteVariantGroup]) {
    self.state = state
    self.scanned = scanned
    self.total = total
    self.groups = groups
  }
}
