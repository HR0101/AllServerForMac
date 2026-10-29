import AVFoundation
import CoreGraphics
import Foundation

// MARK: - 差分動画（同じ映像の衣装違い・状態違い）の検出
//
// 「似ているものを探す」(`SimilarMediaViewModel`) はサムネイル1枚だけを見て、
// ほぼ同じものを消す候補として拾う。こちらは目的が逆で、
// 「同じ尺・同じ動きで、絵の一部だけが差し替わった別バージョン」を **残したまま** 見つける。
// 見つけたグループはそのまま差分切り替え再生（`VariantSwitchPlayerView`）へ渡す。
//
// 判定は2段階。
//  1. 尺で束ねる。差分書き出しは同じタイムラインから出すので尺がフレーム単位で揃う。
//     ここで大半の組み合わせが落ちるため、重いフレーム展開をごく一部にだけ絞れる。
//  2. 束の中だけで、同じ相対位置から取った数フレームの知覚ハッシュを突き合わせる。
//     衣装や肌の差し替えは dHash の一部ビットしか動かさないので、
//     まったく別の動画（距離 20〜30 前後）とははっきり差が付く。
//  そのうえで、ファイル名の近さ（`TitleSimilarity`）でしきい値を少し上下させる。
//  名前は「無関係かどうか」をよく言い当てる一方で「別キャラかどうか」は言い当てられないので、
//  主役はあくまでフレームで、名前は効き幅を絞った補助に留めている。

/// 動画1本ぶんの指紋。同じ相対位置から取った複数フレームの知覚ハッシュを、その順番のまま持つ。
struct VideoFrameSignature: Equatable, Sendable {
    let hashes: [PerceptualHash]

    /// 同じ位置のフレームどうしを突き合わせた平均ハミング距離（0〜64）。
    /// 枚数が違うものは位置が対応しないので比較しない。
    func averageDistance(to other: VideoFrameSignature) -> Double? {
        guard !hashes.isEmpty, hashes.count == other.hashes.count else { return nil }
        let total = zip(hashes, other.hashes).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        return Double(total) / Double(hashes.count)
    }
}

enum VariantFrameSampler {
    /// フレームを取り出す位置（尺に対する割合）。
    /// 先頭と末尾は黒フレームやフェードで潰れて、どの動画も同じ絵になってしまうため避ける。
    static let samplePositions: [Double] = [0.08, 0.24, 0.40, 0.56, 0.72, 0.88]

    /// 動画から指紋を作る。1枚でも取れなければ位置が対応しなくなるので nil を返す。
    ///
    /// 比べたいのは構図だけなので `maximumSize` で小さく起こす（4K のまま展開すると
    /// 1枚あたり数十MB になり、数本ぶんでメモリも時間も一気に膨らむ）。
    /// 一方で時刻の誤差は許さない。近いフレームで代用されると、同じ位置を比べているつもりが
    /// 動きのぶんだけずれて、本物の差分どうしでも距離が開いてしまう。
    nonisolated static func signature(forVideoAt url: URL, duration: TimeInterval) async -> VideoFrameSignature? {
        guard duration > 0 else { return nil }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var hashes: [PerceptualHash] = []
        hashes.reserveCapacity(samplePositions.count)
        for position in samplePositions {
            if Task.isCancelled { return nil }
            let time = CMTime(seconds: duration * position, preferredTimescale: 600)
            guard let cgImage = try? await generator.image(at: time).image,
                  let hash = PerceptualHasher.hash(of: cgImage) else { return nil }
            hashes.append(hash)
        }
        return VideoFrameSignature(hashes: hashes)
    }
}

// MARK: - 尺が違う動画の時間位置合わせ

/// 同じタイムラインから作られた動画どうしの開始位置の差を求める．
/// 正の `offset` は「比較対象を基準動画より先へ進める」ことを表す．
nonisolated struct VariantTimeOffsetEstimate: Equatable, Sendable {
  let offset: TimeInterval
  let score: Double
  let overlapDuration: TimeInterval
}

/// 共通タイムライン上の時刻と，個別動画内の対応時刻を結ぶ折れ線．
/// 複数の類似場面をアンカーとして持つため，途中に別カットが入っても後続で同期へ戻れる．
nonisolated struct VariantTimelineMapping: Equatable, Sendable {
  nonisolated struct Anchor: Equatable, Sendable {
    let logicalTime: TimeInterval
    let videoTime: TimeInterval
  }

  let anchors: [Anchor]

  init(anchors: [Anchor]) {
    let sorted = anchors.sorted {
      if $0.logicalTime == $1.logicalTime {
        return $0.videoTime < $1.videoTime
      }
      return $0.logicalTime < $1.logicalTime
    }
    var monotonic: [Anchor] = []
    for anchor in sorted where anchor.logicalTime.isFinite && anchor.videoTime.isFinite {
      guard let previous = monotonic.last else {
        monotonic.append(anchor)
        continue
      }
      guard anchor.logicalTime > previous.logicalTime,
            anchor.videoTime > previous.videoTime else { continue }
      monotonic.append(anchor)
    }
    self.anchors = monotonic
  }

  static func identity(duration: TimeInterval) -> VariantTimelineMapping {
    VariantTimelineMapping(
      anchors: [
        Anchor(logicalTime: 0, videoTime: 0),
        Anchor(logicalTime: max(duration, 0.001), videoTime: max(duration, 0.001)),
      ]
    )
  }

  func videoTime(forLogicalTime logicalTime: TimeInterval) -> TimeInterval {
    interpolate(
      value: logicalTime,
      source: { $0.logicalTime },
      destination: { $0.videoTime }
    )
  }

  func logicalTime(forVideoTime videoTime: TimeInterval) -> TimeInterval {
    interpolate(
      value: videoTime,
      source: { $0.videoTime },
      destination: { $0.logicalTime }
    )
  }

  private func interpolate(
    value: TimeInterval,
    source: (Anchor) -> TimeInterval,
    destination: (Anchor) -> TimeInterval
  ) -> TimeInterval {
    guard let first = anchors.first else { return max(0, value) }
    guard anchors.count > 1, let last = anchors.last else {
      return destination(first)
    }
    if value <= source(first) { return destination(first) }
    if value >= source(last) { return destination(last) }

    guard let upperIndex = anchors.firstIndex(where: { source($0) >= value }),
          upperIndex > 0 else { return destination(first) }
    let lower = anchors[upperIndex - 1]
    let upper = anchors[upperIndex]
    let sourceSpan = source(upper) - source(lower)
    guard sourceSpan > 0 else { return destination(lower) }
    let ratio = (value - source(lower)) / sourceSpan
    return destination(lower) + (destination(upper) - destination(lower)) * ratio
  }
}

nonisolated struct VariantTimelineMatch: Equatable, Sendable {
  let mapping: VariantTimelineMapping
  let score: Double
}

/// 内容で位置合わせした差分再生に渡す結果．
nonisolated struct VariantContentAlignment: Equatable, Sendable {
  struct Entry: Equatable, Sendable {
    let videoID: UUID
    let mapping: VariantTimelineMapping
    let score: Double

    var startTime: TimeInterval { mapping.videoTime(forLogicalTime: 0) }
  }

  let entries: [Entry]
  let commonDuration: TimeInterval
}

nonisolated enum VariantContentAlignmentError: LocalizedError, Equatable {
  case insufficientVideos
  case unreadableVideo(String)
  case noCommonScene(String)
  case commonSectionTooShort

  var errorDescription: String? {
    switch self {
    case .insufficientVideos:
      return "位置合わせには2本以上の動画が必要です．"
    case .unreadableVideo(let filename):
      return "「\(filename)」から比較用フレームを読み取れませんでした．"
    case .noCommonScene(let filename):
      return "「\(filename)」との共通場面を十分な確度で見つけられませんでした．"
    case .commonSectionTooShort:
      return "位置合わせ後に共通して再生できる区間が短すぎます．"
    }
  }
}

nonisolated enum VariantContentAligner {
  struct Input: Sendable {
    let id: UUID
    let filename: String
    let url: URL
    let duration: TimeInterval
  }

  private struct TemporalSignature: Sendable {
    let hashes: [PerceptualHash]
  }

  /// 粗い探索は1秒刻みにして，数分の動画でも数百フレームに抑える．
  private static let coarseInterval: TimeInterval = 1
  /// アルバム全体から候補を探す段階ではフレーム数を半分に抑える．
  private static let discoveryInterval: TimeInterval = 2
  private static let sampleInset: TimeInterval = 0.5
  private static let maximumAcceptedScore: Double = 20
  private static let maximumAnchorDistance = 20
  private static let sequenceGapPenalty: Float = 3
  private static let minimumMatchedAnchorCount = 10
  private static let minimumCommonDuration: TimeInterval = 10
  private static let refinementStep: TimeInterval = 1.0 / 30.0
  private static let refinementRadius: TimeInterval = 0.5
  private static let refinementAnchorCount = 12
  private static let imageTimescale: CMTimeScale = 600

  /// 2本以上の動画を先頭の動画へ合わせ，共通タイムラインの開始位置と長さを返す．
  nonisolated static func align(
    inputs: [Input]
  ) async -> Result<VariantContentAlignment, VariantContentAlignmentError> {
    guard inputs.count >= 2 else { return .failure(.insufficientVideos) }

    var signatures: [UUID: TemporalSignature] = [:]
    for input in inputs {
      guard !Task.isCancelled else { return .failure(.noCommonScene(input.filename)) }
      guard let signature = await temporalSignature(for: input) else {
        return .failure(.unreadableVideo(input.filename))
      }
      signatures[input.id] = signature
    }

    let reference = inputs[0]
    guard let referenceSignature = signatures[reference.id] else {
      return .failure(.unreadableVideo(reference.filename))
    }

    var matches: [UUID: VariantTimelineMatch] = [:]

    for candidate in inputs.dropFirst() {
      guard let candidateSignature = signatures[candidate.id],
            let coarseMatch = matchTimeline(
              reference: referenceSignature.hashes,
              candidate: candidateSignature.hashes,
              sampleInterval: coarseInterval,
              sampleInset: sampleInset
            ) else {
        return .failure(.noCommonScene(candidate.filename))
      }

      let refinement = await refineFractionalOffset(
        coarseMatch.mapping.anchors,
        reference: reference,
        candidate: candidate
      )
      let fractionalOffset = refinement?.offset ?? 0
      let refinedScore = refinement?.score ?? coarseMatch.score
      guard refinedScore <= maximumAcceptedScore else {
        return .failure(.noCommonScene(candidate.filename))
      }
      let refinedMapping = VariantTimelineMapping(
        anchors: coarseMatch.mapping.anchors.map {
          VariantTimelineMapping.Anchor(
            logicalTime: $0.logicalTime,
            videoTime: $0.videoTime + fractionalOffset
          )
        }
      )
      matches[candidate.id] = VariantTimelineMatch(
        mapping: refinedMapping,
        score: refinedScore
      )
    }

    let referenceStart = matches.values.compactMap {
      $0.mapping.anchors.first?.logicalTime
    }.max() ?? 0
    let referenceEnd = min(
      reference.duration,
      matches.values.compactMap { $0.mapping.anchors.last?.logicalTime }.min()
        ?? reference.duration
    )
    let commonDuration = referenceEnd - referenceStart
    guard commonDuration >= minimumCommonDuration else {
      return .failure(.commonSectionTooShort)
    }

    var entries: [VariantContentAlignment.Entry] = [
      VariantContentAlignment.Entry(
        videoID: reference.id,
        mapping: VariantTimelineMapping(
          anchors: [
            VariantTimelineMapping.Anchor(logicalTime: 0, videoTime: referenceStart),
            VariantTimelineMapping.Anchor(
              logicalTime: commonDuration,
              videoTime: referenceEnd
            ),
          ]
        ),
        score: 0
      )
    ]
    for candidate in inputs.dropFirst() {
      guard let match = matches[candidate.id],
            let clippedMapping = clippedMapping(
              match.mapping,
              referenceStart: referenceStart,
              referenceEnd: referenceEnd,
              videoDuration: candidate.duration
            ) else {
        return .failure(.noCommonScene(candidate.filename))
      }
      entries.append(
        VariantContentAlignment.Entry(
          videoID: candidate.id,
          mapping: clippedMapping,
          score: match.score
        )
      )
    }
    return .success(
      VariantContentAlignment(entries: entries, commonDuration: commonDuration)
    )
  }

  /// 知覚ハッシュ列を局所シーケンス照合し，順序を保った複数の類似ポイントを返す．
  /// 挿入カットはギャップとして飛ばすため，単一オフセットでは扱えない尺差にも追従できる．
  nonisolated static func matchTimeline(
    reference: [PerceptualHash],
    candidate: [PerceptualHash],
    sampleInterval: TimeInterval,
    sampleInset: TimeInterval = 0
  ) -> VariantTimelineMatch? {
    guard sampleInterval > 0, !reference.isEmpty, !candidate.isEmpty else { return nil }

    let columnCount = candidate.count + 1
    let cellCount = (reference.count + 1) * columnCount
    var scores = [Float](repeating: 0, count: cellCount)
    var directions = [UInt8](repeating: 0, count: cellCount)
    var bestCell = 0
    var bestScore: Float = 0

    for referenceIndex in 1...reference.count {
      for candidateIndex in 1...candidate.count {
        let cell = referenceIndex * columnCount + candidateIndex
        let distance = reference[referenceIndex - 1].distance(
          to: candidate[candidateIndex - 1]
        )
        let matchReward = Float(maximumAnchorDistance - distance)
        let diagonal = scores[cell - columnCount - 1] + matchReward
        let skipReference = scores[cell - columnCount] - sequenceGapPenalty
        let skipCandidate = scores[cell - 1] - sequenceGapPenalty

        if diagonal > 0, diagonal >= skipReference, diagonal >= skipCandidate {
          scores[cell] = diagonal
          directions[cell] = 1
        } else if skipReference > 0, skipReference >= skipCandidate {
          scores[cell] = skipReference
          directions[cell] = 2
        } else if skipCandidate > 0 {
          scores[cell] = skipCandidate
          directions[cell] = 3
        }
        if scores[cell] > bestScore {
          bestScore = scores[cell]
          bestCell = cell
        }
      }
    }

    guard bestScore > 0 else { return nil }
    var referenceIndex = bestCell / columnCount
    var candidateIndex = bestCell % columnCount
    var anchors: [VariantTimelineMapping.Anchor] = []
    var distances: [Int] = []

    while referenceIndex > 0, candidateIndex > 0 {
      let cell = referenceIndex * columnCount + candidateIndex
      guard scores[cell] > 0 else { break }
      switch directions[cell] {
      case 1:
        let distance = reference[referenceIndex - 1].distance(
          to: candidate[candidateIndex - 1]
        )
        if distance <= maximumAnchorDistance {
          anchors.append(
            VariantTimelineMapping.Anchor(
              logicalTime: sampleInset + Double(referenceIndex - 1) * sampleInterval,
              videoTime: sampleInset + Double(candidateIndex - 1) * sampleInterval
            )
          )
          distances.append(distance)
        }
        referenceIndex -= 1
        candidateIndex -= 1
      case 2:
        referenceIndex -= 1
      case 3:
        candidateIndex -= 1
      default:
        referenceIndex = 0
        candidateIndex = 0
      }
    }

    anchors.reverse()
    guard anchors.count >= minimumMatchedAnchorCount,
          let first = anchors.first,
          let last = anchors.last else { return nil }
    let shorterDuration = Double(min(reference.count, candidate.count)) * sampleInterval
    let minimumSpan = max(minimumCommonDuration, min(shorterDuration * 0.25, 60))
    guard last.logicalTime - first.logicalTime >= minimumSpan,
          last.videoTime - first.videoTime >= minimumSpan else { return nil }

    let score = trimmedMean(distances)
    guard score <= maximumAcceptedScore else { return nil }
    return VariantTimelineMatch(
      mapping: VariantTimelineMapping(anchors: anchors),
      score: score
    )
  }

  /// 等間隔のハッシュ列から，最も似る整数サンプルぶんの時間差を求める．
  /// AVFoundationに依存しないため，合成した列を使った単体テストも行える．
  nonisolated static func estimateOffset(
    reference: [PerceptualHash],
    candidate: [PerceptualHash],
    sampleInterval: TimeInterval
  ) -> VariantTimeOffsetEstimate? {
    guard sampleInterval > 0, !reference.isEmpty, !candidate.isEmpty else { return nil }

    let shorterCount = min(reference.count, candidate.count)
    let minimumOverlap = max(10, min(60, Int(Double(shorterCount) * 0.25)))
    guard shorterCount >= minimumOverlap else { return nil }

    var best: VariantTimeOffsetEstimate?
    let firstLag = -reference.count + minimumOverlap
    let lastLag = candidate.count - minimumOverlap

    for lag in firstLag...lastLag {
      let referenceStart = max(0, -lag)
      let candidateStart = referenceStart + lag
      let overlapCount = min(
        reference.count - referenceStart,
        candidate.count - candidateStart
      )
      guard overlapCount >= minimumOverlap else { continue }

      var distances: [Int] = []
      distances.reserveCapacity(overlapCount)
      for index in 0..<overlapCount {
        distances.append(
          reference[referenceStart + index].distance(
            to: candidate[candidateStart + index]
          )
        )
      }

      let visualScore = trimmedMean(distances)
      // ごく短い一致だけが勝たないよう，短い重なりには小さな罰点を加える．
      let coverage = Double(overlapCount) / Double(shorterCount)
      let score = visualScore + (1 - coverage) * 4
      let estimate = VariantTimeOffsetEstimate(
        offset: Double(lag) * sampleInterval,
        score: score,
        overlapDuration: Double(overlapCount) * sampleInterval
      )
      if best == nil || estimate.score < best!.score {
        best = estimate
      }
    }
    return best
  }

  /// 尺を問わず一部が一致する動画を探すための軽量な時間列指紋を作る．
  /// 候補を選んだ後の再生時には `align(inputs:)` が1秒間隔で改めて精密解析する．
  nonisolated static func discoverySignature(
    forVideoAt url: URL,
    duration: TimeInterval
  ) async -> [PerceptualHash]? {
    await temporalSignature(
      forVideoAt: url,
      duration: duration,
      sampleInterval: discoveryInterval
    )?.hashes
  }

  /// 候補探索用の指紋列から，順序を保って続く共通場面を検出する．
  nonisolated static func discoveryMatch(
    reference: [PerceptualHash],
    candidate: [PerceptualHash]
  ) -> VariantTimelineMatch? {
    matchTimeline(
      reference: reference,
      candidate: candidate,
      sampleInterval: discoveryInterval,
      sampleInset: sampleInset
    )
  }

  private nonisolated static func temporalSignature(
    for input: Input
  ) async -> TemporalSignature? {
    await temporalSignature(
      forVideoAt: input.url,
      duration: input.duration,
      sampleInterval: coarseInterval
    )
  }

  private nonisolated static func temporalSignature(
    forVideoAt url: URL,
    duration: TimeInterval,
    sampleInterval: TimeInterval
  ) async -> TemporalSignature? {
    guard duration > sampleInset * 2, sampleInterval > 0 else { return nil }
    var times: [CMTime] = []
    var second = sampleInset
    while second <= duration - sampleInset {
      times.append(CMTime(seconds: second, preferredTimescale: imageTimescale))
      second += sampleInterval
    }
    guard let hashes = await hashes(
      forVideoAt: url,
      times: times,
      tolerance: sampleInterval / 4
    ), hashes.count == times.count else { return nil }
    return TemporalSignature(hashes: hashes)
  }

  /// 複数の類似アンカーに共通する端数秒を30fps相当で調べ，フレーム位置を詰める．
  private nonisolated static func refineFractionalOffset(
    _ anchors: [VariantTimelineMapping.Anchor],
    reference: Input,
    candidate: Input
  ) async -> VariantTimeOffsetEstimate? {
    guard let firstAnchor = anchors.first,
          let lastAnchor = anchors.last else { return nil }
    let selectedAnchors = (1...min(refinementAnchorCount, anchors.count)).map { index in
      let ratio = Double(index) / Double(min(refinementAnchorCount, anchors.count) + 1)
      let anchorIndex = min(
        anchors.count - 1,
        Int((Double(anchors.count - 1) * ratio).rounded())
      )
      return anchors[anchorIndex]
    }
    let referenceTimes = selectedAnchors.map {
      CMTime(seconds: $0.logicalTime, preferredTimescale: imageTimescale)
    }
    guard let referenceHashes = await hashes(
      forVideoAt: reference.url,
      times: referenceTimes,
      tolerance: .zero
    ) else { return nil }

    let stepCount = Int((refinementRadius * 2 / refinementStep).rounded())
    let candidateOffsets = (0...stepCount).map { index in
      -refinementRadius + Double(index) * refinementStep
    }
    let candidateTimes = candidateOffsets.flatMap { offset in
      selectedAnchors.map {
        CMTime(seconds: $0.videoTime + offset, preferredTimescale: imageTimescale)
      }
    }.sorted { $0.seconds < $1.seconds }
    guard let candidateHashes = await hashes(
      forVideoAt: candidate.url,
      times: candidateTimes,
      tolerance: .zero
    ), candidateHashes.count == candidateTimes.count else { return nil }
    var candidateHashByTime: [Int64: PerceptualHash] = [:]
    for (time, hash) in zip(candidateTimes, candidateHashes) {
      candidateHashByTime[timeKey(time)] = hash
    }

    var best: VariantTimeOffsetEstimate?
    for offset in candidateOffsets {
      let values = zip(referenceHashes, selectedAnchors).compactMap { pair -> Int? in
        let (referenceHash, anchor) = pair
        let time = CMTime(
          seconds: anchor.videoTime + offset,
          preferredTimescale: imageTimescale
        )
        guard let candidateHash = candidateHashByTime[timeKey(time)] else {
          return nil
        }
        return referenceHash.distance(to: candidateHash)
      }
      guard values.count == selectedAnchors.count else { continue }
      let estimate = VariantTimeOffsetEstimate(
        offset: offset,
        score: trimmedMean(values),
        overlapDuration: lastAnchor.logicalTime - firstAnchor.logicalTime
      )
      if best == nil || estimate.score < best!.score {
        best = estimate
      }
    }
    return best
  }

  private nonisolated static func clippedMapping(
    _ mapping: VariantTimelineMapping,
    referenceStart: TimeInterval,
    referenceEnd: TimeInterval,
    videoDuration: TimeInterval
  ) -> VariantTimelineMapping? {
    guard referenceEnd > referenceStart else { return nil }
    let startVideoTime = mapping.videoTime(forLogicalTime: referenceStart)
    let endVideoTime = mapping.videoTime(forLogicalTime: referenceEnd)
    guard startVideoTime >= 0,
          endVideoTime <= videoDuration,
          endVideoTime > startVideoTime else { return nil }

    var anchors = [
      VariantTimelineMapping.Anchor(logicalTime: 0, videoTime: startVideoTime)
    ]
    anchors.append(
      contentsOf: mapping.anchors.compactMap { anchor in
        guard anchor.logicalTime > referenceStart,
              anchor.logicalTime < referenceEnd else { return nil }
        return VariantTimelineMapping.Anchor(
          logicalTime: anchor.logicalTime - referenceStart,
          videoTime: anchor.videoTime
        )
      }
    )
    anchors.append(
      VariantTimelineMapping.Anchor(
        logicalTime: referenceEnd - referenceStart,
        videoTime: endVideoTime
      )
    )
    let clipped = VariantTimelineMapping(anchors: anchors)
    return clipped.anchors.count >= 2 ? clipped : nil
  }

  private nonisolated static func hashes(
    forVideoAt url: URL,
    times: [CMTime],
    tolerance: TimeInterval
  ) async -> [PerceptualHash]? {
    guard !times.isEmpty else { return [] }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 64, height: 64)
    let toleranceTime = CMTime(seconds: tolerance, preferredTimescale: imageTimescale)
    generator.requestedTimeToleranceBefore = toleranceTime
    generator.requestedTimeToleranceAfter = toleranceTime

    var found: [Int64: PerceptualHash] = [:]
    for await result in generator.images(for: times) {
      guard !Task.isCancelled else {
        generator.cancelAllCGImageGeneration()
        return nil
      }
      switch result {
      case .success(let requestedTime, let image, _):
        guard let hash = PerceptualHasher.hash(of: image) else { return nil }
        found[timeKey(requestedTime)] = hash
      case .failure:
        return nil
      }
    }
    return times.compactMap { found[timeKey($0)] }.count == times.count
      ? times.compactMap { found[timeKey($0)] }
      : nil
  }

  private nonisolated static func timeKey(_ time: CMTime) -> Int64 {
    Int64((time.seconds * Double(imageTimescale)).rounded())
  }

  private nonisolated static func trimmedMean(_ distances: [Int]) -> Double {
    guard !distances.isEmpty else { return .infinity }
    let sorted = distances.sorted()
    let keepCount = max(1, Int((Double(sorted.count) * 0.8).rounded(.down)))
    return Double(sorted.prefix(keepCount).reduce(0, +)) / Double(keepCount)
  }
}

enum VariantVideoDetector {
    /// 束の中の1本ぶんの手がかり。フレームの指紋と、そろえ済みのファイル名。
    struct Fingerprint: Sendable {
        let signature: VideoFrameSignature
        let title: [Character]

        init(signature: VideoFrameSignature, filename: String) {
            self.signature = signature
            self.title = TitleSimilarity.normalized(filename)
        }
    }

    /// 名前がどれだけ遠くても、これ以下のしきい値までは締めない。
    /// 名前を付け替えただけの差分（フレームはほぼ一致）を取りこぼさないための下限。
    static let minimumThreshold: Double = 2

    /// 名前の近さでしきい値を上下させたもの。0.5 を中立に、近ければ足し、遠ければ引く。
    ///
    /// `influence` で効き幅を抑えているのは、名前だけでは差分（0.57〜0.94）と
    /// 別キャラ（0.41〜0.67）が重なって見分けられないため。
    /// 名前の近さだけでフレームの隔たり（差分 2〜9 に対し別キャラ 14〜19）を
    /// 埋め切れない大きさに留めておく必要がある。
    static func effectiveThreshold(
        base: Double,
        titleSimilarity: Double,
        influence: Double
    ) -> Double {
        max(minimumThreshold, base + influence * (titleSimilarity - 0.5) * 2)
    }

    /// 2本が同じ映像の別バージョンかどうか。
    static func isVariantPair(
        _ lhs: Fingerprint,
        _ rhs: Fingerprint,
        maxAverageDistance: Double,
        titleInfluence: Double
    ) -> Bool {
        guard let distance = lhs.signature.averageDistance(to: rhs.signature) else { return false }
        let threshold = effectiveThreshold(
            base: maxAverageDistance,
            titleSimilarity: TitleSimilarity.score(lhs.title, rhs.title),
            influence: titleInfluence
        )
        return distance <= threshold
    }

    /// 尺が `tolerance` 秒以内で揃うものを1つの束にする。
    ///
    /// 尺の昇順に見ていき、束の先頭からの差が `tolerance` を超えたところで束を切る。
    /// 「隣どうしの差」で切ると、わずかな差が積み重なった長い鎖が1つの束になってしまう。
    /// 2件以上になった束だけを返す（1件だけの尺は差分の相手がいない）。
    static func durationBuckets(
        of items: [VideoItem],
        tolerance: TimeInterval
    ) -> [[VideoItem]] {
        let sorted = items.filter { $0.mediaType == .video && $0.duration > 0 }
            .sorted { $0.duration < $1.duration }
        guard sorted.count > 1 else { return [] }

        var buckets: [[VideoItem]] = []
        var current: [VideoItem] = []
        var anchor: TimeInterval = 0

        for item in sorted {
            if current.isEmpty || item.duration - anchor <= tolerance {
                if current.isEmpty { anchor = item.duration }
                current.append(item)
            } else {
                if current.count > 1 { buckets.append(current) }
                current = [item]
                anchor = item.duration
            }
        }
        if current.count > 1 { buckets.append(current) }
        return buckets
    }

    /// 束を、差分どうしとみなせるものでつながるグループへまとめる。
    /// フレームの指紋が取れなかったものは、名前がどれだけ近くても対象にしない
    /// （名前だけでは根拠として弱く、別キャラを引き込んでしまう）。
    static func groups(
        in bucket: [VideoItem],
        fingerprints: [UUID: Fingerprint],
        maxAverageDistance: Double,
        titleInfluence: Double
    ) -> [[VideoItem]] {
        let entries: [(id: UUID, value: Fingerprint)] = bucket.compactMap { item in
            guard let fingerprint = fingerprints[item.id] else { return nil }
            return (id: item.id, value: fingerprint)
        }
        guard entries.count > 1 else { return [] }

        let grouped = SimilarityGrouping.groups(of: entries) { lhs, rhs in
            isVariantPair(
                lhs, rhs,
                maxAverageDistance: maxAverageDistance,
                titleInfluence: titleInfluence
            )
        }

        let itemsByID = Dictionary(bucket.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        return grouped.compactMap { ids in
            let items = ids.compactMap { itemsByID[$0] }
            return items.count > 1 ? items : nil
        }
    }

    /// グループがどれくらいの根拠でまとまったのかを画面に出すための実測値。
    struct GroupStats: Equatable {
        var frameDistance: ClosedRange<Double>
        var titleSimilarity: ClosedRange<Double>
    }

    static func stats(for items: [VideoItem], fingerprints: [UUID: Fingerprint]) -> GroupStats? {
        let found = items.compactMap { fingerprints[$0.id] }
        guard found.count > 1 else { return nil }

        var distances: [Double] = []
        var similarities: [Double] = []
        for i in 0..<found.count {
            for j in (i + 1)..<found.count {
                if let distance = found[i].signature.averageDistance(to: found[j].signature) {
                    distances.append(distance)
                }
                similarities.append(TitleSimilarity.score(found[i].title, found[j].title))
            }
        }
        guard let lowDistance = distances.min(), let highDistance = distances.max(),
              let lowTitle = similarities.min(), let highTitle = similarities.max() else { return nil }
        return GroupStats(
            frameDistance: lowDistance...highDistance,
            titleSimilarity: lowTitle...highTitle
        )
    }
}
