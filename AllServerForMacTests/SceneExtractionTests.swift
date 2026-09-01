// AllServerForMacTests/SceneExtractionTests.swift

import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import AllServerForMac

struct SceneExtractionTests {
  @Test
  func tutorialCoversCompleteWorkflow() {
    let steps = SceneExtractionTutorialContent.steps

    #expect(steps.count == 6)
    #expect(steps.map(\.id) == Array(1...6))
    #expect(steps.allSatisfy { !$0.title.isEmpty })
    #expect(steps.allSatisfy { $0.details.count >= 4 })
    #expect(SceneExtractionTutorialContent.currentVersion > 0)
    #expect(steps[1].title.contains("ライブラリ"))
    #expect(steps[1].summary.contains("シーン抽出"))
    #expect(!steps[1].summary.contains("動画を開く"))
    #expect(steps[4].details.contains { $0.contains("1・2・3キー") })
  }

  @Test
  @MainActor
  func reviewingCandidateAdvancesToNextUnlabeledCandidate() {
    let first = CandidateSegment(
      startTime: 0,
      endTime: 10,
      peakTime: 4,
      score: 0.9,
      audioScore: 0.9,
      visualScore: 0.8,
      transitionScore: 0.7,
      reason: ["テスト"]
    )
    let second = CandidateSegment(
      startTime: 10,
      endTime: 20,
      peakTime: 14,
      score: 0.8,
      audioScore: 0.8,
      visualScore: 0.7,
      transitionScore: 0.6,
      reason: ["テスト"]
    )
    let viewModel = SceneExtractionViewModel()
    viewModel.candidates = [first, second]
    viewModel.selectedCandidateID = first.id

    viewModel.reviewCandidate(.accepted, candidateID: first.id)

    #expect(viewModel.candidates.first { $0.id == first.id }?.userLabel == .accepted)
    #expect(viewModel.selectedCandidateID == second.id)
  }

  @Test
  func glossaryExplainsImportantVisibleTerms() {
    let requiredTerms: Set<String> = [
      "候補区間",
      "ピーク時刻",
      "合成スコア",
      "候補しきい値",
      "A・音声スコア",
      "B・映像スコア",
      "C・遷移スコア",
      "FFT",
      "RMS",
      "freeze",
      "dissolve",
      "fade",
      "GT",
      "fps",
      "出力フレーム数",
      "H.264",
      "HEVC",
      "sidecar JSON",
      "CSV"
    ]
    let terms = SceneExtractionTutorialContent.glossaryTerms
    let availableTerms = Set(terms.map(\.term))
    let explainedCategories = Set(terms.map(\.category))
    let requiredCategories = Set(
      SceneExtractionGlossaryCategory.allCases.filter { $0 != .all }
    )

    #expect(requiredTerms.isSubset(of: availableTerms))
    #expect(requiredCategories.isSubset(of: explainedCategories))
    #expect(terms.allSatisfy { !$0.shortDefinition.isEmpty && !$0.detail.isEmpty })
  }

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

  @Test
  func clipExporterCompletesWithAudioAndVideo() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SceneExtractionAudioExporterTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let videoOnlyURL = temporaryDirectory.appendingPathComponent("video-only.mp4")
    let audioURL = temporaryDirectory.appendingPathComponent("audio.caf")
    let sourceURL = temporaryDirectory.appendingPathComponent("source-with-audio.mp4")
    try await makeSyntheticVideo(at: videoOnlyURL)
    try makeSilentAudio(at: audioURL, duration: 2)
    try await muxVideoAndAudio(
      videoURL: videoOnlyURL,
      audioURL: audioURL,
      outputURL: sourceURL,
      duration: 2
    )

    let document = VideoDocument(
      url: sourceURL,
      duration: 2,
      nominalFrameRate: 30,
      resolutionWidth: 160,
      resolutionHeight: 90,
      hasAudioTrack: true,
      hasVideoTrack: true,
      audioSampleRate: 48_000,
      timeScale: 600
    )
    let candidate = CandidateSegment(
      startTime: 0,
      endTime: 2,
      peakTime: 1,
      score: 0.9,
      audioScore: 0.9,
      visualScore: 0.9,
      transitionScore: 0,
      reason: ["音声付きテスト"]
    )
    var settings = AnalysisSettings()
    settings.clipDuration = 2
    settings.peakLeadTime = 1
    settings.targetFramesPerSecond = 24
    settings.targetFrameCount = 49
    settings.includesAudio = true

    let result = try await ClipExporter().export(
      document: document,
      candidate: candidate,
      settings: settings,
      outputDirectory: temporaryDirectory
    )
    let exportedAsset = AVURLAsset(url: result.videoURL)
    let videoTracks = try await exportedAsset.loadTracks(withMediaType: .video)
    let audioTracks = try await exportedAsset.loadTracks(withMediaType: .audio)
    let fileSize = try #require(
      FileManager.default.attributesOfItem(atPath: result.videoURL.path)[.size] as? NSNumber
    )
    let partialFiles = try FileManager.default.contentsOfDirectory(
      at: temporaryDirectory,
      includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.contains(".partial.mp4") }

    #expect(!videoTracks.isEmpty)
    #expect(!audioTracks.isEmpty)
    #expect(fileSize.int64Value > 0)
    #expect(partialFiles.isEmpty)
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

  private func makeSilentAudio(at url: URL, duration: Double) throws {
    let sampleRate = 48_000.0
    let channelCount: AVAudioChannelCount = 2
    let frameCount = AVAudioFrameCount(sampleRate * duration)
    let format = try #require(
      AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: channelCount
      )
    )
    let buffer = try #require(
      AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
      )
    )
    buffer.frameLength = frameCount
    if let channelData = buffer.floatChannelData {
      for channel in 0..<Int(channelCount) {
        channelData[channel].initialize(
          repeating: 0,
          count: Int(frameCount)
        )
      }
    }

    let audioFile = try AVAudioFile(
      forWriting: url,
      settings: format.settings
    )
    try audioFile.write(from: buffer)
  }

  private func muxVideoAndAudio(
    videoURL: URL,
    audioURL: URL,
    outputURL: URL,
    duration: Double
  ) async throws {
    let videoAsset = AVURLAsset(url: videoURL)
    let audioAsset = AVURLAsset(url: audioURL)
    let sourceVideoTrack = try #require(
      try await videoAsset.loadTracks(withMediaType: .video).first
    )
    let sourceAudioTrack = try #require(
      try await audioAsset.loadTracks(withMediaType: .audio).first
    )
    let composition = AVMutableComposition()
    let videoTrack = try #require(
      composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    )
    let audioTrack = try #require(
      composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    )
    let timeRange = CMTimeRange(
      start: .zero,
      duration: CMTime(seconds: duration, preferredTimescale: 600)
    )
    try videoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
    try audioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
    let exportSession = try #require(
      AVAssetExportSession(
        asset: composition,
        presetName: AVAssetExportPresetHighestQuality
      )
    )
    try await exportSession.export(to: outputURL, as: .mp4)
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
