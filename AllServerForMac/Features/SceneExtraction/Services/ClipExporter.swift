// AllServerForMac/Features/SceneExtraction/Services/ClipExporter.swift

import AVFoundation
import CoreVideo
import Foundation

nonisolated enum ClipExporterError: LocalizedError {
  case missingVideoTrack
  case invalidVideoSize
  case cannotAddVideoInput
  case cannotAddAudioInput
  case cannotStartReader(String)
  case cannotStartWriter(String)
  case missingVideoFrame
  case appendVideoFailed(String)
  case appendAudioFailed(String)
  case retimeAudioFailed
  case emptyOutput
  case writerFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingVideoTrack:
      return "クリップへ書き出せる動画トラックがありません．"
    case .invalidVideoSize:
      return "動画の解像度が不正です．"
    case .cannotAddVideoInput:
      return "動画エンコーダーをAVAssetWriterへ追加できませんでした．"
    case .cannotAddAudioInput:
      return "音声エンコーダーをAVAssetWriterへ追加できませんでした．"
    case .cannotStartReader(let reason):
      return "クリップの読み取りを開始できませんでした．\(reason)"
    case .cannotStartWriter(let reason):
      return "クリップの書き出しを開始できませんでした．\(reason)"
    case .missingVideoFrame:
      return "指定区間から映像フレームを取得できませんでした．"
    case .appendVideoFailed(let reason):
      return "映像フレームを書き込めませんでした．\(reason)"
    case .appendAudioFailed(let reason):
      return "音声サンプルを書き込めませんでした．\(reason)"
    case .retimeAudioFailed:
      return "音声タイムスタンプをクリップ位置へ変換できませんでした．"
    case .emptyOutput:
      return "書き出し結果が空です．完成した動画ファイルを作成できませんでした．"
    case .writerFailed(let reason):
      return "クリップを完了できませんでした．\(reason)"
    }
  }
}

nonisolated struct ClipExporter: Sendable {
  private let videoBitRatePerPixel = 6.0
  private let audioBitRate = 192_000
  private let readinessPollNanoseconds: UInt64 = 2_000_000

  func export(
    document: VideoDocument,
    candidate: CandidateSegment,
    settings: AnalysisSettings,
    outputDirectory: URL
  ) async throws -> ClipExportResult {
    try settings.validateForExport()
    return try await Task.detached(priority: .userInitiated) {
      try await exportDetached(
        document: document,
        candidate: candidate,
        settings: settings,
        outputDirectory: outputDirectory
      )
    }.value
  }

  private func exportDetached(
    document: VideoDocument,
    candidate: CandidateSegment,
    settings: AnalysisSettings,
    outputDirectory: URL
  ) async throws -> ClipExportResult {
    try FileManager.default.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true
    )
    let outputURL = makeOutputURL(
      document: document,
      candidate: candidate,
      outputDirectory: outputDirectory
    )
    let workingOutputURL = makeWorkingOutputURL(for: outputURL)
    let metadataURL = outputURL.deletingPathExtension().appendingPathExtension("json")
    let asset = AVURLAsset(url: document.url)
    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
      throw ClipExporterError.missingVideoTrack
    }
    let audioTrack = settings.includesAudio
      ? try await asset.loadTracks(withMediaType: .audio).first
      : nil
    let naturalSize = try await videoTrack.load(.naturalSize)
    let preferredTransform = try await videoTrack.load(.preferredTransform)
    let width = evenDimension(naturalSize.width)
    let height = evenDimension(naturalSize.height)
    guard width > 0, height > 0 else {
      throw ClipExporterError.invalidVideoSize
    }

    let writer = try AVAssetWriter(outputURL: workingOutputURL, fileType: .mp4)
    let videoInput = makeVideoInput(
      width: width,
      height: height,
      transform: preferredTransform,
      settings: settings
    )
    guard writer.canAdd(videoInput) else {
      throw ClipExporterError.cannotAddVideoInput
    }
    writer.add(videoInput)

    let audioInput = try await makeAudioInput(track: audioTrack)
    if let audioInput {
      guard writer.canAdd(audioInput) else {
        throw ClipExporterError.cannotAddAudioInput
      }
      writer.add(audioInput)
    }

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
      ]
    )

    guard writer.startWriting() else {
      throw ClipExporterError.cannotStartWriter(writer.error?.localizedDescription ?? "原因不明です．")
    }
    writer.startSession(atSourceTime: .zero)

    do {
      if let audioTrack, let audioInput {
        // 映像だけを先に全量投入すると，Writerが未処理の音声を待って停止します．
        // 両トラックを並行して進め，時刻のインターリーブを維持します．
        async let videoWrite: Void = writeVideo(
          asset: asset,
          track: videoTrack,
          candidate: candidate,
          settings: settings,
          writer: writer,
          input: videoInput,
          adaptor: adaptor
        )
        async let audioWrite: Void = writeAudio(
          asset: asset,
          track: audioTrack,
          candidate: candidate,
          settings: settings,
          writer: writer,
          input: audioInput
        )
        _ = try await (videoWrite, audioWrite)
      } else {
        try await writeVideo(
          asset: asset,
          track: videoTrack,
          candidate: candidate,
          settings: settings,
          writer: writer,
          input: videoInput,
          adaptor: adaptor
        )
      }
      writer.endSession(
        atSourceTime: CMTime(
          value: CMTimeValue(settings.targetFrameCount),
          timescale: CMTimeScale(max(1, settings.targetFramesPerSecond))
        )
      )
      try await finishWriting(writer)
      try validateOutput(at: workingOutputURL)
      try FileManager.default.moveItem(at: workingOutputURL, to: outputURL)
    } catch {
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: workingOutputURL)
      throw error
    }

    let metadata = ExportMetadata(
      sourceURL: document.url.path,
      sourceFileName: document.url.lastPathComponent,
      startTime: candidate.startTime,
      endTime: candidate.endTime,
      peakTime: candidate.peakTime,
      duration: settings.outputDuration,
      fps: Double(settings.targetFramesPerSecond),
      frameCount: settings.targetFrameCount,
      score: candidate.score,
      audioScore: candidate.audioScore,
      visualScore: candidate.visualScore,
      transitionScore: candidate.transitionScore,
      reason: candidate.reason,
      createdAt: Date()
    )
    if settings.writesSidecarJSON {
      try writeMetadata(metadata, to: metadataURL)
    }
    return ClipExportResult(
      videoURL: outputURL,
      metadataURL: settings.writesSidecarJSON ? metadataURL : nil,
      metadata: metadata
    )
  }

  private func makeVideoInput(
    width: Int,
    height: Int,
    transform: CGAffineTransform,
    settings: AnalysisSettings
  ) -> AVAssetWriterInput {
    let codec: AVVideoCodecType = settings.usesHEVC ? .hevc : .h264
    let bitRate = max(1_000_000, Int(Double(width * height) * videoBitRatePerPixel))
    let outputSettings: [String: Any] = [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitRate,
        AVVideoExpectedSourceFrameRateKey: settings.targetFramesPerSecond,
        AVVideoMaxKeyFrameIntervalKey: settings.targetFramesPerSecond * 2
      ]
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    input.expectsMediaDataInRealTime = false
    input.transform = transform
    return input
  }

  private func makeAudioInput(track: AVAssetTrack?) async throws -> AVAssetWriterInput? {
    guard let track else { return nil }
    let descriptions = try await track.load(.formatDescriptions)
    guard let description = descriptions.first,
          let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
      return nil
    }
    let channelCount = Int(streamDescription.pointee.mChannelsPerFrame)
    let sampleRate = streamDescription.pointee.mSampleRate
    guard channelCount > 0, sampleRate > 0 else { return nil }

    return AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: channelCount,
        AVSampleRateKey: sampleRate,
        AVEncoderBitRateKey: audioBitRate
      ]
    )
  }

  private func writeVideo(
    asset: AVAsset,
    track: AVAssetTrack,
    candidate: CandidateSegment,
    settings: AnalysisSettings,
    writer: AVAssetWriter,
    input: AVAssetWriterInput,
    adaptor: AVAssetWriterInputPixelBufferAdaptor
  ) async throws {
    defer {
      input.markAsFinished()
    }
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = sourceTimeRange(candidate: candidate, settings: settings)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw ClipExporterError.cannotAddVideoInput
    }
    reader.add(output)
    guard reader.startReading() else {
      throw ClipExporterError.cannotStartReader(reader.error?.localizedDescription ?? "映像Readerを開始できませんでした．")
    }

    let sourceStart = CMTime(seconds: candidate.startTime, preferredTimescale: 600)
    let framesPerSecond = max(1, settings.targetFramesPerSecond)
    var previousSample = output.copyNextSampleBuffer()
    var nextSample = output.copyNextSampleBuffer()
    guard previousSample != nil else {
      throw ClipExporterError.missingVideoFrame
    }

    for frameIndex in 0..<settings.targetFrameCount {
      try Task.checkCancellation()
      let outputTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(framesPerSecond))
      let targetSeconds = outputTime.seconds

      while let nextSampleValue = nextSample,
            relativeSeconds(nextSampleValue, sourceStart: sourceStart) <= targetSeconds {
        previousSample = nextSampleValue
        nextSample = output.copyNextSampleBuffer()
      }

      guard let selectedSample = nearestSample(
        previous: previousSample,
        next: nextSample,
        targetSeconds: targetSeconds,
        sourceStart: sourceStart
      ), let pixelBuffer = CMSampleBufferGetImageBuffer(selectedSample) else {
        throw ClipExporterError.missingVideoFrame
      }
      try await waitUntilReady(input, writer: writer)
      guard adaptor.append(pixelBuffer, withPresentationTime: outputTime) else {
        throw ClipExporterError.appendVideoFailed(writer.error?.localizedDescription ?? "原因不明です．")
      }
    }

    if reader.status == .failed {
      throw ClipExporterError.cannotStartReader(reader.error?.localizedDescription ?? "映像Readerが失敗しました．")
    }
  }

  private func writeAudio(
    asset: AVAsset,
    track: AVAssetTrack,
    candidate: CandidateSegment,
    settings: AnalysisSettings,
    writer: AVAssetWriter,
    input: AVAssetWriterInput
  ) async throws {
    defer {
      input.markAsFinished()
    }
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = sourceTimeRange(candidate: candidate, settings: settings)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
      ]
    )
    guard reader.canAdd(output) else {
      throw ClipExporterError.cannotAddAudioInput
    }
    reader.add(output)
    guard reader.startReading() else {
      throw ClipExporterError.cannotStartReader(reader.error?.localizedDescription ?? "音声Readerを開始できませんでした．")
    }

    let sourceStart = CMTime(seconds: candidate.startTime, preferredTimescale: 600)
    let outputEnd = settings.outputDuration
    while let sampleBuffer = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      guard let retimedBuffer = retime(sampleBuffer, subtracting: sourceStart) else {
        throw ClipExporterError.retimeAudioFailed
      }
      if CMSampleBufferGetPresentationTimeStamp(retimedBuffer).seconds >= outputEnd {
        break
      }
      try await waitUntilReady(input, writer: writer)
      guard input.append(retimedBuffer) else {
        throw ClipExporterError.appendAudioFailed(writer.error?.localizedDescription ?? "原因不明です．")
      }
    }

    if reader.status == .failed {
      throw ClipExporterError.cannotStartReader(reader.error?.localizedDescription ?? "音声Readerが失敗しました．")
    }
  }

  private func retime(_ sampleBuffer: CMSampleBuffer, subtracting startTime: CMTime) -> CMSampleBuffer? {
    var timingInfo = CMSampleTimingInfo()
    guard CMSampleBufferGetSampleTimingInfo(
      sampleBuffer,
      at: 0,
      timingInfoOut: &timingInfo
    ) == noErr else {
      return nil
    }
    timingInfo.presentationTimeStamp = CMTimeSubtract(timingInfo.presentationTimeStamp, startTime)
    if timingInfo.decodeTimeStamp.isValid {
      timingInfo.decodeTimeStamp = CMTimeSubtract(timingInfo.decodeTimeStamp, startTime)
    }

    var retimedBuffer: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault,
      sampleBuffer: sampleBuffer,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timingInfo,
      sampleBufferOut: &retimedBuffer
    )
    return status == noErr ? retimedBuffer : nil
  }

  private func nearestSample(
    previous: CMSampleBuffer?,
    next: CMSampleBuffer?,
    targetSeconds: Double,
    sourceStart: CMTime
  ) -> CMSampleBuffer? {
    guard let previous else { return next }
    guard let next else { return previous }
    let previousDistance = abs(relativeSeconds(previous, sourceStart: sourceStart) - targetSeconds)
    let nextDistance = abs(relativeSeconds(next, sourceStart: sourceStart) - targetSeconds)
    return previousDistance <= nextDistance ? previous : next
  }

  private func relativeSeconds(_ sampleBuffer: CMSampleBuffer, sourceStart: CMTime) -> Double {
    CMTimeSubtract(
      CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
      sourceStart
    ).seconds
  }

  private func sourceTimeRange(
    candidate: CandidateSegment,
    settings: AnalysisSettings
  ) -> CMTimeRange {
    let start = CMTime(seconds: candidate.startTime, preferredTimescale: 600)
    let availableDuration = max(0, candidate.endTime - candidate.startTime)
    let duration = min(availableDuration, settings.outputDuration)
    return CMTimeRange(
      start: start,
      duration: CMTime(seconds: duration, preferredTimescale: 600)
    )
  }

  private func waitUntilReady(
    _ input: AVAssetWriterInput,
    writer: AVAssetWriter
  ) async throws {
    while !input.isReadyForMoreMediaData {
      try Task.checkCancellation()
      if writer.status == .failed || writer.status == .cancelled {
        throw ClipExporterError.writerFailed(writer.error?.localizedDescription ?? "Writerが停止しました．")
      }
      try await Task.sleep(nanoseconds: readinessPollNanoseconds)
    }
  }

  private func finishWriting(_ writer: AVAssetWriter) async throws {
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw ClipExporterError.writerFailed(
        writer.error?.localizedDescription ?? "原因不明です．"
      )
    }
  }

  private func writeMetadata(_ metadata: ExportMetadata, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(metadata).write(to: url, options: .atomic)
  }

  private func validateOutput(at url: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    guard fileSize > 0 else {
      throw ClipExporterError.emptyOutput
    }
  }

  private func makeOutputURL(
    document: VideoDocument,
    candidate: CandidateSegment,
    outputDirectory: URL
  ) -> URL {
    let sourceName = sanitizedFileName(document.url.deletingPathExtension().lastPathComponent)
    let timeText = String(format: "%09.2f", candidate.startTime)
    let scoreText = String(format: "%.2f", candidate.score)
    let uniqueSuffix = UUID().uuidString.prefix(8)
    let fileName = "\(sourceName)_\(timeText)_score\(scoreText)_\(uniqueSuffix).mp4"
    return outputDirectory.appendingPathComponent(fileName)
  }

  private func sanitizedFileName(_ fileName: String) -> String {
    let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let sanitizedScalars = fileName.unicodeScalars.map { scalar in
      allowedCharacters.contains(scalar) ? String(scalar) : "_"
    }
    let result = sanitizedScalars.joined()
    return result.isEmpty ? "clip" : result
  }

  private func makeWorkingOutputURL(for outputURL: URL) -> URL {
    let workingName = ".\(outputURL.deletingPathExtension().lastPathComponent).partial.mp4"
    return outputURL.deletingLastPathComponent().appendingPathComponent(workingName)
  }

  private func evenDimension(_ value: CGFloat) -> Int {
    let rounded = max(0, Int(abs(value).rounded()))
    return rounded - rounded % 2
  }
}
