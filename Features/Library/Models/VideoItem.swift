import Foundation

struct VideoItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let originalFilename: String
    var internalFilename: String
    let duration: TimeInterval
    let importDate: Date
    let creationDate: Date?
    var fileHash: String
    var mediaType: MediaType = .video

    var externalFilePath: String?

    var isFavorite: Bool = false
    var isInTrash: Bool = false
    /// ゴミ箱に入れた日時。ゴミ箱の自動削除期限（設定）で使う。nil はゴミ箱に入っていないか旧データ。
    var trashedDate: Date? = nil
    /// fileHash を計算した時点のファイル更新日時。ファイルの中身が後から変わった場合に
    /// 古いハッシュを使い続けないための検証用。nil は旧データ（＝ハッシュは信頼しない）。
    var fileHashDate: Date? = nil

    init(id: UUID, originalFilename: String, internalFilename: String, duration: TimeInterval, importDate: Date, creationDate: Date?, fileHash: String, mediaType: MediaType = .video, externalFilePath: String? = nil, isFavorite: Bool = false, isInTrash: Bool = false, trashedDate: Date? = nil) {
        self.id = id
        self.originalFilename = originalFilename
        self.internalFilename = internalFilename
        self.duration = duration
        self.importDate = importDate
        self.creationDate = creationDate
        self.fileHash = fileHash
        self.mediaType = mediaType
        self.externalFilePath = externalFilePath
        self.isFavorite = isFavorite
        self.isInTrash = isInTrash
        self.trashedDate = trashedDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.originalFilename = try container.decode(String.self, forKey: .originalFilename)
        self.internalFilename = try container.decode(String.self, forKey: .internalFilename)
        self.duration = try container.decode(TimeInterval.self, forKey: .duration)
        self.importDate = try container.decode(Date.self, forKey: .importDate)
        self.creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate)
        self.fileHash = try container.decode(String.self, forKey: .fileHash)
        self.mediaType = try container.decodeIfPresent(MediaType.self, forKey: .mediaType) ?? .video
        self.externalFilePath = try container.decodeIfPresent(String.self, forKey: .externalFilePath)
        self.isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        self.isInTrash = try container.decodeIfPresent(Bool.self, forKey: .isInTrash) ?? false
        self.trashedDate = try container.decodeIfPresent(Date.self, forKey: .trashedDate)
        self.fileHashDate = try container.decodeIfPresent(Date.self, forKey: .fileHashDate)
    }
}

/// 並び替え（サイズ・変更日・最後に開いた日）のために実ファイルから読む属性。
/// VideoItem には保持していないので、必要になった時だけ stat して埋める。
nonisolated struct VideoFileMetadata: Sendable {
    var size: Int64 = 0
    var modificationDate: Date? = nil
    var accessDate: Date? = nil
}
