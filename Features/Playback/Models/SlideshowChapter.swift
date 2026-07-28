import Foundation

/// スライドショーのチャプター（クリップ単位）
struct SlideshowChapter: Identifiable, Hashable {
    let id: UUID
    let title: String
    let startTime: TimeInterval
    let sourceURL: URL?
}
