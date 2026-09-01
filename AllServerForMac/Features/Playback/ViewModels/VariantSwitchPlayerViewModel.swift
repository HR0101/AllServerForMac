import AVKit
import Combine
import Foundation

// MARK: - 差分切り替え再生
//
// 同じ尺・同じ動きで絵だけが違う「差分動画」を何本かまとめて読み込み、
// 全部を完全同期で走らせたまま、見せる1本だけを差し替える。
//
// これまでは ffmpeg の concat で切り替え済みの1本を焼いていたが、
// それだと本数ぶんの尺の動画がもう1本ディスクに増えるうえ、
// 間隔を変えるたびに焼き直しになり、見ている最中に「今のをもう一度」もできない。
// 全部を同時に走らせておけば、切り替えは「どのレイヤーを見せるか」だけの話になり、
// 切り替わりに継ぎ目が出ない・その場で間隔を変えられる・手動で戻せる。
//
// 代償はデコードの負荷（本数ぶん同時にデコードし続ける）。4K の差分を何本も選ぶと重い。
@MainActor
final class VariantSwitchPlayerViewModel: ObservableObject {
    struct Variant: Identifiable {
        let id: UUID
        let title: String
    }

    @Published private(set) var variants: [Variant] = []
    /// いま画面に出している差分の番号。
    @Published private(set) var activeIndex = 0
    @Published var commonCurrentTime: Double = 0
    @Published private(set) var commonDuration: Double = 1
    @Published private(set) var isPlaying = false
    @Published private(set) var hasReachedEnd = false
    @Published private(set) var isAligningByContent = false
    @Published private(set) var alignmentErrorMessage: String?
    @Published private(set) var alignmentSummary: String?
    /// 次の自動切り替えまでの残り秒。カウントダウン表示にそのまま使う。
    @Published private(set) var secondsUntilSwitch: Double = 0

    @Published var isAutoSwitching: Bool {
        didSet {
            VariantSwitchSettings.isAutoSwitchEnabled = isAutoSwitching
            if isAutoSwitching {
                prepareBeatAnalysis()
            } else {
                beatAnalysisTask?.cancel()
                beatAnalysisTask = nil
                isAnalyzingBeats = false
            }
            scheduleNextSwitch()
        }
    }

    /// 切り替え間隔の下限・上限。同じ値にすれば固定間隔、開ければその範囲でばらつく。
    ///
    /// 丸め込みや上下の入れ替わりを `didSet` の中でやってはいけない。
    /// `@Published` は素の stored property と違い、`didSet` の中で自分自身へ代入すると
    /// `didSet` がもう一度走るため、`self = clamp(self)` の形が無限再帰になってアプリごと落ちる。
    /// 変更は必ず下の `setMinInterval` / `setMaxInterval` / `shiftIntervals` を通す。
    @Published private(set) var minInterval: Double
    @Published private(set) var maxInterval: Double

    @Published var avoidsImmediateRepeat: Bool {
        didSet { VariantSwitchSettings.avoidsImmediateRepeat = avoidsImmediateRepeat }
    }

    /// 聞こえるのは表示中の1本だけ。この音量はその1本に効く。
    @Published var volume: Float = 1 { didSet { applyAudio() } }
    @Published var isMuted: Bool = false { didSet { applyAudio() } }

    /// 動画ごとの代表音量を測り，切り替え時のBGM音量差を抑える．
    @Published var normalizesBGMVolume: Bool {
        didSet {
            VariantSwitchSettings.normalizesBGMVolume = normalizesBGMVolume
            handleBGMNormalizationSettingChange()
        }
    }
    @Published private(set) var isAnalyzingBGMVolume = false
    @Published private(set) var audioLevelAnalysisCompleted = false

    /// 自動切り替えの予定時刻を，検出したBGMの拍候補へ合わせる．
    @Published var synchronizesSwitchesToBeats: Bool {
        didSet {
            VariantSwitchSettings.synchronizesSwitchesToBeats = synchronizesSwitchesToBeats
            handleBeatSynchronizationSettingChange()
        }
    }
    @Published private(set) var isAnalyzingBeats = false
    @Published private(set) var beatAnalysisCompleted = false
    @Published private(set) var detectedBeatCount = 0
    @Published private(set) var isNextSwitchBeatAligned = false

    /// 見比べた結果「これは要らない」と分かったものを選ぶモード。
    /// 差分として並べてみて初めて、中身がまったく同じだと気づくことがある。
    @Published var isDeleteMode = false {
        didSet { if !isDeleteMode { markedForDeletionIDs.removeAll() } }
    }
    @Published private(set) var markedForDeletionIDs: Set<UUID> = []

    var players: [AVPlayer] { group.players }
    var variantCount: Int { variants.count }

    var activeBGMNormalizationText: String? {
        guard normalizesBGMVolume else { return nil }
        if isAnalyzingBGMVolume { return "音量解析中" }
        guard audioLevelAnalysisCompleted,
              audioLevels.indices.contains(activeIndex),
              audioNormalizationGains.indices.contains(activeIndex) else {
            return alignmentMode == .content ? "位置合わせ後に音量解析" : "音量解析待ち"
        }
        return VariantAudioLevelAnalyzer.adjustmentText(
            level: audioLevels[activeIndex],
            gain: audioNormalizationGains[activeIndex]
        )
    }

    var beatSynchronizationStatusText: String? {
        guard synchronizesSwitchesToBeats else { return nil }
        if isAnalyzingBeats { return "BGMの拍を解析中" }
        guard beatAnalysisCompleted else {
            return alignmentMode == .content ? "位置合わせ後に拍を解析" : "拍解析待ち"
        }
        guard detectedBeatCount > 0 else {
            return "拍を検出できないため通常間隔"
        }
        return isNextSwitchBeatAligned
            ? "拍同期・\(detectedBeatCount)拍"
            : "次の拍が遠いため通常間隔"
    }

    /// 削除対象に選ばれているもの。並びは画面と同じ（確認ダイアログの一覧と見た目を合わせる）。
    var markedItems: [VideoItem] {
        playable.map(\.item).filter { markedForDeletionIDs.contains($0.id) }
    }

    /// 通常時は従来の更新頻度を保ち，拍同期中だけ切り替え誤差を小さくする．
    private static let standardTickSeconds: Double = 0.1
    private static let beatSynchronizedTickSeconds: Double = 0.025
    /// これ以上ずれたら揃え直す。60fps で 15 フレームぶん＝切り替えたときに気づく大きさ。
    private static let driftThreshold: Double = 0.25
    /// ずれの点検間隔．差分切り替えとは独立して定期確認し，必要な場合だけ揃え直す．
    private static let driftCheckSeconds: Double = 4

    /// 読み込んだ差分の実体。削除したあとに組み直すため、URL ごと持っておく。
    private struct PlayableItem {
        let item: VideoItem
        let url: URL
        var timelineMapping: VariantTimelineMapping
    }

    private var playable: [PlayableItem]
    private var group: SynchronizedPlayerGroup
    private let alignmentMode: VariantPlaybackAlignmentMode
    private var alignedCommonDuration: TimeInterval?
    private var hasPreparedAlignment = false
    private var alignmentTask: Task<Void, Never>?
    private var audioNormalizationTask: Task<Void, Never>?
    private var beatAnalysisTask: Task<Void, Never>?
    private var switchTask: Task<Void, Never>?
    private var isSliderEditing = false
    private var secondsSinceDriftCheck: Double = 0
    private var audioLevels: [Double?] = []
    private var audioNormalizationGains: [Float] = []
    private var detectedBeatTimes: [TimeInterval] = []
    private var scheduledSwitchTimelineTime: TimeInterval?

    init(
        videos: [VideoItem],
        dataManager: LibraryViewModel,
        alignmentMode: VariantPlaybackAlignmentMode = .sameTime
    ) {
        let playable = videos.compactMap { item -> PlayableItem? in
            guard let url = dataManager.fileURL(for: item) else { return nil }
            return PlayableItem(
                item: item,
                url: url,
                timelineMapping: .identity(duration: item.duration)
            )
        }

        self.playable = playable
        self.alignmentMode = alignmentMode
        self.group = alignmentMode == .content
            ? SynchronizedPlayerGroup(urls: [])
            : SynchronizedPlayerGroup(urls: playable.map(\.url))
        self.variants = playable.map { Variant(id: $0.item.id, title: $0.item.originalFilename) }
        self.isAutoSwitching = VariantSwitchSettings.isAutoSwitchEnabled
        self.minInterval = VariantSwitchSettings.minInterval
        self.maxInterval = VariantSwitchSettings.maxInterval
        self.avoidsImmediateRepeat = VariantSwitchSettings.avoidsImmediateRepeat
        self.normalizesBGMVolume = VariantSwitchSettings.normalizesBGMVolume
        self.synchronizesSwitchesToBeats = VariantSwitchSettings.synchronizesSwitchesToBeats

        wireGroup()
        applyAudio()
    }

    private func wireGroup() {
        group.onDurationUpdate = { [weak self] duration in
            self?.commonDuration = duration
        }
        group.onTimeUpdate = { [weak self] time in
            guard let self, !self.isSliderEditing else { return }
            self.commonCurrentTime = time
        }
        group.onPlayToEnd = { [weak self] in
            self?.handlePlayToEnd()
        }
    }

    // MARK: - 再生

    func start() {
        prepareBGMVolumeNormalization()
        prepareBeatAnalysis()
        if alignmentMode == .content, !hasPreparedAlignment {
            prepareContentAlignment()
            return
        }
        startPreparedPlayback()
    }

    func retryContentAlignment() {
        guard alignmentMode == .content, !isAligningByContent else { return }
        alignmentErrorMessage = nil
        hasPreparedAlignment = false
        prepareContentAlignment()
    }

    private func startPreparedPlayback() {
        guard !group.isEmpty, alignmentErrorMessage == nil else { return }
        hasReachedEnd = false
        isPlaying = true
        group.play()
        scheduleNextSwitch()
        startTicking()
    }

    private func prepareContentAlignment() {
        guard !isAligningByContent, playable.count >= 2 else { return }
        alignmentTask?.cancel()
        isAligningByContent = true
        alignmentErrorMessage = nil

        let inputs = playable.map {
            VariantContentAligner.Input(
                id: $0.item.id,
                filename: $0.item.originalFilename,
                url: $0.url,
                duration: $0.item.duration
            )
        }
        alignmentTask = Task { @MainActor [weak self] in
            let result = await VariantContentAligner.align(inputs: inputs)
            guard let self, !Task.isCancelled else { return }
            self.isAligningByContent = false

            switch result {
            case .success(let alignment):
                let entries = Dictionary(
                    uniqueKeysWithValues: alignment.entries.map { ($0.videoID, $0) }
                )
                for index in self.playable.indices {
                    if let mapping = entries[self.playable[index].item.id]?.mapping {
                        self.playable[index].timelineMapping = mapping
                    }
                }
                self.alignedCommonDuration = alignment.commonDuration
                self.alignmentSummary = self.makeAlignmentSummary(alignment)
                self.group.cleanup()
                self.group = self.makePlayerGroup()
                self.wireGroup()
                self.commonDuration = alignment.commonDuration
                self.hasPreparedAlignment = true
                self.applyAudio()
                self.prepareBGMVolumeNormalization(force: true)
                self.prepareBeatAnalysis(force: true)
                self.startPreparedPlayback()
            case .failure(let error):
                self.alignmentErrorMessage = error.localizedDescription
                self.isPlaying = false
            }
        }
    }

    private func makePlayerGroup() -> SynchronizedPlayerGroup {
        SynchronizedPlayerGroup(
            urls: playable.map(\.url),
            timelineMappings: playable.map(\.timelineMapping),
            commonTimelineDuration: alignedCommonDuration
        )
    }

    private func makeAlignmentSummary(_ alignment: VariantContentAlignment) -> String {
        let starts = alignment.entries.map(\.startTime)
        let spread = (starts.max() ?? 0) - (starts.min() ?? 0)
        let matchedPointCount = alignment.entries.dropFirst().map {
            $0.mapping.anchors.count
        }.min() ?? 0
        let seconds = Int(alignment.commonDuration.rounded())
        let durationText = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return String(
            format: "類似点%d個・開始差 %.2f秒・共通尺 %@",
            matchedPointCount,
            spread,
            durationText
        )
    }

    func togglePlayPause() {
        if isPlaying {
            isPlaying = false
            group.pause()
        } else {
            // 最後まで行ってから押されたら、頭出しし直して続ける。
            if hasReachedEnd {
                hasReachedEnd = false
                group.seekAll(toTimelineTime: 0)
                scheduleNextSwitch(from: 0)
            }
            isPlaying = true
            group.play()
        }
    }

    func seek(by seconds: Double) {
        hasReachedEnd = false
        let expectedTime = min(max(0, commonCurrentTime + seconds), commonDuration)
        group.seekAll(by: seconds)
        scheduleNextSwitch(from: expectedTime)
    }

    /// 数字キーからの割合ジャンプ（0〜1）。
    func seek(toPercentage percentage: Double) {
        hasReachedEnd = false
        group.seekAll(toPercentage: percentage)
        scheduleNextSwitch(from: commonDuration * min(max(percentage, 0), 1))
    }

    func sliderEditingChanged(isEditing: Bool) {
        isSliderEditing = isEditing
        guard !isEditing, commonDuration > 0 else { return }
        hasReachedEnd = false
        group.seekAll(toPercentage: commonCurrentTime / commonDuration)
        scheduleNextSwitch(from: commonCurrentTime)
    }

    private func handlePlayToEnd() {
        hasReachedEnd = true
        isPlaying = false
        secondsUntilSwitch = 0
        scheduledSwitchTimelineTime = nil
        isNextSwitchBeatAligned = false
        group.pause()
    }

    // MARK: - 差分の切り替え

    func showVariant(at index: Int) {
        guard variants.indices.contains(index) else { return }
        applySwitch(to: index)
    }

    func showNextVariant() {
        guard variantCount > 1 else { return }
        applySwitch(to: (activeIndex + 1) % variantCount)
    }

    func showPreviousVariant() {
        guard variantCount > 1 else { return }
        applySwitch(to: (activeIndex - 1 + variantCount) % variantCount)
    }

    func showRandomVariant() {
        guard variantCount > 1 else { return }
        let candidates = avoidsImmediateRepeat
            ? variants.indices.filter { $0 != activeIndex }
            : Array(variants.indices)
        guard let pick = candidates.randomElement() else { return }
        applySwitch(to: pick)
    }

    /// 表示と音を差し替える。手で切り替えたときも次の自動切り替えまでの時間は測り直す
    /// （切り替えた直後にまた勝手に変わると、見たかった1本を見られない）。
    private func applySwitch(to index: Int) {
        guard variants.indices.contains(index) else { return }
        commitSwitch(to: index)
    }

    private func commitSwitch(to index: Int) {
        activeIndex = index
        applyAudio()
        scheduleNextSwitch()
    }

    /// 聞こえるのは表示中の1本だけ。裏の動画は走らせたままミュートする
    /// （止めてしまうと切り替えた瞬間に頭出しからやり直しになる）。
    private func applyAudio() {
        for (index, player) in players.enumerated() {
            let isActive = index == activeIndex
            let normalizationGain = normalizesBGMVolume
                && audioNormalizationGains.indices.contains(index)
                ? audioNormalizationGains[index]
                : 1
            player.isMuted = !isActive || isMuted
            player.volume = isActive ? min(max(volume * normalizationGain, 0), 1) : 0
        }
    }

    // MARK: - BGM音量の補正

    private func handleBGMNormalizationSettingChange() {
        if normalizesBGMVolume {
            prepareBGMVolumeNormalization()
        } else {
            audioNormalizationTask?.cancel()
            audioNormalizationTask = nil
            isAnalyzingBGMVolume = false
            applyAudio()
        }
    }

    private func prepareBGMVolumeNormalization(force: Bool = false) {
        guard normalizesBGMVolume, !playable.isEmpty else { return }
        // 一部一致差分は，共通場面の対応表が完成してから同じ場面どうしを測る．
        guard alignmentMode != .content || hasPreparedAlignment else { return }
        if !force,
           audioLevelAnalysisCompleted,
           audioLevels.count == playable.count,
           audioNormalizationGains.count == playable.count {
            applyAudio()
            return
        }

        let sources = makeAudioLevelSources()
        guard sources.count == playable.count else { return }
        audioNormalizationTask?.cancel()
        isAnalyzingBGMVolume = true
        audioLevelAnalysisCompleted = false

        audioNormalizationTask = Task { @MainActor [weak self] in
            let levels = await VariantAudioLevelAnalyzer.analyze(sources: sources)
            guard let self, !Task.isCancelled else { return }
            self.audioLevels = levels
            self.audioNormalizationGains = VariantAudioLevelAnalyzer
                .normalizationGains(for: levels)
            self.isAnalyzingBGMVolume = false
            self.audioLevelAnalysisCompleted = true
            self.audioNormalizationTask = nil
            self.applyAudio()
        }
    }

    private func makeAudioLevelSources() -> [VariantAudioLevelSource] {
        playable.map { playableItem in
            let sampleCenterTimes: [TimeInterval]?
            if alignmentMode == .content,
               let alignedCommonDuration,
               alignedCommonDuration > 0 {
                sampleCenterTimes = VariantAudioLevelAnalyzer.samplePositions.map {
                    playableItem.timelineMapping.videoTime(
                        forLogicalTime: alignedCommonDuration * $0
                    )
                }
            } else {
                sampleCenterTimes = nil
            }
            return VariantAudioLevelSource(
                url: playableItem.url,
                duration: playableItem.item.duration,
                sampleCenterTimes: sampleCenterTimes
            )
        }
    }

    // MARK: - BGMの拍に合わせた切り替え

    private func handleBeatSynchronizationSettingChange() {
        if synchronizesSwitchesToBeats {
            prepareBeatAnalysis()
        } else {
            beatAnalysisTask?.cancel()
            beatAnalysisTask = nil
            isAnalyzingBeats = false
        }
        scheduleNextSwitch()
    }

    private func prepareBeatAnalysis(force: Bool = false) {
        guard synchronizesSwitchesToBeats,
              isAutoSwitching,
              !playable.isEmpty else { return }
        // 一部一致差分では，拍時刻を共通タイムラインへ戻すため位置合わせを先に完了させる．
        guard alignmentMode != .content || hasPreparedAlignment else { return }
        if !force, beatAnalysisCompleted {
            scheduleNextSwitch()
            return
        }

        let sources = makeBeatAnalysisSources()
        guard !sources.isEmpty else { return }
        beatAnalysisTask?.cancel()
        isAnalyzingBeats = true
        beatAnalysisCompleted = false
        detectedBeatCount = 0
        detectedBeatTimes = []

        beatAnalysisTask = Task { @MainActor [weak self] in
            let beatTimes = await VariantBeatAnalyzer.analyze(sources: sources)
            guard let self, !Task.isCancelled else { return }
            self.detectedBeatTimes = beatTimes
            self.detectedBeatCount = beatTimes.count
            self.isAnalyzingBeats = false
            self.beatAnalysisCompleted = true
            self.beatAnalysisTask = nil
            self.scheduleNextSwitch()
        }
    }

    private func makeBeatAnalysisSources() -> [VariantBeatAnalysisSource] {
        let logicalDuration: TimeInterval
        if alignmentMode == .content, let alignedCommonDuration {
            logicalDuration = alignedCommonDuration
        } else {
            logicalDuration = playable.map(\.item.duration)
                .filter { $0 > 0 && $0.isFinite }
                .min() ?? commonDuration
        }
        guard logicalDuration > 0 else { return [] }

        return playable.map {
            VariantBeatAnalysisSource(
                url: $0.url,
                duration: $0.item.duration,
                timelineMapping: $0.timelineMapping,
                logicalDuration: logicalDuration
            )
        }
    }

    private func scheduleNextSwitch(from requestedCurrentTime: TimeInterval? = nil) {
        guard isAutoSwitching, variantCount > 1 else {
            scheduledSwitchTimelineTime = nil
            secondsUntilSwitch = 0
            isNextSwitchBeatAligned = false
            return
        }

        let currentTime = max(
            0,
            requestedCurrentTime ?? group.currentTimelineTime()
        )
        let baseInterval = nextInterval()
        let schedule: VariantBeatSwitchSchedule
        if synchronizesSwitchesToBeats, !detectedBeatTimes.isEmpty {
            schedule = VariantBeatSwitchScheduler.schedule(
                baseInterval: baseInterval,
                currentTime: currentTime,
                beatTimes: detectedBeatTimes
            )
        } else {
            schedule = VariantBeatSwitchSchedule(
                delay: baseInterval,
                isBeatAligned: false
            )
        }

        scheduledSwitchTimelineTime = currentTime + schedule.delay
        secondsUntilSwitch = schedule.delay
        isNextSwitchBeatAligned = schedule.isBeatAligned
    }

    /// 下限を変える。上限より大きくなったら上限も押し上げる。
    func setMinInterval(_ value: Double) {
        let clamped = VariantSwitchSettings.clamp(value)
        minInterval = clamped
        if maxInterval < clamped { maxInterval = clamped }
        persistIntervals()
    }

    /// 上限を変える。下限より小さくなったら下限も引き下げる。
    func setMaxInterval(_ value: Double) {
        let clamped = VariantSwitchSettings.clamp(value)
        maxInterval = clamped
        if minInterval > clamped { minInterval = clamped }
        persistIntervals()
    }

    /// 下限と上限を同じ幅だけ動かして、ばらつきの幅は保ったまま速さだけ変える。
    /// 端に当たったら窓を潰さずそこで止める（上限側で潰すと、戻したときに固定間隔になってしまう）。
    func shiftIntervals(increasing: Bool) {
        let span = maxInterval - minInterval
        let lowest = VariantSwitchSettings.allowedRange.lowerBound
        let highestStart = max(VariantSwitchSettings.allowedRange.upperBound - span, lowest)
        let adjustedMinInterval = VariantSwitchSettings.adjustedInterval(
            minInterval,
            increasing: increasing
        )
        minInterval = min(max(adjustedMinInterval, lowest), highestStart)
        maxInterval = VariantSwitchSettings.clamp(minInterval + span)
        persistIntervals()
    }

    private func persistIntervals() {
        VariantSwitchSettings.minInterval = minInterval
        VariantSwitchSettings.maxInterval = maxInterval
        scheduleNextSwitch()
    }

    private func nextInterval() -> Double {
        maxInterval > minInterval ? Double.random(in: minInterval...maxInterval) : minInterval
    }

    // MARK: - 削除

    func toggleMark(at index: Int) {
        guard variants.indices.contains(index) else { return }
        let id = variants[index].id
        if markedForDeletionIDs.contains(id) {
            markedForDeletionIDs.remove(id)
        } else {
            markedForDeletionIDs.insert(id)
        }
    }

    /// いま表示している差分を削除対象に入れる/外す。
    /// 見比べて「これは同じだ」と分かった瞬間に、その場で印を付けられるようにする。
    func toggleMarkOnActiveVariant() {
        toggleMark(at: activeIndex)
    }

    /// 消したぶんを外して組み直す。いま見ている位置と再生状態はそのまま引き継ぐ。
    ///
    /// 消えたファイルのプレイヤーを走らせたままにはできないし、かといって
    /// 全部作り直して頭から流し直すと、見比べていた場所を見失う。
    /// 残ったものだけで組み直し、同じ位置へ揃えてから続きを流す。
    func removeVariants(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let remaining = playable.filter { !ids.contains($0.item.id) }
        guard remaining.count != playable.count else { return }

        let resumeAt = commonCurrentTime
        let wasPlaying = isPlaying
        let activeID = variants.indices.contains(activeIndex) ? variants[activeIndex].id : nil

        audioNormalizationTask?.cancel()
        audioNormalizationTask = nil
        beatAnalysisTask?.cancel()
        beatAnalysisTask = nil
        isAnalyzingBGMVolume = false
        isAnalyzingBeats = false
        audioLevelAnalysisCompleted = false
        beatAnalysisCompleted = false
        audioLevels = []
        audioNormalizationGains = []
        detectedBeatTimes = []
        detectedBeatCount = 0
        group.cleanup()
        playable = remaining
        variants = remaining.map { Variant(id: $0.item.id, title: $0.item.originalFilename) }
        markedForDeletionIDs.subtract(ids)
        // 見ていたものが消えたなら先頭へ。残っているならその位置を追いかける。
        activeIndex = activeID.flatMap { id in variants.firstIndex { $0.id == id } } ?? 0

        group = SynchronizedPlayerGroup(
            urls: remaining.map(\.url),
            timelineMappings: remaining.map(\.timelineMapping),
            commonTimelineDuration: alignedCommonDuration
        )
        wireGroup()
        applyAudio()
        prepareBGMVolumeNormalization(force: true)
        prepareBeatAnalysis(force: true)
        scheduleNextSwitch(from: resumeAt)

        guard !remaining.isEmpty else {
            isPlaying = false
            return
        }
        if wasPlaying {
            isPlaying = true
            group.startInSync(atTimelineTime: resumeAt)
        } else {
            isPlaying = false
            group.seekAll(toTimelineTime: resumeAt)
        }
    }

    // MARK: - 自動切り替えの時計

    private func startTicking() {
        switchTask?.cancel()
        switchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let tickSeconds = self.map({ viewModel in
                    viewModel.synchronizesSwitchesToBeats
                        ? Self.beatSynchronizedTickSeconds
                        : Self.standardTickSeconds
                }) else { return }
                try? await Task.sleep(nanoseconds: UInt64(tickSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.tick(elapsed: tickSeconds)
            }
        }
    }

    /// 一時停止中は時計も止める（残り時間が減らない＝再開したところから続く）。
    private func tick(elapsed: TimeInterval) {
        guard isPlaying else { return }

        secondsSinceDriftCheck += elapsed
        if secondsSinceDriftCheck >= Self.driftCheckSeconds {
            secondsSinceDriftCheck = 0
            group.resyncIfDrifting(threshold: Self.driftThreshold)
        }

        guard isAutoSwitching, variantCount > 1 else { return }
        guard let scheduledSwitchTimelineTime else {
            scheduleNextSwitch()
            return
        }
        let currentTime = group.currentTimelineTime()
        secondsUntilSwitch = max(0, scheduledSwitchTimelineTime - currentTime)
        if currentTime >= scheduledSwitchTimelineTime {
            showRandomVariant()
        }
    }

    func cleanup() {
        alignmentTask?.cancel()
        alignmentTask = nil
        audioNormalizationTask?.cancel()
        audioNormalizationTask = nil
        beatAnalysisTask?.cancel()
        beatAnalysisTask = nil
        switchTask?.cancel()
        switchTask = nil
        group.cleanup()
    }
}
