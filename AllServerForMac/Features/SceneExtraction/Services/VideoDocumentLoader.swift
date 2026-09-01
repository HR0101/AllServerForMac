// AllServerForMac/Features/SceneExtraction/Services/VideoDocumentLoader.swift

import AVFoundation
import Foundation

nonisolated enum VideoDocumentLoaderError: LocalizedError {
  case missingVideoTrack
  case invalidDuration

  var errorDescription: String? {
    switch self {
    case .missingVideoTrack:
      return "選択したファイルに動画トラックがありません．"
    case .invalidDuration:
      return "動画の再生時間を取得できませんでした．"
    }
  }
}

nonisolated struct VideoDocumentLoader: Sendable {
  func load(from url: URL) async throws -> VideoDocument {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    guard duration.seconds.isFinite, duration.seconds > 0 else {
      throw VideoDocumentLoaderError.invalidDuration
    }

    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    guard let videoTrack = videoTracks.first else {
      throw VideoDocumentLoaderError.missingVideoTrack
    }

    async let nominalFrameRate = videoTrack.load(.nominalFrameRate)
    async let naturalSize = videoTrack.load(.naturalSize)
    async let preferredTransform = videoTrack.load(.preferredTransform)
    async let naturalTimeScale = videoTrack.load(.naturalTimeScale)

    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    let audioSampleRate = try await loadSampleRate(from: audioTracks.first)
    let transformedSize = try await naturalSize.applying(preferredTransform)

    return VideoDocument(
      url: url,
      duration: duration.seconds,
      nominalFrameRate: Double(try await nominalFrameRate),
      resolutionWidth: Int(abs(transformedSize.width.rounded())),
      resolutionHeight: Int(abs(transformedSize.height.rounded())),
      hasAudioTrack: !audioTracks.isEmpty,
      hasVideoTrack: true,
      audioSampleRate: audioSampleRate,
      timeScale: try await naturalTimeScale
    )
  }

  private func loadSampleRate(from audioTrack: AVAssetTrack?) async throws -> Double? {
    guard let audioTrack else { return nil }
    let descriptions = try await audioTrack.load(.formatDescriptions)
    guard let description = descriptions.first,
          let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
      return nil
    }
    return streamDescription.pointee.mSampleRate
  }
}
