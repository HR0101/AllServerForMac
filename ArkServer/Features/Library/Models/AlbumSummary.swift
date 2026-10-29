import Foundation

/// アルバム／フォルダ1件分の中身の要約。
/// サイドバーの行・アルバム一覧ページ・フォルダ画面のタイルが、同じ数字を同じ書き方で出すために
/// 集計と文言をここ1箇所にまとめている（ゴミ箱のメディアは数えない）。
struct AlbumSummary {
    var videoCount = 0
    var photoCount = 0
    /// 動画の合計再生時間（秒）。画像は含まない。
    var totalDuration: TimeInterval = 0
    /// 配下の、中身のある実アルバムの数。フォルダの「3アルバム」表示に使う
    /// （空のアルバムを数えると、見える中身より多く見えてしまう）。
    var albumCount = 0
    var latestImportDate: Date?
    /// 表紙に使う代表メディア（最大4件）。自分のアルバムを先に、足りなければ子孫を順に辿る
    /// （サーバー・iOSクライアントの coverVideoID と同じ「先頭から」の考え方）。
    var coverItems: [VideoItem] = []

    static let coverLimit = 4

    var mediaCount: Int { videoCount + photoCount }

    mutating func merge(_ other: AlbumSummary) {
        videoCount += other.videoCount
        photoCount += other.photoCount
        totalDuration += other.totalDuration
        albumCount += other.albumCount
        if let date = other.latestImportDate {
            latestImportDate = max(latestImportDate ?? date, date)
        }
        let room = Self.coverLimit - coverItems.count
        if room > 0 {
            coverItems.append(contentsOf: other.coverItems.prefix(room))
        }
    }

    // MARK: - 集計

    /// ゴミ箱を除いたメディアの索引。呼び出し側で1回だけ作って、全アルバムの集計に使い回す。
    static func itemIndex(_ videos: [VideoItem]) -> [UUID: VideoItem] {
        var index: [UUID: VideoItem] = [:]
        index.reserveCapacity(videos.count)
        for video in videos where !video.isInTrash {
            index[video.id] = video
        }
        return index
    }

    /// 実アルバム1件ぶん（そのアルバム自身のメディアだけ）。
    static func of(album: Album, itemByID: [UUID: VideoItem]) -> AlbumSummary {
        var summary = AlbumSummary()
        for id in album.videoIDs {
            guard let item = itemByID[id] else { continue }
            if item.mediaType == .video {
                summary.videoCount += 1
                summary.totalDuration += item.duration
            } else {
                summary.photoCount += 1
            }
            summary.latestImportDate = max(summary.latestImportDate ?? item.importDate, item.importDate)
            if summary.coverItems.count < coverLimit {
                summary.coverItems.append(item)
            }
        }
        summary.albumCount = summary.mediaCount > 0 ? 1 : 0
        return summary
    }

    /// 画面に出ているメディアの並び（検索で絞った結果など）から作る要約。ページ見出しの2行目に使う。
    static func of(items: [VideoItem]) -> AlbumSummary {
        var summary = AlbumSummary()
        for item in items {
            if item.mediaType == .video {
                summary.videoCount += 1
                summary.totalDuration += item.duration
            } else {
                summary.photoCount += 1
            }
        }
        return summary
    }

    /// フォルダ／アルバムのノード1件ぶん（配下をすべて含む）。
    static func of(node: SidebarAlbumNode, itemByID: [UUID: VideoItem]) -> AlbumSummary {
        var summary = AlbumSummary()
        if let album = node.album {
            summary.merge(of(album: album, itemByID: itemByID))
        }
        for child in node.children {
            summary.merge(of(node: child, itemByID: itemByID))
        }
        return summary
    }

    // MARK: - 文言

    /// 「動画 12本 · 38分」「画像 120枚」「5アルバム · 動画 80本 · 4時間12分」のような1行の説明。
    func detailText(isFolder: Bool) -> String {
        var parts: [String] = []
        if isFolder, albumCount > 0 {
            parts.append("\(albumCount.formatted())アルバム")
        }
        if videoCount > 0 {
            parts.append("動画 \(videoCount.formatted())本")
            if totalDuration >= 1 {
                parts.append(Self.durationText(totalDuration))
            }
        }
        if photoCount > 0 {
            parts.append("画像 \(photoCount.formatted())枚")
        }
        if mediaCount == 0 {
            parts.append("空のアルバム")
        }
        return parts.joined(separator: " · ")
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)秒" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)分" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)時間" : "\(hours)時間\(rest)分"
    }
}
