import Foundation

enum MediaType: String, Codable, Hashable, Sendable {
    case video
    case photo
}

enum AlbumType: String, Codable, Hashable, Sendable {
    case video
    case photo
    case mixed

    var displayName: String {
        switch self {
        case .video: return "動画アルバム"
        case .photo: return "画像アルバム"
        case .mixed: return "すべて"
        }
    }
}
