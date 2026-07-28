import AVFoundation
import Foundation

/// スライドショー生成の結果
struct SlideshowGenerationResult {
    let playerItem: AVPlayerItem
    let clipDurations: [TimeInterval]
}
