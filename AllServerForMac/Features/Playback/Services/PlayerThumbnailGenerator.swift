import AVFoundation
import CoreMedia
import Foundation

// MARK: - Live thumbnail generation (no cache)

/// 再生中プレビュー（チャプター等）用に、キャッシュなしでサムネイルを生成するユーティリティ。
enum PlayerThumbnailGenerator {

    /// 指定された時間からサムネイルを生成する。真っ黒なフレームの場合は少し先で再試行する。
    static func generateLiveThumbnail(for asset: AVAsset, at time: CMTime) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let maxAttempts = 5
        let retryTimeOffset: Double = 2.0

        for attempt in 0..<maxAttempts {
            let attemptTime = CMTimeAdd(time, CMTime(seconds: Double(attempt) * retryTimeOffset, preferredTimescale: 600))
            do {
                let cgImage = try await generator.image(at: attemptTime).image
                if !isPredominantlyBlack(image: cgImage) {
                    return cgImage
                }
            } catch {
                continue
            }
        }
        return try? await generator.image(at: time).image
    }

    /// CGImage が主に黒（非常に暗い色）で構成されているかを判定する。
    private static func isPredominantlyBlack(
        image: CGImage,
        darknessThreshold: UInt8 = 30,
        percentageThreshold: Double = 0.95
    ) -> Bool {
        guard let pixelData = image.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else { return false }

        let width = image.width
        let height = image.height
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return false }

        let totalPixels = width * height
        guard totalPixels > 0 else { return false }

        // パフォーマンスのため最大1万ピクセル程度をサンプリングする
        let step = max(1, totalPixels / 10000)
        let sampleTotal = max(1, totalPixels / step)
        var darkPixelCount = 0

        for i in stride(from: 0, to: totalPixels, by: step) {
            let x = i % width
            let y = i / width
            let offset = (y * image.bytesPerRow) + (x * bytesPerPixel)
            let red = data[offset]
            let green = data[offset + 1]
            let blue = data[offset + 2]
            if red < darknessThreshold && green < darknessThreshold && blue < darknessThreshold {
                darkPixelCount += 1
            }
        }
        return Double(darkPixelCount) / Double(sampleTotal) >= percentageThreshold
    }
}
