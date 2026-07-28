import Foundation

struct Album: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var videoIDs: [UUID]
    var type: AlbumType
    var linkedFolderPath: String?
    var linkedFolderBookmarkData: Data?

    init(
        id: UUID,
        name: String,
        videoIDs: [UUID],
        type: AlbumType,
        linkedFolderPath: String? = nil,
        linkedFolderBookmarkData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.videoIDs = videoIDs
        self.type = type
        self.linkedFolderPath = linkedFolderPath
        self.linkedFolderBookmarkData = linkedFolderBookmarkData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.videoIDs = try container.decode([UUID].self, forKey: .videoIDs)
        self.type = try container.decodeIfPresent(AlbumType.self, forKey: .type) ?? .video
        self.linkedFolderPath = try container.decodeIfPresent(String.self, forKey: .linkedFolderPath)
        self.linkedFolderBookmarkData = try container.decodeIfPresent(Data.self, forKey: .linkedFolderBookmarkData)
    }
}
