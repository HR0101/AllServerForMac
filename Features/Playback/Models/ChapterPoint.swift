import AVFoundation
import Foundation
import SwiftUI

// MARK: - Chapter model

/// プレイヤーサイドバーに表示するチャプター情報を表す構造体
struct ChapterPoint: Identifiable, Hashable {
    let id = UUID()
    let percentage: Double // 0.0, 0.1 ... 0.9
    let time: CMTime
    let thumbnail: Image?

    var timeString: String {
        let totalSeconds = Int(round(CMTimeGetSeconds(time)))
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func == (lhs: ChapterPoint, rhs: ChapterPoint) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
