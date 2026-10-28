import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

// MARK: - Shared Utilities

nonisolated func isImagePredominantlyBlack(image: CGImage, threshold: CGFloat = 0.1) -> Bool {
    let size = 20
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var rawData = [UInt8](repeating: 0, count: size * size * 4)
    guard let context = CGContext(
        data: &rawData, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
    var darkPixelCount = 0
    for i in 0..<(size * size) {
        let offset = i * 4
        let luminance = 0.299 * CGFloat(rawData[offset]) / 255.0
                      + 0.587 * CGFloat(rawData[offset + 1]) / 255.0
                      + 0.114 * CGFloat(rawData[offset + 2]) / 255.0
        if luminance < threshold { darkPixelCount += 1 }
    }
    return Double(darkPixelCount) / Double(size * size) > 0.8
}

nonisolated enum LoopBlackFrameAnalysisError: LocalizedError {
  case invalidDuration
  case cannotReadFrames(String)
  case unsupportedPixelBuffer

  var errorDescription: String? {
    switch self {
    case .invalidDuration:
      return "動画の長さを取得できませんでした．"
    case .cannotReadFrames(let reason):
      return "黒画面の解析用フレームを読み取れませんでした．\(reason)"
    case .unsupportedPixelBuffer:
      return "黒画面の解析に必要な画素形式を取得できませんでした．"
    }
  }
}

/// 端から連続する黒フレームだけを調べ，中間の暗転を含む再生範囲を返します．
nonisolated struct LoopBlackFrameAnalyzer: Sendable {
  private let tailWindowSeconds: TimeInterval = 2
  private let fallbackFramesPerSecond: Float = 30
  private static let sampleWidth = 160
  private static let sampleHeight = 90
  private static let maximumBlackComponent: UInt8 = 8
  private static let minimumBlackPixelRatio = 0.995

  func analyze(asset: AVAsset) async throws -> CMTimeRange? {
    try Task.checkCancellation()
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      return nil
    }
    let duration = try await asset.load(.duration)
    guard duration.seconds.isFinite, duration.seconds > 0 else {
      throw LoopBlackFrameAnalysisError.invalidDuration
    }
    let frameRate = try await track.load(.nominalFrameRate)
    let fallbackFrameDuration = CMTime(
      seconds: 1 / Double(frameRate.isFinite && frameRate > 0 ? frameRate : fallbackFramesPerSecond),
      preferredTimescale: 60_000
    )
    let head = try scan(
      asset: asset, track: track,
      range: CMTimeRange(start: .zero, duration: duration),
      fallbackFrameDuration: fallbackFrameDuration,
      stopsAtFirstVisibleFrame: true
    )
    // 全編が黒い動画は，有効な再生区間を作れないため省略しません．
    guard let start = head.firstVisibleTime else { return nil }

    let window = CMTime(seconds: tailWindowSeconds, preferredTimescale: 60_000)
    var windowEnd = duration
    while CMTimeCompare(windowEnd, start) > 0 {
      try Task.checkCancellation()
      let windowStart = CMTimeMaximum(start, CMTimeSubtract(windowEnd, window))
      let tail = try scan(
        asset: asset, track: track,
        range: CMTimeRange(start: windowStart, end: windowEnd),
        fallbackFrameDuration: fallbackFrameDuration,
        stopsAtFirstVisibleFrame: false
      )
      if let lastVisibleEnd = tail.lastVisibleEnd {
        let end = CMTimeMinimum(lastVisibleEnd, duration)
        guard CMTimeCompare(end, start) > 0 else { return nil }
        return CMTimeRange(start: start, end: end)
      }
      windowEnd = windowStart
    }
    return nil
  }

  private struct EdgeFrames {
    var firstVisibleTime: CMTime?
    var lastVisibleEnd: CMTime?
  }

  /// 末尾は短い区間を後ろから順に読み，長い本編の全フレーム解析を避けます．
  private func scan(
    asset: AVAsset,
    track: AVAssetTrack,
    range: CMTimeRange,
    fallbackFrameDuration: CMTime,
    stopsAtFirstVisibleFrame: Bool
  ) throws -> EdgeFrames {
    try Task.checkCancellation()
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = range
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw LoopBlackFrameAnalysisError.cannotReadFrames("映像出力を追加できませんでした．")
    }
    reader.add(output)
    guard reader.startReading() else {
      throw LoopBlackFrameAnalysisError.cannotReadFrames(
        reader.error?.localizedDescription ?? "読み取りを開始できませんでした．"
      )
    }
    defer { reader.cancelReading() }

    var frames = EdgeFrames()
    var previousFrameWasVisible = false
    while let sample = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      let time = CMSampleBufferGetPresentationTimeStamp(sample)
      guard time.seconds.isFinite else {
        throw LoopBlackFrameAnalysisError.cannotReadFrames("フレームの時刻が不正です．")
      }
      // 次のフレームの実時刻を使い，可変フレームレートでも境界を合わせます．
      if previousFrameWasVisible { frames.lastVisibleEnd = time }
      guard let pixels = CMSampleBufferGetImageBuffer(sample) else {
        throw LoopBlackFrameAnalysisError.unsupportedPixelBuffer
      }
      let black = try Self.isBlackFrame(pixels)
      previousFrameWasVisible = !black
      if !black {
        if frames.firstVisibleTime == nil { frames.firstVisibleTime = time }
        let sampleDuration = CMSampleBufferGetDuration(sample)
        let frameDuration = sampleDuration.seconds.isFinite && sampleDuration.seconds > 0
          ? sampleDuration : fallbackFrameDuration
        frames.lastVisibleEnd = CMTimeAdd(time, frameDuration)
        if stopsAtFirstVisibleFrame { return frames }
      }
    }
    try Task.checkCancellation()
    guard reader.status == .completed else {
      throw LoopBlackFrameAnalysisError.cannotReadFrames(
        reader.error?.localizedDescription ?? "フレームの読み取りが中断されました．"
      )
    }
    return frames
  }

  /// 暗い場面や黒帯を除外し，画面のほぼ全域が黒い場合だけ判定します．
  static func isBlackFrame(_ pixels: CVPixelBuffer) throws -> Bool {
    guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
          CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else {
      throw LoopBlackFrameAnalysisError.unsupportedPixelBuffer
    }
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard let address = CVPixelBufferGetBaseAddress(pixels) else {
      throw LoopBlackFrameAnalysisError.unsupportedPixelBuffer
    }
    let width = CVPixelBufferGetWidth(pixels)
    let height = CVPixelBufferGetHeight(pixels)
    let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
    let sampledWidth = min(width, sampleWidth)
    let sampledHeight = min(height, sampleHeight)
    guard sampledWidth > 0, sampledHeight > 0 else {
      throw LoopBlackFrameAnalysisError.unsupportedPixelBuffer
    }
    let bytes = address.assumingMemoryBound(to: UInt8.self)
    var blackPixels = 0
    for y in 0..<sampledHeight {
      let row = bytes.advanced(by: (y * height / sampledHeight) * rowBytes)
      for x in 0..<sampledWidth {
        let pixel = row.advanced(by: (x * width / sampledWidth) * 4)
        if pixel[0] <= maximumBlackComponent,
           pixel[1] <= maximumBlackComponent,
           pixel[2] <= maximumBlackComponent {
          blackPixels += 1
        }
      }
    }
    return Double(blackPixels) / Double(sampledWidth * sampledHeight) >= minimumBlackPixelRatio
  }
}
