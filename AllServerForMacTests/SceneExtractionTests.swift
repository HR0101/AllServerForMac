// AllServerForMacTests/SceneExtractionTests.swift

import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import AllServerForMac

struct SceneExtractionTests {
  @Test
  func mergerFillsMissingAudioFeaturesWithZero() throws {
    let visualPoints = (0..<3).map { index in
      makeVisualPoint(time: Double(index), frameDiff: Double(index) * 0.1)
    }
    let transitionPoints = (0..<3).map { index in
      TransitionFeaturePoint(
        time: Double(index),
        freezeScore: Double(index) * 0.2,
        dissolveScore: 0,
        fadeScore: 0,
        editScore: 0
      )
    }

    let merged = try FeatureMerger().merge(
      audioPoints: [],
      visualPoints: visualPoints,
      transitionPoints: transitionPoints
    )

    #expect(merged.count == visualPoints.count)
    #expect(merged.allSatisfy { $0.audioBandEnergy == 0 })
    #expect(merged.allSatisfy { $0.audioRise == 0 })
    #expect(merged.allSatisfy { $0.audioDecay == 0 })
  }

  @Test
  func transitionAnalyzerRaisesFreezeScoreForConsecutiveStillFrames() throws {
    let visualPoints = (0..<5).map { index in
      makeVisualPoint(time: Double(index) / 8, frameDiff: 0.001)
    }

    let transitions = try TransitionAnalyzer().analyze(
      visualPoints: visualPoints,
      settings: AnalysisSettings()
    )

    #expect(transitions.first?.freezeScore == 0.25)
    #expect(transitions.last?.freezeScore == 1)
  }

  @Test
  func detectorKeepsSeparatedPeaksAndClampsClipToVideoBounds() throws {
    var settings = AnalysisSettings()
    settings.candidateThreshold = 0.6
    settings.minimumCandidateDistance = 8
    var features = (0..<16).map { index in
      makeFeature(time: Double(index), score: 0.1)
    }
    features[2].combinedScore = 0.8
    features[12].combinedScore = 0.9

    let candidates = try CandidateDetector().detect(
      features: features,
      duration: 16,
      settings: settings
    )

    #expect(candidates.count == 2)
    #expect(candidates[0].peakTime == 12)
    #expect(candidates[0].startTime == 6)
    #expect(candidates[0].endTime == 16)
    #expect(candidates[1].peakTime == 2)
    #expect(candidates[1].startTime == 0)
    #expect(candidates[1].endTime == 10)
  }

  @Test
  func exportSettingsRejectZeroFramesPerSecond() {
    var settings = AnalysisSettings()
    settings.targetFramesPerSecond = 0

    #expect(throws: AnalysisSettingsError.self) {
      try settings.validateForExport()
    }
  }

  @Test
  func clipExporterProducesExactFrameCount() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SceneExtractionExporterTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let sourceURL = temporaryDirectory.appendingPathComponent("source.mp4")
    try await makeSyntheticVideo(at: sourceURL)

    let document = VideoDocument(
      url: sourceURL,
      duration: 2,
      nominalFrameRate: 30,
      resolutionWidth: 160,
      resolutionHeight: 90,
      hasAudioTrack: false,
      hasVideoTrack: true,
      audioSampleRate: nil,
      timeScale: 600
    )
    let candidate = CandidateSegment(
      startTime: 0,
      endTime: 2,
      peakTime: 1,
      score: 0.9,
      audioScore: 0,
      visualScore: 0.9,
      transitionScore: 0,
      reason: ["テスト"]
    )
    var settings = AnalysisSettings()
    settings.clipDuration = 2
    settings.peakLeadTime = 1
    settings.targetFramesPerSecond = 24
    settings.targetFrameCount = 49
    settings.includesAudio = false

    let result = try await ClipExporter().export(
      document: document,
      candidate: candidate,
      settings: settings,
      outputDirectory: temporaryDirectory
    )

    let exportedFrameCount = try await countVideoFrames(at: result.videoURL)
    #expect(exportedFrameCount == 49, "実フレーム数は\(exportedFrameCount)でした．")
    #expect(result.metadata.frameCount == 49)
    #expect(result.metadataURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
  }

  private func makeVisualPoint(time: Double, frameDiff: Double) -> VisualFeaturePoint {
    VisualFeaturePoint(
      time: time,
      frameDiff: frameDiff,
      meanLuminance: 0.5,
      luminanceDiff: frameDiff,
      edgeDiff: 0,
      motionSpike: 0,
      motionDrop: 0,
      zScore: 0
    )
  }

  private func makeFeature(time: Double, score: Double) -> FeatureVector {
    FeatureVector(
      time: time,
      audioBandEnergy: 0.8,
      audioRise: 0.7,
      audioDecay: 0.7,
      visualMotion: 0.8,
      visualSpike: 0.7,
      visualDrop: 0.7,
      freezeScore: 0.2,
      dissolveScore: 0,
      fadeScore: 0,
      editScore: 0,
      combinedScore: score
    )
  }

  private func makeSyntheticVideo(at url: URL) async throws {
    let width = 160
    let height = 90
    let framesPerSecond: Int32 = 30
    let frameCount = 60
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height
      ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
      ]
    )
    #expect(writer.canAdd(input))
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    for frameIndex in 0..<frameCount {
      while !input.isReadyForMoreMediaData {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(2))
      }
      var pixelBuffer: CVPixelBuffer?
      let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
      )
      guard status == kCVReturnSuccess, let pixelBuffer else {
        throw CocoaError(.fileWriteUnknown)
      }
      CVPixelBufferLockBaseAddress(pixelBuffer, [])
      if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(
          baseAddress,
          Int32(frameIndex % 255),
          CVPixelBufferGetDataSize(pixelBuffer)
        )
      }
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
      let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: framesPerSecond)
      #expect(adaptor.append(pixelBuffer, withPresentationTime: presentationTime))
    }

    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
  }

  private func countVideoFrames(at url: URL) async throws -> Int {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    #expect(reader.canAdd(output))
    reader.add(output)
    #expect(reader.startReading())
    var frameCount = 0
    while let sampleBuffer = output.copyNextSampleBuffer() {
      frameCount += CMSampleBufferGetNumSamples(sampleBuffer)
    }
    return frameCount
  }
}
