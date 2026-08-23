import AVFoundation
import Combine
import Foundation
import ImageIO

@MainActor
final class SimilarMediaViewModel: ObservableObject {
  enum ScanStage {
    case appearance
    case mediaDetails

    var title: String {
      switch self {
      case .appearance:
        return "見た目を照合中"
      case .mediaDetails:
        return "音声・画質を精査中"
      }
    }
  }

  enum AudioState: Sendable {
    case notApplicable
    case noAudio
    case fingerprint([UInt8])
    case unreadable
  }

  enum AudioStatus {
    case notApplicable
    case matched
    case different
    case noAudio
    case unreadable
  }

  struct MediaDetails: Sendable {
    var fileSize: Int64
    var pixelWidth: Int
    var pixelHeight: Int
    var videoBitrate: Double
    var audioState: AudioState

    var pixelCount: Int {
      pixelWidth * pixelHeight
    }
  }

  struct Group: Identifiable {
    let id = UUID()
    var items: [VideoItem]
    /// 音声が異なる版を誤って消さないよう，音声グループごとに1件ずつ残す候補を持つ．
    var keepIDs: Set<UUID>
    var audioGroupByItemID: [UUID: Int]
    var hasAudioDifferences: Bool
  }

  @Published private(set) var isScanning = false
  @Published private(set) var scanStage: ScanStage = .appearance
  @Published private(set) var scannedCount = 0
  @Published private(set) var totalCount = 0
  @Published private(set) var groups: [Group] = []
  @Published private(set) var unreadableCount = 0
  /// 消す対象．音声が一致すると判断できた組だけを初期選択する．
  @Published var selectedIDs = Set<UUID>()

  /// 何ビットまでの違いを「似ている」とみなすか．dHash は64ビット．
  /// 音声・尺・画角まで一致した動画は，この値より少し離れていても候補へ含める．
  @Published var maxDistance: Double = 5 {
    didSet { rebuildGroups() }
  }

  private struct ScanTarget: Sendable {
    let item: VideoItem
    let appearanceURL: URL
    let mediaURL: URL
  }

  private static let maximumSliderDistance = 16
  private static let metadataDistanceAllowance = 2
  private static let durationTolerance = 0.75
  private static let aspectRatioTolerance = 0.03
  private static let maximumFileSizeRatio = 20.0
  private static let audioDifferenceThreshold = 0.2

  private var hashes: [(id: UUID, hash: PerceptualHash)] = []
  private var detailsByID: [UUID: MediaDetails] = [:]
  private var itemsByID: [UUID: VideoItem] = [:]
  private var scanTask: Task<Void, Never>?

  var progress: Double {
    totalCount == 0 ? 0 : Double(scannedCount) / Double(totalCount)
  }

  var selectedItems: [VideoItem] {
    groups.flatMap { $0.items }.filter { selectedIDs.contains($0.id) }
  }

  func details(for item: VideoItem) -> MediaDetails? {
    detailsByID[item.id]
  }

  func audioStatus(for item: VideoItem, in group: Group) -> AudioStatus {
    guard item.mediaType != .photo else { return .notApplicable }
    guard let details = detailsByID[item.id] else { return .unreadable }

    switch details.audioState {
    case .notApplicable:
      return .notApplicable
    case .noAudio:
      return .noAudio
    case .unreadable:
      return .unreadable
    case .fingerprint:
      return group.hasAudioDifferences ? .different : .matched
    }
  }

  func scan(items: [VideoItem], dataManager: LibraryViewModel) {
    guard !isScanning else { return }

    // 見た目は写真なら実ファイル，動画なら一覧と同じ生成済みサムネイルで比較する．
    // 音声・画質の解析には動画の実ファイルを使う．
    let targets: [ScanTarget] = items.compactMap { item in
      guard let mediaURL = dataManager.fileURL(for: item)?.resolvingSymlinksInPath() else { return nil }
      switch item.mediaType {
      case .photo:
        return ScanTarget(item: item, appearanceURL: mediaURL, mediaURL: mediaURL)
      default:
        let thumbnail = dataManager.thumbnailStorageURL
          .appendingPathComponent(item.id.uuidString)
          .appendingPathExtension("jpg")
        guard FileManager.default.fileExists(atPath: thumbnail.path) else { return nil }
        return ScanTarget(item: item, appearanceURL: thumbnail, mediaURL: mediaURL)
      }
    }

    isScanning = true
    scanStage = .appearance
    scannedCount = 0
    totalCount = targets.count
    groups = []
    selectedIDs = []
    hashes = []
    detailsByID = [:]
    unreadableCount = items.count - targets.count
    itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })

    scanTask = Task { @MainActor in
      var collected: [(id: UUID, hash: PerceptualHash)] = []
      let progressStride = max(1, targets.count / 100)

      for (offset, target) in targets.enumerated() {
        if Task.isCancelled { break }
        let hash = await Task.detached(priority: .utility) {
          PerceptualHasher.hash(forImageAt: target.appearanceURL)
        }.value

        if let hash {
          collected.append((target.item.id, hash))
        } else {
          unreadableCount += 1
        }
        if offset % progressStride == 0 { scannedCount = offset + 1 }
      }

      guard !Task.isCancelled else {
        isScanning = false
        return
      }

      hashes = collected
      let detailCandidateIDs = candidateIDsForDetailedAnalysis(from: collected)
      let detailTargets = targets.filter { detailCandidateIDs.contains($0.item.id) }
      scanStage = .mediaDetails
      scannedCount = 0
      totalCount = detailTargets.count

      var collectedDetails: [UUID: MediaDetails] = [:]
      for (offset, target) in detailTargets.enumerated() {
        if Task.isCancelled { break }
        let fallbackSize = fileSize(of: target.item)
        let details = await SimilarMediaAnalyzer.analyze(
          item: target.item,
          mediaURL: target.mediaURL,
          fallbackFileSize: fallbackSize
        )
        collectedDetails[target.item.id] = details
        scannedCount = offset + 1
      }

      guard !Task.isCancelled else {
        isScanning = false
        return
      }

      detailsByID = collectedDetails
      rebuildGroups()
      isScanning = false
    }
  }

  func cancelScan() {
    scanTask?.cancel()
    scanTask = nil
    isScanning = false
  }

  /// 同じ音声版の中で残す1件を選び直す．別音声版の残す候補には触れない．
  func setKeep(_ id: UUID, inGroupAt index: Int) {
    guard groups.indices.contains(index),
          let audioGroup = groups[index].audioGroupByItemID[id] else { return }

    let replacedKeepIDs = groups[index].keepIDs.filter {
      groups[index].audioGroupByItemID[$0] == audioGroup
    }
    groups[index].keepIDs.subtract(replacedKeepIDs)
    groups[index].keepIDs.insert(id)
    updateSelection(forGroupAt: index)
  }

  func toggle(_ id: UUID, inGroupAt index: Int) {
    guard groups.indices.contains(index) else { return }
    if selectedIDs.contains(id) {
      selectedIDs.remove(id)
    } else {
      // 音声が異なる版も利用者が明示的に選べば削除できるが，残す表示との矛盾は残さない．
      groups[index].keepIDs.remove(id)
      selectedIDs.insert(id)
    }
  }

  private func candidateIDsForDetailedAnalysis(
    from collected: [(id: UUID, hash: PerceptualHash)]
  ) -> Set<UUID> {
    let widestDistance = Self.maximumSliderDistance + Self.metadataDistanceAllowance
    var candidateIDs = Set<UUID>()
    guard collected.count > 1 else { return candidateIDs }

    // 推移的なグループ化をここで使うと，似た候補が鎖状につながっただけで
    // 無関係な動画まで重い音声解析へ進むため，直接近い組だけを対象にする．
    for firstIndex in 0..<(collected.count - 1) {
      for secondIndex in (firstIndex + 1)..<collected.count {
        if collected[firstIndex].hash.distance(to: collected[secondIndex].hash) <= widestDistance {
          candidateIDs.insert(collected[firstIndex].id)
          candidateIDs.insert(collected[secondIndex].id)
        }
      }
    }
    return candidateIDs
  }

  private func rebuildGroups() {
    let entries = hashes.map { entry in
      (id: entry.id, value: entry)
    }
    let grouped = SimilarityGrouping.groups(of: entries) { [weak self] first, second in
      guard let self else { return false }
      return self.areSimilar(firstID: first.id, firstHash: first.hash, secondID: second.id, secondHash: second.hash)
    }

    groups = grouped.compactMap { ids in
      let items = ids.compactMap { itemsByID[$0] }
      guard items.count > 1 else { return nil }
      let audioGroups = makeAudioGroups(for: items)
      let keepIDs = Set(audioGroups.compactMap { bestQualityItem(in: $0)?.id })
      let audioGroupByItemID = Dictionary(
        uniqueKeysWithValues: audioGroups.enumerated().flatMap { index, groupItems in
          groupItems.map { ($0.id, index) }
        }
      )
      let comparableAudioGroupCount = audioGroups.filter { groupItems in
        groupItems.contains { item in
          guard let state = detailsByID[item.id]?.audioState else { return false }
          if case .unreadable = state { return false }
          return item.mediaType != .photo
        }
      }.count
      return Group(
        items: items.sorted { isHigherQuality($0, than: $1) },
        keepIDs: keepIDs,
        audioGroupByItemID: audioGroupByItemID,
        hasAudioDifferences: comparableAudioGroupCount > 1
      )
    }

    selectedIDs = Set(groups.flatMap { group in
      group.items.map(\.id).filter { !group.keepIDs.contains($0) }
    })
  }

  private func areSimilar(
    firstID: UUID,
    firstHash: PerceptualHash,
    secondID: UUID,
    secondHash: PerceptualHash
  ) -> Bool {
    let distance = firstHash.distance(to: secondHash)
    if distance <= Int(maxDistance) { return true }
    guard distance <= Int(maxDistance) + Self.metadataDistanceAllowance,
          let firstItem = itemsByID[firstID],
          let secondItem = itemsByID[secondID],
          firstItem.mediaType != .photo,
          secondItem.mediaType != .photo,
          abs(firstItem.duration - secondItem.duration) <= Self.durationTolerance,
          let firstDetails = detailsByID[firstID],
          let secondDetails = detailsByID[secondID],
          audioStatesMatch(firstDetails.audioState, secondDetails.audioState),
          aspectRatiosMatch(firstDetails, secondDetails),
          fileSizesArePlausible(firstDetails.fileSize, secondDetails.fileSize) else {
      return false
    }
    return true
  }

  private func makeAudioGroups(for items: [VideoItem]) -> [[VideoItem]] {
    var result: [[VideoItem]] = []
    for item in items {
      guard let state = detailsByID[item.id]?.audioState else {
        result.append([item])
        continue
      }

      if case .unreadable = state {
        result.append([item])
        continue
      }

      if let index = result.firstIndex(where: { existingItems in
        guard let representative = existingItems.first,
              let representativeState = detailsByID[representative.id]?.audioState else { return false }
        return audioStatesMatch(state, representativeState)
      }) {
        result[index].append(item)
      } else {
        result.append([item])
      }
    }
    return result
  }

  private func audioStatesMatch(_ first: AudioState, _ second: AudioState) -> Bool {
    switch (first, second) {
    case (.notApplicable, .notApplicable):
      return true
    case (.noAudio, .noAudio):
      return true
    case let (.fingerprint(firstValues), .fingerprint(secondValues)):
      guard firstValues.count == secondValues.count, !firstValues.isEmpty else { return false }
      let totalDifference = zip(firstValues, secondValues).reduce(0.0) { partial, pair in
        partial + Double(abs(Int(pair.0) - Int(pair.1))) / 255.0
      }
      return totalDifference / Double(firstValues.count) <= Self.audioDifferenceThreshold
    default:
      return false
    }
  }

  private func aspectRatiosMatch(_ first: MediaDetails, _ second: MediaDetails) -> Bool {
    guard first.pixelHeight > 0, second.pixelHeight > 0 else { return false }
    let firstRatio = Double(first.pixelWidth) / Double(first.pixelHeight)
    let secondRatio = Double(second.pixelWidth) / Double(second.pixelHeight)
    return abs(firstRatio - secondRatio) <= Self.aspectRatioTolerance
  }

  private func fileSizesArePlausible(_ first: Int64, _ second: Int64) -> Bool {
    guard first > 0, second > 0 else { return false }
    let ratio = Double(max(first, second)) / Double(min(first, second))
    return ratio <= Self.maximumFileSizeRatio
  }

  private func bestQualityItem(in items: [VideoItem]) -> VideoItem? {
    items.sorted { isHigherQuality($0, than: $1) }.first
  }

  private func isHigherQuality(_ first: VideoItem, than second: VideoItem) -> Bool {
    let firstDetails = detailsByID[first.id]
    let secondDetails = detailsByID[second.id]
    let firstPixels = firstDetails?.pixelCount ?? 0
    let secondPixels = secondDetails?.pixelCount ?? 0
    if firstPixels != secondPixels { return firstPixels > secondPixels }

    let firstBitrate = firstDetails?.videoBitrate ?? 0
    let secondBitrate = secondDetails?.videoBitrate ?? 0
    if firstBitrate != secondBitrate { return firstBitrate > secondBitrate }

    return (firstDetails?.fileSize ?? fileSize(of: first)) >
      (secondDetails?.fileSize ?? fileSize(of: second))
  }

  private func updateSelection(forGroupAt index: Int) {
    guard groups.indices.contains(index) else { return }
    for item in groups[index].items {
      if groups[index].keepIDs.contains(item.id) {
        selectedIDs.remove(item.id)
      } else {
        selectedIDs.insert(item.id)
      }
    }
  }

  /// 並べ替えでも使っているキャッシュ済みの属性を読む．
  private var fileSizeProvider: ((VideoItem) -> Int64)?

  func configure(fileSizeProvider: @escaping (VideoItem) -> Int64) {
    self.fileSizeProvider = fileSizeProvider
  }

  private func fileSize(of item: VideoItem) -> Int64 {
    fileSizeProvider?(item) ?? 0
  }
}

private enum SimilarMediaAnalyzer {
  nonisolated private static let audioSampleRate = 8_000
  nonisolated private static let audioWindowDuration = 1.5
  nonisolated private static let samplesPerWindow = 12_000
  nonisolated private static let blocksPerWindow = 24
  nonisolated private static let audioWindowFractions = [0.15, 0.5, 0.85]
  nonisolated private static let audioBandFrequencies = [150.0, 300.0, 600.0, 1_200.0, 2_400.0]

  nonisolated static func analyze(
    item: VideoItem,
    mediaURL: URL,
    fallbackFileSize: Int64
  ) async -> SimilarMediaViewModel.MediaDetails {
    let fileSize = resolvedFileSize(at: mediaURL, fallback: fallbackFileSize)
    if item.mediaType == .photo {
      let dimensions = imageDimensions(at: mediaURL)
      return SimilarMediaViewModel.MediaDetails(
        fileSize: fileSize,
        pixelWidth: dimensions.width,
        pixelHeight: dimensions.height,
        videoBitrate: 0,
        audioState: .notApplicable
      )
    }

    let asset = AVURLAsset(url: mediaURL)
    do {
      guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
        return unreadableVideoDetails(fileSize: fileSize)
      }
      async let naturalSize = videoTrack.load(.naturalSize)
      async let preferredTransform = videoTrack.load(.preferredTransform)
      async let estimatedDataRate = videoTrack.load(.estimatedDataRate)
      async let assetDuration = asset.load(.duration)
      let transformedSize = try await naturalSize.applying(preferredTransform)
      let loadedDuration = try await assetDuration.seconds
      let analysisDuration = loadedDuration.isFinite && loadedDuration > 0 ? loadedDuration : item.duration
      let audioTracks = try await asset.loadTracks(withMediaType: .audio)
      let audioState: SimilarMediaViewModel.AudioState
      if let audioTrack = audioTracks.first {
        let fingerprint = await Task.detached(priority: .utility) {
          makeAudioFingerprint(asset: asset, track: audioTrack, duration: analysisDuration)
        }.value
        audioState = fingerprint.map { .fingerprint($0) } ?? .unreadable
      } else {
        audioState = .noAudio
      }

      return SimilarMediaViewModel.MediaDetails(
        fileSize: fileSize,
        pixelWidth: Int(abs(transformedSize.width).rounded()),
        pixelHeight: Int(abs(transformedSize.height).rounded()),
        videoBitrate: Double(try await estimatedDataRate),
        audioState: audioState
      )
    } catch {
      return unreadableVideoDetails(fileSize: fileSize)
    }
  }

  nonisolated private static func unreadableVideoDetails(
    fileSize: Int64
  ) -> SimilarMediaViewModel.MediaDetails {
    SimilarMediaViewModel.MediaDetails(
      fileSize: fileSize,
      pixelWidth: 0,
      pixelHeight: 0,
      videoBitrate: 0,
      audioState: .unreadable
    )
  }

  nonisolated private static func resolvedFileSize(at url: URL, fallback: Int64) -> Int64 {
    let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    return Int64(fileSize ?? 0) > 0 ? Int64(fileSize ?? 0) : fallback
  }

  nonisolated private static func imageDimensions(at url: URL) -> (width: Int, height: Int) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
      return (0, 0)
    }
    let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
    return (width, height)
  }

  nonisolated private static func makeAudioFingerprint(
    asset: AVAsset,
    track: AVAssetTrack,
    duration: TimeInterval
  ) -> [UInt8]? {
    guard duration > 0 else { return nil }
    var fingerprint: [UInt8] = []

    for fraction in audioWindowFractions {
      let center = duration * fraction
      let start = max(0, min(duration - audioWindowDuration, center - audioWindowDuration / 2))
      guard let samples = readAudioSamples(asset: asset, track: track, start: start),
            !samples.isEmpty else { return nil }
      fingerprint.append(contentsOf: fingerprintWindow(samples))
    }
    return fingerprint.isEmpty ? nil : fingerprint
  }

  nonisolated private static func readAudioSamples(
    asset: AVAsset,
    track: AVAssetTrack,
    start: TimeInterval
  ) -> [Int16]? {
    do {
      let reader = try AVAssetReader(asset: asset)
      reader.timeRange = CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: 600),
        duration: CMTime(seconds: audioWindowDuration, preferredTimescale: 600)
      )
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: audioSampleRate,
        AVNumberOfChannelsKey: 1
      ]
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
      output.alwaysCopiesSampleData = false
      guard reader.canAdd(output) else { return nil }
      reader.add(output)
      guard reader.startReading() else { return nil }

      var samples: [Int16] = []
      samples.reserveCapacity(samplesPerWindow)
      while reader.status == .reading, samples.count < samplesPerWindow,
            let sampleBuffer = output.copyNextSampleBuffer() {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let result = CMBlockBufferGetDataPointer(
          blockBuffer,
          atOffset: 0,
          lengthAtOffsetOut: &lengthAtOffset,
          totalLengthOut: &totalLength,
          dataPointerOut: &dataPointer
        )
        guard result == kCMBlockBufferNoErr, let dataPointer else { continue }
        let sampleCount = totalLength / MemoryLayout<Int16>.size
        let buffer = UnsafeRawBufferPointer(start: dataPointer, count: totalLength)
          .bindMemory(to: Int16.self)
        samples.append(contentsOf: buffer.prefix(min(sampleCount, samplesPerWindow - samples.count)))
      }
      reader.cancelReading()
      return samples
    } catch {
      return nil
    }
  }

  /// 音量差や再エンコードに耐えるよう，短時間ごとの音量変化，ゼロ交差率，周波数分布を正規化する．
  nonisolated private static func fingerprintWindow(_ samples: [Int16]) -> [UInt8] {
    let blockSize = max(1, samples.count / blocksPerWindow)
    var energies: [Double] = []
    var zeroCrossings: [Double] = []
    var spectralBands: [[Double]] = []

    for blockIndex in 0..<blocksPerWindow {
      let lower = blockIndex * blockSize
      guard lower < samples.count else {
        energies.append(0)
        zeroCrossings.append(0)
        spectralBands.append([Double](repeating: 0, count: audioBandFrequencies.count))
        continue
      }
      let upper = min(samples.count, lower + blockSize)
      let block = samples[lower..<upper]
      let energy = block.reduce(0.0) { partial, sample in
        let normalized = Double(sample) / Double(Int16.max)
        return partial + normalized * normalized
      } / Double(max(1, block.count))
      var crossingCount = 0
      var previous = block.first ?? 0
      for sample in block.dropFirst() {
        if (previous < 0 && sample >= 0) || (previous >= 0 && sample < 0) {
          crossingCount += 1
        }
        previous = sample
      }
      energies.append(sqrt(energy))
      zeroCrossings.append(Double(crossingCount) / Double(max(1, block.count - 1)))
      spectralBands.append(spectralDistribution(for: block))
    }

    let maximumEnergy = max(energies.max() ?? 0, 0.000_001)
    let energyBytes = energies.map { UInt8(clamping: Int(($0 / maximumEnergy * 255).rounded())) }
    let crossingBytes = zeroCrossings.map { UInt8(clamping: Int(($0 * 255).rounded())) }
    let spectralBytes = spectralBands.flatMap { distribution in
      distribution.map { UInt8(clamping: Int(($0 * 255).rounded())) }
    }
    return energyBytes + crossingBytes + spectralBytes
  }

  /// Goertzel法で各帯域の強さを取り，ブロック内の構成比へ正規化する．
  nonisolated private static func spectralDistribution(
    for samples: ArraySlice<Int16>
  ) -> [Double] {
    let powers = audioBandFrequencies.map { frequency -> Double in
      let coefficient = 2 * cos(2 * Double.pi * frequency / Double(audioSampleRate))
      var previous = 0.0
      var previousPrevious = 0.0
      for sample in samples {
        let normalized = Double(sample) / Double(Int16.max)
        let current = normalized + coefficient * previous - previousPrevious
        previousPrevious = previous
        previous = current
      }
      let power = previous * previous
        + previousPrevious * previousPrevious
        - coefficient * previous * previousPrevious
      return max(0, power)
    }
    let totalPower = max(powers.reduce(0, +), 0.000_000_001)
    return powers.map { $0 / totalPower }
  }
}
