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
