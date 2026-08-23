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
    /// 次の自動切り替えまでの残り秒。カウントダウン表示にそのまま使う。
    @Published private(set) var secondsUntilSwitch: Double = 0

    @Published var isAutoSwitching: Bool {
        didSet {
            VariantSwitchSettings.isAutoSwitchEnabled = isAutoSwitching
            secondsUntilSwitch = isAutoSwitching ? nextInterval() : 0
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

    var players: [AVPlayer] { group.players }
    var variantCount: Int { variants.count }

    /// カウントダウンの刻み。表示がなめらかに見える程度に細かく、無駄に起きない程度に粗く。
    private static let tickSeconds: Double = 0.1
    /// これ以上ずれたら揃え直す。60fps で 15 フレームぶん＝切り替えたときに気づく大きさ。
    private static let driftThreshold: Double = 0.25
    /// ずれの点検の間隔。切り替えのたびに調べると、揃え直しが切り替えと重なって二重に引っかかる。
    private static let driftCheckSeconds: Double = 4

    private let group: SynchronizedPlayerGroup
    private var switchTask: Task<Void, Never>?
    private var isSliderEditing = false
    private var secondsSinceDriftCheck: Double = 0

    init(videos: [VideoItem], dataManager: LibraryViewModel) {
        let playable = videos.compactMap { item -> (VideoItem, URL)? in
            guard let url = dataManager.fileURL(for: item) else { return nil }
            return (item, url)
        }

        self.group = SynchronizedPlayerGroup(urls: playable.map(\.1))
        self.variants = playable.map { Variant(id: $0.0.id, title: $0.0.originalFilename) }
        self.isAutoSwitching = VariantSwitchSettings.isAutoSwitchEnabled
        self.minInterval = VariantSwitchSettings.minInterval
        self.maxInterval = VariantSwitchSettings.maxInterval
        self.avoidsImmediateRepeat = VariantSwitchSettings.avoidsImmediateRepeat

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
        applyAudio()
    }

    // MARK: - 再生

    func start() {
        guard !group.isEmpty else { return }
        hasReachedEnd = false
        isPlaying = true
        group.play()
        secondsUntilSwitch = isAutoSwitching ? nextInterval() : 0
        startTicking()
    }

    func togglePlayPause() {
        if isPlaying {
            isPlaying = false
            group.pause()
        } else {
            // 最後まで行ってから押されたら、頭出しし直して続ける。
            if hasReachedEnd {
                hasReachedEnd = false
                group.applySeek { _ in .zero }
            }
            isPlaying = true
            group.play()
        }
    }

    func seek(by seconds: Double) {
        hasReachedEnd = false
        group.seekAll(by: seconds)
    }

    /// 数字キーからの割合ジャンプ（0〜1）。
    func seek(toPercentage percentage: Double) {
        hasReachedEnd = false
        group.seekAll(toPercentage: percentage)
    }

    func sliderEditingChanged(isEditing: Bool) {
        isSliderEditing = isEditing
        guard !isEditing, commonDuration > 0 else { return }
        hasReachedEnd = false
        group.seekAll(toPercentage: commonCurrentTime / commonDuration)
    }

    private func handlePlayToEnd() {
        hasReachedEnd = true
        isPlaying = false
        secondsUntilSwitch = 0
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
        activeIndex = index
        applyAudio()
        secondsUntilSwitch = isAutoSwitching ? nextInterval() : 0
    }

    /// 聞こえるのは表示中の1本だけ。裏の動画は走らせたままミュートする
    /// （止めてしまうと切り替えた瞬間に頭出しからやり直しになる）。
    private func applyAudio() {
        for (index, player) in players.enumerated() {
            let isActive = index == activeIndex
            player.isMuted = !isActive || isMuted
            player.volume = isActive ? volume : 0
        }
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
    func shiftIntervals(by delta: Double) {
        let span = maxInterval - minInterval
        let lowest = VariantSwitchSettings.allowedRange.lowerBound
        let highestStart = max(VariantSwitchSettings.allowedRange.upperBound - span, lowest)
        minInterval = min(max(minInterval + delta, lowest), highestStart)
        maxInterval = VariantSwitchSettings.clamp(minInterval + span)
        persistIntervals()
    }

    private func persistIntervals() {
        VariantSwitchSettings.minInterval = minInterval
        VariantSwitchSettings.maxInterval = maxInterval
        clampCountdownToRange()
    }

    private func nextInterval() -> Double {
        maxInterval > minInterval ? Double.random(in: minInterval...maxInterval) : minInterval
    }

    /// 間隔を狭めたときに、いま走っているカウントダウンだけ長いまま残らないようにする。
    private func clampCountdownToRange() {
        guard isAutoSwitching, secondsUntilSwitch > maxInterval else { return }
        secondsUntilSwitch = maxInterval
    }

    // MARK: - 自動切り替えの時計

    private func startTicking() {
        switchTask?.cancel()
        switchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.tickSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// 一時停止中は時計も止める（残り時間が減らない＝再開したところから続く）。
    private func tick() {
        guard isPlaying else { return }

        secondsSinceDriftCheck += Self.tickSeconds
        if secondsSinceDriftCheck >= Self.driftCheckSeconds {
            secondsSinceDriftCheck = 0
            group.resyncIfDrifting(threshold: Self.driftThreshold)
        }

        guard isAutoSwitching, variantCount > 1 else { return }
        secondsUntilSwitch -= Self.tickSeconds
        if secondsUntilSwitch <= 0 {
            showRandomVariant()
        }
    }

    func cleanup() {
        switchTask?.cancel()
        switchTask = nil
        group.cleanup()
    }
}
