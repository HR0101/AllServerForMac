import Foundation

// RemoteAlbumInfo / RemoteVideoInfo は MediaServerKit へ集約（iOS と共有）
struct AccessLogEntry: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let ip: String
    let method: String
    let path: String
    let authorized: Bool
}

struct MimeType {
    static func forPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}
