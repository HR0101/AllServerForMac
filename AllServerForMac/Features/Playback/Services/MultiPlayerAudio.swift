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

/// 推定したテンポ，小節位置，拍時刻をまとめた音楽上のグリッド．
nonisolated struct VariantBeatGrid: Equatable, Sendable {
  let beatTimes: [TimeInterval]
  let bpm: Double
  let confidence: Double
  let beatsPerBar: Int

  /// 1拍あたりの秒数．細かい刻みの最小間隔を決めるのに使う．
  var beatDuration: TimeInterval {
    bpm > 0 ? 60 / bpm : 0
  }
}

/// 小節先頭を基準に，ユーザーが選んだ拍数ごとの境界を次の切り替え時刻にする．
///
/// 1拍より短い刻み（1/2拍・1/4拍）も選べるよう，境界は1/4拍単位で数える．検出した拍と拍の
/// あいだは等分した位置を使うので，テンポが少し揺れても実際の拍にぶら下がった刻みになる．
nonisolated enum VariantBeatSwitchScheduler {
  /// 境界を数える解像度．1拍を4等分し，1/4拍までの刻みを扱えるようにする．
  static let quarterBeatsPerBeat = 4
  /// 拍を検出できないときの下限．
  private static let minimumFallbackDelay: TimeInterval = 0.20
  /// 時計の刻み（0.025秒）より短い予定を立てても取りこぼすため，これ以上先の境界だけを見る．
  private static let minimumBoundaryLookahead: TimeInterval = 0.03

  static func schedule(
    baseInterval: TimeInterval,
    currentTime: TimeInterval,
    beatGrid: VariantBeatGrid?,
    quarterBeatsPerSwitch: Int
  ) -> VariantBeatSwitchSchedule {
    let safeInterval = max(baseInterval, minimumFallbackDelay)
    let fallback = VariantBeatSwitchSchedule(
      delay: safeInterval,
      isBeatAligned: false
    )
    guard let beatGrid, beatGrid.beatTimes.count >= 2 else { return fallback }

    let step = max(1, quarterBeatsPerSwitch)
    let lookahead = boundaryLookahead(
      step: step,
      beatDuration: beatGrid.beatDuration
    )
    let threshold = currentTime + lookahead
    let lastPosition =
      (beatGrid.beatTimes.count - 1) * quarterBeatsPerBeat

    var position = firstBoundaryPosition(
      after: threshold,
      step: step,
      beatTimes: beatGrid.beatTimes
    )
    while position <= lastPosition {
      let boundaryTime = time(
        atQuarterBeat: position,
        beatTimes: beatGrid.beatTimes
      )
      if boundaryTime > threshold {
        return VariantBeatSwitchSchedule(
          delay: boundaryTime - currentTime,
          isBeatAligned: true
        )
      }
      position += step
    }
    return fallback
  }

  /// 直前に切り替えた境界をもう一度拾わないよう，刻みの半分までは先を見る．
  private static func boundaryLookahead(
    step: Int,
    beatDuration: TimeInterval
  ) -> TimeInterval {
    guard beatDuration > 0 else { return minimumFallbackDelay }
    let stepDuration =
      beatDuration * Double(step) / Double(quarterBeatsPerBeat)
    return min(
      minimumFallbackDelay,
      max(minimumBoundaryLookahead, stepDuration / 2)
    )
  }

  /// 指定時刻以降で最初に来る境界の位置（1/4拍単位）を求める．
  private static func firstBoundaryPosition(
    after time: TimeInterval,
    step: Int,
    beatTimes: [TimeInterval]
  ) -> Int {
    guard let nextBeatIndex = beatTimes.firstIndex(where: { $0 > time }) else {
      return .max
    }
    // 直前の拍の位置まで戻してから刻みへ丸めることで，拍と拍のあいだの境界も拾う．
    let previousBeatPosition =
      max(0, nextBeatIndex - 1) * quarterBeatsPerBeat
    return (previousBeatPosition / step) * step
  }

  /// 1/4拍単位の位置を，拍と拍のあいだを等分した時刻へ変換する．
  private static func time(
    atQuarterBeat position: Int,
    beatTimes: [TimeInterval]
  ) -> TimeInterval {
    let beatIndex = position / quarterBeatsPerBeat
    let remainder = position % quarterBeatsPerBeat
    guard beatIndex < beatTimes.count else { return .infinity }
    guard remainder > 0, beatIndex + 1 < beatTimes.count else {
      return beatTimes[beatIndex]
    }
    let beatInterval = beatTimes[beatIndex + 1] - beatTimes[beatIndex]
    return beatTimes[beatIndex]
      + beatInterval * Double(remainder) / Double(quarterBeatsPerBeat)
  }
}

/// 周波数帯域ごとの立ち上がりからテンポを推定し，4拍子の小節先頭にそろえた拍グリッドを作る．
///
/// 単発の効果音をそのまま拍とせず，一定間隔で繰り返す成分を自己相関で探す．音源分離では
/// ないためBGMより大きい効果音が続く素材では誤る可能性があり，信頼度が低ければ通常間隔へ戻す．
nonisolated enum VariantBeatAnalyzer {
  private struct EnergyFrame: Sendable {
    let bass: Double
    let mid: Double
    let high: Double
  }

  private struct TempoEstimate {
    let frameInterval: Int
    let correlation: Double
  }

  private static let analysisSampleRate = 22_050.0
  private static let energyFrameDuration: TimeInterval = 0.02
  private static let bassCrossoverFrequency = 180.0
  private static let midCrossoverFrequency = 2_000.0
  private static let bassOnsetWeight = 0.55
  private static let midOnsetWeight = 0.30
  private static let highOnsetWeight = 0.15
  private static let adaptiveWindowDuration: TimeInterval = 1.0
  private static let minimumTempo = 60.0
  private static let maximumTempo = 200.0
  private static let minimumDetectedBeatCount = 4
  private static let minimumTempoCorrelation = 0.12
  private static let minimumAcceptedConfidence = 0.20
  private static let preferredConfidence = 0.72
  /// 長尺動画を差分本数ぶん読み直さないよう，候補比較は先頭3本までに制限する．
  private static let maximumAnalysisSourceCount = 3
  private static let assumedBeatsPerBar = 4
  private static let peakSnapDuration: TimeInterval = 0.10

  /// 音声を持つ差分を順に調べ，最も信頼できる拍グリッドを共通タイムライン上で返す．
  static func analyze(sources: [VariantBeatAnalysisSource]) async -> VariantBeatGrid? {
    var bestGrid: VariantBeatGrid?
    for source in sources.prefix(maximumAnalysisSourceCount) {
      guard !Task.isCancelled else { return nil }
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

      guard let videoGrid = await detectBeatGrid(
        url: source.url,
        range: startTime..<endTime
      ), let logicalGrid = makeLogicalBeatGrid(
        videoGrid: videoGrid,
        mapping: source.timelineMapping,
        logicalDuration: source.logicalDuration
      ) else {
        continue
      }
      if bestGrid == nil || logicalGrid.confidence > bestGrid?.confidence ?? 0 {
        bestGrid = logicalGrid
      }
      if logicalGrid.confidence >= preferredConfidence {
        break
      }
    }
    guard let bestGrid,
          bestGrid.confidence >= minimumAcceptedConfidence else { return nil }
    return bestGrid
  }

  /// テスト用に，単一エネルギー列からテンポ補正済みの拍時刻を求める．
  static func detectBeatTimes(
    energyFrames: [Double],
    hopDuration: TimeInterval,
    startTime: TimeInterval = 0
  ) -> [TimeInterval] {
    let frames = energyFrames.map {
      EnergyFrame(bass: $0, mid: $0, high: $0)
    }
    return makeBeatGrid(
      energyFrames: frames,
      hopDuration: hopDuration,
      startTime: startTime
    )?.beatTimes ?? []
  }

  /// テスト用に，推定したBPMと信頼度を含む拍グリッドを返す．
  static func detectBeatGrid(
    energyFrames: [Double],
    hopDuration: TimeInterval,
    startTime: TimeInterval = 0
  ) -> VariantBeatGrid? {
    let frames = energyFrames.map {
      EnergyFrame(bass: $0, mid: $0, high: $0)
    }
    return makeBeatGrid(
      energyFrames: frames,
      hopDuration: hopDuration,
      startTime: startTime
    )
  }

  private static func makeBeatGrid(
    energyFrames: [EnergyFrame],
    hopDuration: TimeInterval,
    startTime: TimeInterval
  ) -> VariantBeatGrid? {
    guard hopDuration > 0, energyFrames.count >= 20 else { return nil }
    let onsetStrengths = makeOnsetStrengths(
      energyFrames: energyFrames,
      hopDuration: hopDuration
    )
    guard let tempo = estimateTempo(
      onsetStrengths: onsetStrengths,
      hopDuration: hopDuration
    ) else { return nil }
    let beatIndices = makeTempoAlignedBeatIndices(
      onsetStrengths: onsetStrengths,
      frameInterval: tempo.frameInterval,
      hopDuration: hopDuration
    )
    guard beatIndices.count >= minimumDetectedBeatCount else { return nil }

    let downbeatOffset = estimateDownbeatOffset(
      beatIndices: beatIndices,
      onsetStrengths: onsetStrengths
    )
    let alignedBeatIndices = Array(beatIndices.dropFirst(downbeatOffset))
    guard alignedBeatIndices.count >= minimumDetectedBeatCount else { return nil }
    let beatTimes = alignedBeatIndices.map {
      startTime + (Double($0) + 0.5) * hopDuration
    }
    let bpm = refinedBPM(
      beatTimes: beatTimes,
      fallback: 60 / (Double(tempo.frameInterval) * hopDuration)
    )
    let confidence = analysisConfidence(
      correlation: tempo.correlation,
      beatIndices: alignedBeatIndices,
      expectedFrameInterval: tempo.frameInterval
    )
    return VariantBeatGrid(
      beatTimes: beatTimes,
      bpm: bpm,
      confidence: confidence,
      beatsPerBar: assumedBeatsPerBar
    )
  }

  /// 低域・中域・高域それぞれの正方向変化を混ぜ，音色が違うBGMでも立ち上がりを残す．
  private static func makeOnsetStrengths(
    energyFrames: [EnergyFrame],
    hopDuration: TimeInterval
  ) -> [Double] {
    let logFrames = energyFrames.map { frame in
      EnergyFrame(
        bass: log1p(max(0, frame.bass) * 100),
        mid: log1p(max(0, frame.mid) * 100),
        high: log1p(max(0, frame.high) * 100)
      )
    }
    var rawOnsets = [Double](repeating: 0, count: logFrames.count)
    for index in 1..<logFrames.count {
      rawOnsets[index] =
        bassOnsetWeight * max(0, logFrames[index].bass - logFrames[index - 1].bass)
        + midOnsetWeight * max(0, logFrames[index].mid - logFrames[index - 1].mid)
        + highOnsetWeight * max(0, logFrames[index].high - logFrames[index - 1].high)
    }

    let adaptiveRadius = max(
      2,
      Int((adaptiveWindowDuration / hopDuration / 2).rounded())
    )
    var adaptiveOnsets = [Double](repeating: 0, count: rawOnsets.count)
    for index in rawOnsets.indices {
      let lowerBound = max(0, index - adaptiveRadius)
      let upperBound = min(rawOnsets.count, index + adaptiveRadius + 1)
      let localValues = rawOnsets[lowerBound..<upperBound]
      let localMean = localValues.reduce(0, +) / Double(localValues.count)
      adaptiveOnsets[index] = max(0, rawOnsets[index] - localMean * 0.5)
    }

    guard adaptiveOnsets.count >= 3 else { return adaptiveOnsets }
    var smoothed = adaptiveOnsets
    for index in 1..<(adaptiveOnsets.count - 1) {
      smoothed[index] = adaptiveOnsets[index - 1] * 0.25
        + adaptiveOnsets[index] * 0.5
        + adaptiveOnsets[index + 1] * 0.25
    }
    return smoothed
  }

  /// 自己相関に2倍周期を加味し，半周期にも強い一致がある遅い候補は減点する．
  private static func estimateTempo(
    onsetStrengths: [Double],
    hopDuration: TimeInterval
  ) -> TempoEstimate? {
    let minimumLag = max(
      1,
      Int((60 / maximumTempo / hopDuration).rounded())
    )
    let maximumLag = min(
      onsetStrengths.count / 3,
      Int((60 / minimumTempo / hopDuration).rounded())
    )
    guard minimumLag <= maximumLag else { return nil }

    var correlations: [Int: Double] = [:]
    for lag in minimumLag...min(maximumLag * 2, onsetStrengths.count / 2) {
      correlations[lag] = normalizedCorrelation(
        values: onsetStrengths,
        lag: lag
      )
    }

    var bestLag = minimumLag
    var bestCombinedScore = -Double.infinity
    for lag in minimumLag...maximumLag {
      let correlation = correlations[lag] ?? 0
      let doublePeriodCorrelation = correlations[lag * 2] ?? 0
      let halfPeriodCorrelation = correlations[max(1, lag / 2)] ?? 0
      let combinedScore = correlation
        + doublePeriodCorrelation * 0.25
        - halfPeriodCorrelation * 0.25
      if combinedScore > bestCombinedScore {
        bestCombinedScore = combinedScore
        bestLag = lag
      }
    }
    let bestCorrelation = correlations[bestLag] ?? 0
    guard bestCorrelation >= minimumTempoCorrelation else { return nil }
    return TempoEstimate(
      frameInterval: bestLag,
      correlation: bestCorrelation
    )
  }

  private static func normalizedCorrelation(
    values: [Double],
    lag: Int
  ) -> Double {
    guard lag > 0, lag < values.count else { return 0 }
    var productSum = 0.0
    var currentSquaredSum = 0.0
    var delayedSquaredSum = 0.0
    for index in lag..<values.count {
      let current = values[index]
      let delayed = values[index - lag]
      productSum += current * delayed
      currentSquaredSum += current * current
      delayedSquaredSum += delayed * delayed
    }
    let denominator = sqrt(currentSquaredSum * delayedSquaredSum)
    guard denominator > 0 else { return 0 }
    return productSum / denominator
  }

  /// 推定周期の各位相を採点し，期待位置の近くで最も強い立ち上がりへ微調整する．
  private static func makeTempoAlignedBeatIndices(
    onsetStrengths: [Double],
    frameInterval: Int,
    hopDuration: TimeInterval
  ) -> [Int] {
    guard frameInterval > 0 else { return [] }
    var bestPhase = 0
    var bestPhaseScore = -Double.infinity
    for phase in 0..<min(frameInterval, onsetStrengths.count) {
      var score = 0.0
      var index = phase
      while index < onsetStrengths.count {
        score += pow(onsetStrengths[index], 1.25)
        index += frameInterval
      }
      if score > bestPhaseScore {
        bestPhaseScore = score
        bestPhase = phase
      }
    }

    let snapRadius = max(1, Int((peakSnapDuration / hopDuration).rounded()))
    var beatIndices: [Int] = []
    var expectedIndex = bestPhase
    while expectedIndex < onsetStrengths.count {
      let lowerBound = max(0, expectedIndex - snapRadius)
      let upperBound = min(onsetStrengths.count - 1, expectedIndex + snapRadius)
      let snappedIndex = (lowerBound...upperBound).max {
        onsetStrengths[$0] < onsetStrengths[$1]
      } ?? expectedIndex
      if beatIndices.last != snappedIndex {
        beatIndices.append(snappedIndex)
      }
      expectedIndex += frameInterval
    }
    return beatIndices
  }

  /// 4拍のうち平均アクセントが最も強い位相を，小節の1拍目候補とする．
  private static func estimateDownbeatOffset(
    beatIndices: [Int],
    onsetStrengths: [Double]
  ) -> Int {
    guard beatIndices.count >= assumedBeatsPerBar else { return 0 }
    var bestOffset = 0
    var bestScore = -Double.infinity
    for offset in 0..<assumedBeatsPerBar {
      let values = stride(
        from: offset,
        to: beatIndices.count,
        by: assumedBeatsPerBar
      ).map { onsetStrengths[beatIndices[$0]] }
      guard !values.isEmpty else { continue }
      let score = values.reduce(0, +) / Double(values.count)
      if score > bestScore {
        bestScore = score
        bestOffset = offset
      }
    }
    return bestOffset
  }

  private static func analysisConfidence(
    correlation: Double,
    beatIndices: [Int],
    expectedFrameInterval: Int
  ) -> Double {
    guard beatIndices.count >= 2, expectedFrameInterval > 0 else { return 0 }
    let deviations = zip(beatIndices.dropFirst(), beatIndices).map {
      abs(Double($0 - $1 - expectedFrameInterval))
        / Double(expectedFrameInterval)
    }
    let meanDeviation = deviations.reduce(0, +) / Double(deviations.count)
    let regularity = max(0, 1 - meanDeviation)
    return min(1, max(0, correlation * 0.75 + regularity * 0.25))
  }

  private static func refinedBPM(
    beatTimes: [TimeInterval],
    fallback: Double
  ) -> Double {
    let intervals = zip(beatTimes.dropFirst(), beatTimes).map(-)
      .filter { $0 > 0 }
      .sorted()
    guard !intervals.isEmpty else { return fallback }
    let median = intervals[intervals.count / 2]
    return median > 0 ? 60 / median : fallback
  }

  private static func detectBeatGrid(
    url: URL,
    range: Range<TimeInterval>
  ) async -> VariantBeatGrid? {
    guard !Task.isCancelled else { return nil }
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
          let energyFrames = readEnergyFrames(
            asset: asset,
            track: track,
            range: range
          ) else {
      return nil
    }
    return makeBeatGrid(
      energyFrames: energyFrames,
      hopDuration: energyFrameDuration,
      startTime: range.lowerBound
    )
  }

  private static func readEnergyFrames(
    asset: AVAsset,
    track: AVAssetTrack,
    range: Range<TimeInterval>
  ) -> [EnergyFrame]? {
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
      let bassAlpha = 1 - exp(
        -2 * Double.pi * bassCrossoverFrequency / analysisSampleRate
      )
      let midAlpha = 1 - exp(
        -2 * Double.pi * midCrossoverFrequency / analysisSampleRate
      )
      var bassLowPassedSample = 0.0
      var midLowPassedSample = 0.0
      var accumulatedBassEnergy = 0.0
      var accumulatedMidEnergy = 0.0
      var accumulatedHighEnergy = 0.0
      var accumulatedSampleCount = 0
      var energyFrames: [EnergyFrame] = []
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
          bassLowPassedSample += bassAlpha * (value - bassLowPassedSample)
          midLowPassedSample += midAlpha * (value - midLowPassedSample)
          let bassSample = bassLowPassedSample
          let midSample = midLowPassedSample - bassLowPassedSample
          let highSample = value - midLowPassedSample
          accumulatedBassEnergy += bassSample * bassSample
          accumulatedMidEnergy += midSample * midSample
          accumulatedHighEnergy += highSample * highSample
          accumulatedSampleCount += 1

          if accumulatedSampleCount == samplesPerFrame {
            energyFrames.append(
              makeEnergyFrame(
                bassEnergy: accumulatedBassEnergy,
                midEnergy: accumulatedMidEnergy,
                highEnergy: accumulatedHighEnergy,
                sampleCount: accumulatedSampleCount
              )
            )
            accumulatedBassEnergy = 0
            accumulatedMidEnergy = 0
            accumulatedHighEnergy = 0
            accumulatedSampleCount = 0
          }
        }
      }

      if accumulatedSampleCount > 0 {
        energyFrames.append(
          makeEnergyFrame(
            bassEnergy: accumulatedBassEnergy,
            midEnergy: accumulatedMidEnergy,
            highEnergy: accumulatedHighEnergy,
            sampleCount: accumulatedSampleCount
          )
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

  private static func makeEnergyFrame(
    bassEnergy: Double,
    midEnergy: Double,
    highEnergy: Double,
    sampleCount: Int
  ) -> EnergyFrame {
    let divisor = Double(max(1, sampleCount))
    return EnergyFrame(
      bass: sqrt(bassEnergy / divisor),
      mid: sqrt(midEnergy / divisor),
      high: sqrt(highEnergy / divisor)
    )
  }

  private static func makeLogicalBeatGrid(
    videoGrid: VariantBeatGrid,
    mapping: VariantTimelineMapping,
    logicalDuration: TimeInterval
  ) -> VariantBeatGrid? {
    let sortedTimes = videoGrid.beatTimes.map {
      mapping.logicalTime(forVideoTime: $0)
    }.filter {
      $0 >= 0 && $0 <= logicalDuration
    }.sorted()

    var uniqueTimes: [TimeInterval] = []
    for time in sortedTimes {
      if let previousTime = uniqueTimes.last,
         time - previousTime < energyFrameDuration {
        continue
      }
      uniqueTimes.append(time)
    }
    guard uniqueTimes.count >= minimumDetectedBeatCount else { return nil }
    return VariantBeatGrid(
      beatTimes: uniqueTimes,
      bpm: refinedBPM(beatTimes: uniqueTimes, fallback: videoGrid.bpm),
      confidence: videoGrid.confidence,
      beatsPerBar: videoGrid.beatsPerBar
    )
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
