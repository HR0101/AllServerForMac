// AllServerForMac/Features/SceneExtraction/Services/AudioAnalyzer.swift

import Accelerate
import AVFoundation
import Foundation

nonisolated enum AudioAnalyzerError: LocalizedError {
  case cannotCreateReader
  case cannotAddOutput
  case invalidAudioFormat
  case readerFailed(String)

  var errorDescription: String? {
    switch self {
    case .cannotCreateReader:
      return "音声解析用のAVAssetReaderを作成できませんでした．"
    case .cannotAddOutput:
      return "音声PCM出力をAVAssetReaderへ追加できませんでした．"
    case .invalidAudioFormat:
      return "音声のサンプルレートまたはチャンネル数を取得できませんでした．"
    case .readerFailed(let reason):
      return "音声の読み取りに失敗しました．\(reason)"
    }
  }
}

nonisolated struct AudioAnalyzer: Sendable {
  private let minimumFrequency = 100.0
  private let maximumFrequency = 1_500.0
  private let minimumStandardDeviation = 0.000_000_1

  func analyze(url: URL, settings: AnalysisSettings) async throws -> [AudioFeaturePoint] {
    let asset = AVURLAsset(url: url)
    guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
      return []
    }

    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      throw AudioAnalyzerError.cannotCreateReader
    }

    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false
    ]
    let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw AudioAnalyzerError.cannotAddOutput
    }
    reader.add(output)

    guard reader.startReading() else {
      throw AudioAnalyzerError.readerFailed(reader.error?.localizedDescription ?? "開始できませんでした．")
    }

    var rawPoints: [RawAudioPoint] = []
    var pendingSamples: [Float] = []
    var pendingStartTime: Double?
    var sampleRate = 0.0
    var channelCount = 0
    var windowSize = 0
    var hopSize = 0

    while let sampleBuffer = output.copyNextSampleBuffer() {
      try Task.checkCancellation()

      if sampleRate == 0 {
        guard let format = sampleBuffer.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
          throw AudioAnalyzerError.invalidAudioFormat
        }
        sampleRate = streamDescription.pointee.mSampleRate
        channelCount = Int(streamDescription.pointee.mChannelsPerFrame)
        guard sampleRate > 0, channelCount > 0 else {
          throw AudioAnalyzerError.invalidAudioFormat
        }
        windowSize = max(2, Int((sampleRate * settings.audioWindowDuration).rounded()))
        hopSize = max(1, windowSize / 2)
      }

      if pendingSamples.isEmpty {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        pendingStartTime = presentationTime.isFinite ? presentationTime : 0
      }

      let interleavedSamples = try samples(from: sampleBuffer)
      pendingSamples.append(contentsOf: makeMono(interleavedSamples, channelCount: channelCount))

      while pendingSamples.count >= windowSize {
        try Task.checkCancellation()
        let window = Array(pendingSamples.prefix(windowSize))
        let time = max(0, pendingStartTime ?? 0)
        rawPoints.append(analyzeWindow(window, sampleRate: sampleRate, time: time))
        pendingSamples.removeFirst(min(hopSize, pendingSamples.count))
        pendingStartTime = time + Double(hopSize) / sampleRate
      }
    }

    if reader.status == .failed {
      throw AudioAnalyzerError.readerFailed(reader.error?.localizedDescription ?? "原因不明です．")
    }

    return makeFeaturePoints(from: rawPoints)
  }

  private func samples(from sampleBuffer: CMSampleBuffer) throws -> [Float] {
    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      throw AudioAnalyzerError.invalidAudioFormat
    }
    let byteCount = CMBlockBufferGetDataLength(dataBuffer)
    guard byteCount > 0, byteCount.isMultiple(of: MemoryLayout<Float>.size) else {
      throw AudioAnalyzerError.invalidAudioFormat
    }

    var samples = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
    let status = samples.withUnsafeMutableBytes { destination in
      CMBlockBufferCopyDataBytes(
        dataBuffer,
        atOffset: 0,
        dataLength: byteCount,
        destination: destination.baseAddress!
      )
    }
    guard status == kCMBlockBufferNoErr else {
      throw AudioAnalyzerError.readerFailed("PCMバッファをコピーできませんでした．")
    }
    return samples
  }

  private func makeMono(_ samples: [Float], channelCount: Int) -> [Float] {
    guard channelCount > 1 else { return samples }
    let frameCount = samples.count / channelCount
    var mono = [Float](repeating: 0, count: frameCount)
    let divisor = Float(channelCount)

    for frameIndex in 0..<frameCount {
      let firstSampleIndex = frameIndex * channelCount
      var sum: Float = 0
      for channelIndex in 0..<channelCount {
        sum += samples[firstSampleIndex + channelIndex]
      }
      mono[frameIndex] = sum / divisor
    }
    return mono
  }

  private func analyzeWindow(_ samples: [Float], sampleRate: Double, time: Double) -> RawAudioPoint {
    var rms: Float = 0
    vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))

    let fftLength = nextPowerOfTwo(samples.count)
    let log2Length = vDSP_Length(log2(Double(fftLength)))
    guard let fftSetup = vDSP_create_fftsetup(log2Length, FFTRadix(kFFTRadix2)) else {
      return RawAudioPoint(time: time, rms: Double(rms), bandEnergy: 0)
    }
    defer { vDSP_destroy_fftsetup(fftSetup) }

    var padded = [Float](repeating: 0, count: fftLength)
    var hannWindow = [Float](repeating: 0, count: samples.count)
    vDSP_hann_window(&hannWindow, vDSP_Length(samples.count), Int32(vDSP_HANN_NORM))
    vDSP_vmul(samples, 1, hannWindow, 1, &padded, 1, vDSP_Length(samples.count))

    let halfLength = fftLength / 2
    var real = [Float](repeating: 0, count: halfLength)
    var imaginary = [Float](repeating: 0, count: halfLength)
    var magnitudes = [Float](repeating: 0, count: halfLength)

    real.withUnsafeMutableBufferPointer { realBuffer in
      imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
        var splitComplex = DSPSplitComplex(
          realp: realBuffer.baseAddress!,
          imagp: imaginaryBuffer.baseAddress!
        )
        padded.withUnsafeBufferPointer { paddedBuffer in
          paddedBuffer.baseAddress!.withMemoryRebound(
            to: DSPComplex.self,
            capacity: halfLength
          ) { complexBuffer in
            // 実数列を偶数・奇数サンプルへ分け，in-place実FFTへ渡します．
            vDSP_ctoz(complexBuffer, 2, &splitComplex, 1, vDSP_Length(halfLength))
          }
        }
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2Length, FFTDirection(kFFTDirection_Forward))
        // 絶対値の二乗を周波数ビンごとのパワーとして使います．
        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfLength))
      }
    }

    let frequencyResolution = sampleRate / Double(fftLength)
    let lowerBin = max(0, Int((minimumFrequency / frequencyResolution).rounded(.up)))
    let upperBin = min(halfLength - 1, Int((maximumFrequency / frequencyResolution).rounded(.down)))
    guard lowerBin <= upperBin else {
      return RawAudioPoint(time: time, rms: Double(rms), bandEnergy: 0)
    }

    var powerSum: Float = 0
    magnitudes[lowerBin...upperBin].withContiguousStorageIfAvailable { buffer in
      vDSP_sve(buffer.baseAddress!, 1, &powerSum, vDSP_Length(buffer.count))
    }
    let binCount = max(1, upperBin - lowerBin + 1)
    let normalization = Double(fftLength * fftLength * binCount)
    let bandEnergy = log1p(Double(powerSum) / normalization)
    return RawAudioPoint(time: time, rms: Double(rms), bandEnergy: bandEnergy)
  }

  private func makeFeaturePoints(from rawPoints: [RawAudioPoint]) -> [AudioFeaturePoint] {
    guard !rawPoints.isEmpty else { return [] }
    let energies = rawPoints.map(\.bandEnergy)
    let mean = energies.reduce(0, +) / Double(energies.count)
    let variance = energies.reduce(0) { partial, value in
      partial + pow(value - mean, 2)
    } / Double(energies.count)
    let standardDeviation = max(minimumStandardDeviation, sqrt(variance))

    return rawPoints.enumerated().map { index, point in
      let previousEnergy = index > 0 ? rawPoints[index - 1].bandEnergy : point.bandEnergy
      let delta = point.bandEnergy - previousEnergy
      return AudioFeaturePoint(
        time: point.time,
        rms: point.rms,
        bandEnergy100To1500: point.bandEnergy,
        delta: delta,
        decay: max(0, -delta),
        zScore: (point.bandEnergy - mean) / standardDeviation
      )
    }
  }

  private func nextPowerOfTwo(_ value: Int) -> Int {
    var result = 1
    while result < value {
      result <<= 1
    }
    return result
  }
}

private nonisolated struct RawAudioPoint: Sendable {
  let time: Double
  let rms: Double
  let bandEnergy: Double
}
