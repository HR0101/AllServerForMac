import AVFoundation
import Foundation
import MediaToolbox

// MARK: - 同時再生の音声処理（音量・ミュート・定位）
//
// AVPlayer には定位（左右のどちらから鳴らすか）を指定する仕組みが無く、
// AVAudioMix で調整できるのも音量だけ。左右へ振り分けるにはサンプルを直接触るしかないので、
// 音声トラックへ MTAudioProcessingTap を挟み、チャンネルごとのゲインを掛ける。

/// 1タイルぶんの音声パラメータ。処理タップ（リアルタイムの音声スレッド）から毎回読まれる。
///
/// 音声スレッドはブロックしてはいけないためロックを取らない。
/// 受け渡すのは整列済みの Float 2つだけで、これらの読み書きは分割されない。
/// 更新の反映が数ミリ秒遅れても、音量つまみの操作としては問題にならない。
final class AudioTapSettings: @unchecked Sendable {
    private var leftGain: Float = 1
    private var rightGain: Float = 1

    var gains: (left: Float, right: Float) { (leftGain, rightGain) }

    /// `pan` は -1（完全に左）〜 0（中央）〜 +1（完全に右）。
    func update(volume: Float, isMuted: Bool, pan: Float) {
        let base = isMuted ? 0 : min(max(volume, 0), 1)
        let clampedPan = min(max(pan, -1), 1)
        leftGain = base * min(1, 1 - clampedPan)
        rightGain = base * min(1, 1 + clampedPan)
    }
}

enum MultiPlayerAudio {
    /// `track` に処理タップを挟んだ audioMix を作る。`settings` の変更は即座に音へ反映される。
    static func makeAudioMix(for track: AVAssetTrack, settings: AudioTapSettings) -> AVAudioMix? {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let clientInfo = UnsafeMutableRawPointer(Unmanaged.passRetained(settings).toOpaque())

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: tapInit,
            finalize: tapFinalize,
            prepare: nil,
            unprepare: nil,
            process: tapProcess
        )

        var tap: MTAudioProcessingTap?
        // 音を書き換える用途なので PreEffects（audioMix 自身の音量処理より前）に挟む。
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tap
        )
        guard status == noErr, let tap else {
            // 生成に失敗したら finalize が呼ばれないので、ここで retain を戻す。
            Unmanaged<AudioTapSettings>.fromOpaque(clientInfo).release()
            return nil
        }

        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}

// MARK: - 差分切り替え再生の音量解析

/// 動画ごとに測る時刻を明示し，一部一致差分では共通場面だけを解析できるようにする．
nonisolated struct VariantAudioLevelSource: Sendable {
  let url: URL
  let duration: TimeInterval
  let sampleCenterTimes: [TimeInterval]?
}

/// 差分を切り替えた瞬間の音量差を小さくするため，代表区間のRMSを比較する．
///
/// BGMだけを分離する処理ではなく，音声全体の実効音量をBGM音量の目安として扱う．
/// 音割れを避けるため小さい動画は増幅せず，大きい動画だけを基準まで減衰させる．
nonisolated enum VariantAudioLevelAnalyzer {
  static let samplePositions = [
    0.10,
    0.20,
    0.30,
    0.40,
    0.50,
    0.60,
    0.70,
    0.80,
    0.90
  ]

  private static let sampleWindowDuration: TimeInterval = 1.25
  private static let sampleRate = 8_000.0
  private static let silenceThresholdDecibels = -55.0
  private static let maximumAttenuationDecibels = 30.0
  private static let minimumRMS = 0.000_001
  private static let maximumConcurrentAnalyses = 2

  static func analyze(sources: [VariantAudioLevelSource]) async -> [Double?] {
    await withTaskGroup(
      of: (Int, Double?).self,
      returning: [Double?].self
    ) { group in
      var nextSourceIndex = 0
      let initialTaskCount = min(maximumConcurrentAnalyses, sources.count)
      for _ in 0..<initialTaskCount {
        let index = nextSourceIndex
        let source = sources[index]
        nextSourceIndex += 1
        group.addTask {
          let level = await representativeDecibels(for: source)
          return (index, level)
        }
      }

      var levels = [Double?](repeating: nil, count: sources.count)
      while let (index, level) = await group.next() {
        levels[index] = level
        // 4K動画の再生と競合しないよう，音声デコードは最大2本に抑える．
        if nextSourceIndex < sources.count {
          let nextIndex = nextSourceIndex
          let nextSource = sources[nextIndex]
          nextSourceIndex += 1
          group.addTask {
            let nextLevel = await representativeDecibels(for: nextSource)
            return (nextIndex, nextLevel)
          }
        }
      }
      return levels
    }
  }

  /// 最も小さい有効音量を基準にし，大きい動画だけを減衰させる．
  /// 無音や解析不能な動画は補正せず，誤って全動画を無音近くまで下げないようにする．
  static func normalizationGains(for levels: [Double?]) -> [Float] {
    let validLevels = levels.compactMap { level -> Double? in
      guard let level,
            level.isFinite,
            level >= silenceThresholdDecibels else { return nil }
      return level
    }
    guard let targetLevel = validLevels.min() else {
      return [Float](repeating: 1, count: levels.count)
    }

    return levels.map { level in
      guard let level,
            level.isFinite,
            level >= silenceThresholdDecibels else { return 1 }
      let attenuation = max(
        targetLevel - level,
        -maximumAttenuationDecibels
      )
      return Float(pow(10, attenuation / 20))
    }
  }

  static func adjustmentText(level: Double?, gain: Float) -> String {
    guard let level,
          level.isFinite,
          level >= silenceThresholdDecibels else {
      return "音声なし・補正対象外"
    }
    guard gain < 0.995 else { return "基準音量" }
    let decibels = 20 * log10(Double(gain))
    return String(format: "補正 %.1f dB", decibels)
  }

  private static func representativeDecibels(
    for source: VariantAudioLevelSource
  ) async -> Double? {
    guard source.duration > 0, !Task.isCancelled else { return nil }
    let asset = AVURLAsset(url: source.url)
    guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
      return nil
    }

    let sampleTimes = source.sampleCenterTimes ?? samplePositions.map {
      source.duration * $0
    }
    var windowLevels: [Double] = []
    windowLevels.reserveCapacity(sampleTimes.count)

    for centerTime in sampleTimes {
      guard !Task.isCancelled else { return nil }
      if let rootMeanSquare = readRootMeanSquare(
        asset: asset,
        track: track,
        centerTime: centerTime,
        duration: source.duration
      ) {
        let decibels = 20 * log10(max(rootMeanSquare, minimumRMS))
        windowLevels.append(decibels)
      }
    }

    guard !windowLevels.isEmpty else { return nil }
    // 一時的な大音量や無音へ偏らないよう，9区間の中央値を代表値にする．
    let sortedLevels = windowLevels.sorted()
    return sortedLevels[sortedLevels.count / 2]
  }

  private static func readRootMeanSquare(
    asset: AVAsset,
    track: AVAssetTrack,
    centerTime: TimeInterval,
    duration: TimeInterval
  ) -> Double? {
    let windowDuration = min(sampleWindowDuration, duration)
    guard windowDuration > 0 else { return nil }
    let startTime = max(
      0,
      min(duration - windowDuration, centerTime - windowDuration / 2)
    )

    do {
      let reader = try AVAssetReader(asset: asset)
      reader.timeRange = CMTimeRange(
        start: CMTime(seconds: startTime, preferredTimescale: 600),
        duration: CMTime(seconds: windowDuration, preferredTimescale: 600)
      )
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1
      ]
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
      output.alwaysCopiesSampleData = false
      guard reader.canAdd(output) else { return nil }
      reader.add(output)
      guard reader.startReading() else { return nil }
      defer { reader.cancelReading() }

      var squaredSum = 0.0
      var sampleCount = 0
      while reader.status == .reading,
            !Task.isCancelled,
            let sampleBuffer = output.copyNextSampleBuffer() {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
          continue
        }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        guard byteCount > 0,
              byteCount.isMultiple(of: MemoryLayout<Int16>.size) else {
          continue
        }

        var samples = [Int16](
          repeating: 0,
          count: byteCount / MemoryLayout<Int16>.size
        )
        let status = samples.withUnsafeMutableBytes { destination in
          CMBlockBufferCopyDataBytes(
            blockBuffer,
            atOffset: 0,
            dataLength: byteCount,
            destination: destination.baseAddress!
          )
        }
        guard status == kCMBlockBufferNoErr else { continue }

        // Int16 PCMを-1〜1へ正規化し，二乗平均平方根（RMS）を求める．
        for sample in samples {
          let normalizedSample = Double(sample) / Double(Int16.max)
          squaredSum += normalizedSample * normalizedSample
        }
        sampleCount += samples.count
      }

      guard !Task.isCancelled,
            reader.status != .failed,
            sampleCount > 0 else { return nil }
      return sqrt(squaredSum / Double(sampleCount))
    } catch {
      return nil
    }
  }
}

// MARK: - 差分切り替え再生の拍検出

/// 拍を読み取る動画と，共通タイムラインへの変換方法をまとめる．
nonisolated struct VariantBeatAnalysisSource: Sendable {
  let url: URL
  let duration: TimeInterval
  let timelineMapping: VariantTimelineMapping
  let logicalDuration: TimeInterval
}

nonisolated struct VariantBeatSwitchSchedule: Equatable, Sendable {
  let delay: TimeInterval
  let isBeatAligned: Bool
}

/// 通常の切り替え予定時刻を，近くにある拍へ吸着させる．
nonisolated enum VariantBeatSwitchScheduler {
  static let maximumSnapDistance: TimeInterval = 0.75
  private static let minimumFutureDelay: TimeInterval = 0.08

  static func schedule(
    baseInterval: TimeInterval,
    currentTime: TimeInterval,
    beatTimes: [TimeInterval]
  ) -> VariantBeatSwitchSchedule {
    let safeInterval = max(baseInterval, minimumFutureDelay)
    let desiredTime = currentTime + safeInterval
    let candidates = beatTimes.filter {
      $0 > currentTime + minimumFutureDelay
        && abs($0 - desiredTime) <= maximumSnapDistance
    }
    guard let nearestBeat = candidates.min(by: {
      let firstDistance = abs($0 - desiredTime)
      let secondDistance = abs($1 - desiredTime)
      if firstDistance == secondDistance { return $0 < $1 }
      return firstDistance < secondDistance
    }) else {
      return VariantBeatSwitchSchedule(
        delay: safeInterval,
        isBeatAligned: false
      )
    }
    return VariantBeatSwitchSchedule(
      delay: nearestBeat - currentTime,
      isBeatAligned: true
    )
  }
}

/// 音声の低域を重視した短時間エネルギーから，局所的な立ち上がりを拍候補として抽出する．
///
/// 音源分離ではないため，強い効果音を拍として拾う場合がある．その場合でも切り替え間隔は
/// 最大0.75秒しか動かさず，拍を検出できなければ従来の間隔へ戻す．
nonisolated enum VariantBeatAnalyzer {
  /// AVAssetReaderがPCM変換で受け付ける下限の8kHzを使用する．
  private static let analysisSampleRate = 8_000.0
  private static let energyFrameDuration: TimeInterval = 0.04
  private static let bassLowPassFrequency = 250.0
  private static let bassHighPassFrequency = 45.0
  private static let bassEnergyWeight = 0.8
  private static let fullBandEnergyWeight = 0.2
  private static let adaptiveWindowDuration: TimeInterval = 1.2
  private static let onsetHistoryDuration: TimeInterval = 0.20
  private static let minimumBeatSeparation: TimeInterval = 0.22
  private static let minimumOnsetStrength = 0.06
  private static let minimumDetectedBeatCount = 3

  /// 音声を持つ先頭の差分から拍を検出し，共通タイムライン上の時刻として返す．
  static func analyze(sources: [VariantBeatAnalysisSource]) async -> [TimeInterval] {
    for source in sources {
      guard !Task.isCancelled else { return [] }
      let startTime = max(
        0,
        source.timelineMapping.videoTime(forLogicalTime: 0)
      )
      let endTime = min(
        source.duration,
        source.timelineMapping.videoTime(
          forLogicalTime: source.logicalDuration
        )
      )
      guard endTime > startTime else { continue }

      let videoBeatTimes = await detectBeatTimes(
        url: source.url,
        range: startTime..<endTime
      )
      let logicalBeatTimes = makeUniqueLogicalBeatTimes(
        videoBeatTimes: videoBeatTimes,
        mapping: source.timelineMapping,
        logicalDuration: source.logicalDuration
      )
      if logicalBeatTimes.count >= minimumDetectedBeatCount {
        return logicalBeatTimes
      }
    }
    return []
  }

  /// テスト可能な純粋計算として，エネルギー列から拍時刻を求める．
  static func detectBeatTimes(
    energyFrames: [Double],
    hopDuration: TimeInterval,
    startTime: TimeInterval = 0
  ) -> [TimeInterval] {
    guard hopDuration > 0, energyFrames.count >= 5 else { return [] }
    let logEnergies = energyFrames.map {
      log1p(max(0, $0) * 100)
    }
    let historyFrameCount = max(
      2,
      Int((onsetHistoryDuration / hopDuration).rounded())
    )
    var onsetStrengths = [Double](repeating: 0, count: logEnergies.count)

    for index in logEnergies.indices {
      let lowerBound = max(0, index - historyFrameCount)
      guard lowerBound < index else { continue }
      let history = logEnergies[lowerBound..<index]
      let historyMean = history.reduce(0, +) / Double(history.count)
      onsetStrengths[index] = max(0, logEnergies[index] - historyMean)
    }

    let adaptiveRadius = max(
      2,
      Int((adaptiveWindowDuration / hopDuration / 2).rounded())
    )
    let refractoryFrames = max(
      1,
      Int((minimumBeatSeparation / hopDuration).rounded())
    )
    var beatIndices: [Int] = []

    for index in 1..<(onsetStrengths.count - 1) {
      let lowerBound = max(0, index - adaptiveRadius)
      let upperBound = min(onsetStrengths.count, index + adaptiveRadius + 1)
      let localValues = onsetStrengths[lowerBound..<upperBound]
      let localMean = localValues.reduce(0, +) / Double(localValues.count)
      let variance = localValues.reduce(0) {
        $0 + ($1 - localMean) * ($1 - localMean)
      } / Double(localValues.count)
      let threshold = localMean + max(minimumOnsetStrength, sqrt(variance) * 1.1)
      let strength = onsetStrengths[index]
      guard strength >= threshold,
            strength >= onsetStrengths[index - 1],
            strength > onsetStrengths[index + 1] else { continue }

      if let previousIndex = beatIndices.last,
         index - previousIndex < refractoryFrames {
        if strength > onsetStrengths[previousIndex] {
          beatIndices[beatIndices.count - 1] = index
        }
      } else {
        beatIndices.append(index)
      }
    }

    return beatIndices.map {
      startTime + (Double($0) + 0.5) * hopDuration
    }
  }

  private static func detectBeatTimes(
    url: URL,
    range: Range<TimeInterval>
  ) async -> [TimeInterval] {
    guard !Task.isCancelled else { return [] }
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
          let energyFrames = readEnergyFrames(
            asset: asset,
            track: track,
            range: range
          ) else {
      return []
    }
    return detectBeatTimes(
      energyFrames: energyFrames,
      hopDuration: energyFrameDuration,
      startTime: range.lowerBound
    )
  }

  private static func readEnergyFrames(
    asset: AVAsset,
    track: AVAssetTrack,
    range: Range<TimeInterval>
  ) -> [Double]? {
    do {
      let reader = try AVAssetReader(asset: asset)
      reader.timeRange = CMTimeRange(
        start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
        duration: CMTime(
          seconds: range.upperBound - range.lowerBound,
          preferredTimescale: 600
        )
      )
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: analysisSampleRate,
        AVNumberOfChannelsKey: 1
      ]
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
      output.alwaysCopiesSampleData = false
      guard reader.canAdd(output) else { return nil }
      reader.add(output)
      guard reader.startReading() else { return nil }
      defer { reader.cancelReading() }

      let samplesPerFrame = max(
        1,
        Int((analysisSampleRate * energyFrameDuration).rounded())
      )
      let lowPassAlpha = 1 - exp(
        -2 * Double.pi * bassLowPassFrequency / analysisSampleRate
      )
      let highPassAlpha = 1 - exp(
        -2 * Double.pi * bassHighPassFrequency / analysisSampleRate
      )
      var lowPassedSample = 0.0
      var subBassSample = 0.0
      var accumulatedEnergy = 0.0
      var accumulatedSampleCount = 0
      var energyFrames: [Double] = []
      let estimatedFrameCount = Int(
        (range.upperBound - range.lowerBound) / energyFrameDuration
      )
      energyFrames.reserveCapacity(max(0, estimatedFrameCount))

      while reader.status == .reading,
            !Task.isCancelled,
            let sampleBuffer = output.copyNextSampleBuffer() {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
          continue
        }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        guard byteCount > 0,
              byteCount.isMultiple(of: MemoryLayout<Int16>.size) else {
          continue
        }

        var samples = [Int16](
          repeating: 0,
          count: byteCount / MemoryLayout<Int16>.size
        )
        let status = samples.withUnsafeMutableBytes { destination in
          CMBlockBufferCopyDataBytes(
            blockBuffer,
            atOffset: 0,
            dataLength: byteCount,
            destination: destination.baseAddress!
          )
        }
        guard status == kCMBlockBufferNoErr else { continue }

        for sample in samples {
          let value = Double(sample) / Double(Int16.max)
          lowPassedSample += lowPassAlpha * (value - lowPassedSample)
          subBassSample += highPassAlpha * (value - subBassSample)
          let bassSample = lowPassedSample - subBassSample
          accumulatedEnergy += bassEnergyWeight * bassSample * bassSample
            + fullBandEnergyWeight * value * value
          accumulatedSampleCount += 1

          if accumulatedSampleCount == samplesPerFrame {
            energyFrames.append(
              sqrt(accumulatedEnergy / Double(accumulatedSampleCount))
            )
            accumulatedEnergy = 0
            accumulatedSampleCount = 0
          }
        }
      }

      if accumulatedSampleCount > 0 {
        energyFrames.append(
          sqrt(accumulatedEnergy / Double(accumulatedSampleCount))
        )
      }
      guard !Task.isCancelled,
            reader.status != .failed,
            !energyFrames.isEmpty else { return nil }
      return energyFrames
    } catch {
      return nil
    }
  }

  private static func makeUniqueLogicalBeatTimes(
    videoBeatTimes: [TimeInterval],
    mapping: VariantTimelineMapping,
    logicalDuration: TimeInterval
  ) -> [TimeInterval] {
    let sortedTimes = videoBeatTimes.map {
      mapping.logicalTime(forVideoTime: $0)
    }.filter {
      $0 >= 0 && $0 <= logicalDuration
    }.sorted()

    var uniqueTimes: [TimeInterval] = []
    for time in sortedTimes {
      if let previousTime = uniqueTimes.last,
         time - previousTime < minimumBeatSeparation / 2 {
        continue
      }
      uniqueTimes.append(time)
    }
    return uniqueTimes
  }
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    // clientInfo で渡された retain 済みの参照をそのままタップの保管領域へ移す。
    tapStorageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    guard let storage = MTAudioProcessingTapGetStorage(tap) as UnsafeMutableRawPointer? else { return }
    Unmanaged<AudioTapSettings>.fromOpaque(storage).release()
}

private let tapProcess: MTAudioProcessingTapProcessCallback = {
    tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in

    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
    )
    guard status == noErr else { return }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let settings = Unmanaged<AudioTapSettings>.fromOpaque(storage).takeUnretainedValue()
    let gains = settings.gains

    let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    let frameCount = Int(numberFramesOut.pointee)

    if buffers.count >= 2 {
        // 非インターリーブ（チャンネルごとに別バッファ）。AVFoundation の既定はこちら。
        applyGain(gains.left, to: buffers[0], frameCount: frameCount)
        applyGain(gains.right, to: buffers[1], frameCount: frameCount)
    } else if let buffer = buffers.first {
        if buffer.mNumberChannels == 2 {
            applyInterleavedStereoGain(gains, to: buffer, frameCount: frameCount)
        } else {
            // モノラル音声は左右へ分けようがないので、音量だけ反映する。
            applyGain((gains.left + gains.right) / 2, to: buffer, frameCount: frameCount)
        }
    }
}

private func applyGain(_ gain: Float, to buffer: AudioBuffer, frameCount: Int) {
    guard let data = buffer.mData else { return }
    let samples = data.assumingMemoryBound(to: Float.self)
    let count = min(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
    for i in 0..<count {
        samples[i] *= gain
    }
}

private func applyInterleavedStereoGain(_ gains: (left: Float, right: Float), to buffer: AudioBuffer, frameCount: Int) {
    guard let data = buffer.mData else { return }
    let samples = data.assumingMemoryBound(to: Float.self)
    let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
    let count = min(frameCount * 2, available)
    var i = 0
    while i + 1 < count {
        samples[i] *= gains.left
        samples[i + 1] *= gains.right
        i += 2
    }
}
