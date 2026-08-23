import AVKit
import Combine
import Foundation

// MARK: - 複数プレイヤーの完全同期
//
// AVPlayer を並べて個別に play() すると、デコードの準備ができた順にバラバラと動き出すので、
// まったく同じ動画を並べても開始が数フレームずれる。ずれを無くすために
// 「目的位置へシーク → 全員が再生可能になるまで待つ → preroll でバッファを用意 →
// 共通のホストタイムを指定して一斉に setRate」という順で揃える。
//
// 同時再生（グリッドに並べて見比べる）と差分切り替え再生（1本だけ見せて差し替える）は
// 見せ方こそ違うが、必要な「揃え方」は同じなので、その手順はここ1か所に置く。
@MainActor
final class SynchronizedPlayerGroup {
    let players: [AVPlayer]

    /// いちばん長い動画を基準にした共通の現在位置／総尺。
    var onTimeUpdate: (@MainActor (Double) -> Void)?
    var onDurationUpdate: (@MainActor (Double) -> Void)?
    /// 基準の動画が最後まで再生された。
    var onPlayToEnd: (@MainActor () -> Void)?

    /// 一斉スタートを予約するときの猶予。全プレイヤーへ setRate を配り終える前に
    /// その時刻が過ぎてしまうと、結局バラバラに動き出す。
    private static let syncStartLeadSeconds: Double = 0.15
    /// 再生可能になるまで待つ上限。壊れたファイルが1つ混じっても止まらないようにする。
    private static let readyTimeoutSeconds: Double = 5

    private var leadPlayer: AVPlayer?
    private var leadTimeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var syncStartTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(urls: [URL]) {
        self.players = urls.map { url in
            let player = AVPlayer(url: url)
            // 一斉スタート（setRate(_:time:atHostTime:)）を使うための前提。
            // 既定のままだとプレイヤーが自分の判断で再生開始を遅らせるので同期が崩れる。
            player.automaticallyWaitsToMinimizeStalling = false
            // 各プレイヤーの時間軸を共通のホストクロックに合わせる。
            player.sourceClock = CMClockGetHostTimeClock()
            return player
        }
        observeLeadPlayer()
    }

    // MARK: - 状態

    var isEmpty: Bool { players.isEmpty }

    var isPlaying: Bool { players.contains { $0.rate > 0 } }

    /// いちばん進んでいるプレイヤーと遅れているプレイヤーの開き（秒）。
    /// 長く流していると、デコードの取りこぼしぶんだけ少しずつ開いていく。
    var drift: Double {
        let times = players.compactMap { player -> Double? in
            let seconds = player.currentTime().seconds
            return seconds.isFinite ? seconds : nil
        }
        guard let earliest = times.min(), let latest = times.max() else { return 0 }
        return latest - earliest
    }

    // MARK: - 再生

    func play() { startInSync() }

    func pause() {
        syncStartTask?.cancel()
        syncStartTask = nil
        players.forEach { $0.pause() }
    }

    /// 全プレイヤーを同じ瞬間に走らせる。`seek` を渡すと、まずその位置へ揃えてから開始する。
    func startInSync(seek target: (@MainActor (AVPlayer) -> CMTime?)? = nil) {
        syncStartTask?.cancel()
        let players = self.players
        guard !players.isEmpty else { return }

        // 走ったまま準備を進めると、その間に各プレイヤーが進んでしまって揃わない。
        players.forEach { $0.pause() }
        let seekTargets = players.map { player in (player: player, time: target?(player)) }

        syncStartTask = Task { @MainActor in
            for entry in seekTargets {
                guard let time = entry.time else { continue }
                await entry.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                if Task.isCancelled { return }
            }

            await Self.waitUntilAllReady(players)
            if Task.isCancelled { return }

            for player in players {
                _ = await player.preroll(atRate: 1.0)
                if Task.isCancelled { return }
            }

            let startHostTime = CMClockGetTime(CMClockGetHostTimeClock())
                + CMTime(seconds: Self.syncStartLeadSeconds, preferredTimescale: 600)
            for player in players {
                // time に .invalid を渡すと「今指している位置」をその瞬間に合わせる意味になる。
                player.setRate(1.0, time: .invalid, atHostTime: startHostTime)
            }
        }
    }

    /// ずれが `threshold` 秒を超えていたら、いちばん進んでいる位置へ全員を揃え直す。
    ///
    /// 揃え直すと preroll のぶんだけ一瞬引っかかるので、
    /// 見て分かるほど開いたときにだけ呼ぶ（普段のわずかなずれは放っておくほうが滑らか）。
    @discardableResult
    func resyncIfDrifting(threshold: Double) -> Bool {
        guard isPlaying, drift > threshold else { return false }
        let latest = players.compactMap { player -> Double? in
            let seconds = player.currentTime().seconds
            return seconds.isFinite ? seconds : nil
        }.max() ?? 0
        let target = CMTime(seconds: latest, preferredTimescale: 600)
        startInSync { _ in target }
        return true
    }

    /// 全プレイヤーの `currentItem` が再生可能になるまで待つ（上限つき）。
    private static func waitUntilAllReady(_ players: [AVPlayer]) async {
        let deadline = Date().addingTimeInterval(readyTimeoutSeconds)
        while Date() < deadline {
            if players.allSatisfy({ $0.currentItem?.status == .readyToPlay }) { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
            if Task.isCancelled { return }
        }
    }

    // MARK: - シーク

    /// 再生中なら一斉スタートし直し、停止中ならシークだけして止まったままにする。
    func applySeek(_ target: @escaping @MainActor (AVPlayer) -> CMTime?) {
        guard !isPlaying else {
            startInSync(seek: target)
            return
        }
        syncStartTask?.cancel()
        syncStartTask = nil
        for player in players {
            guard let time = target(player) else { continue }
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func seekAll(by seconds: Double) {
        applySeek { player in
            let current = player.currentTime().seconds
            guard current.isFinite else { return nil }
            return CMTime(seconds: max(0, current + seconds), preferredTimescale: 600)
        }
    }

    func seekAll(toPercentage percentage: Double) {
        applySeek { player in
            guard let duration = player.currentItem?.duration, duration.seconds > 0 else { return nil }
            return CMTime(seconds: duration.seconds * percentage, preferredTimescale: 600)
        }
    }

    /// 全動画を同じ秒数（最短動画の範囲内）へランダムシークする。
    func seekAllToRandomTime() {
        let shortestDuration = players.compactMap { $0.currentItem?.duration.seconds }.min() ?? 0
        guard shortestDuration > 0 else { return }
        let seekCMTime = CMTime(seconds: Double.random(in: 0..<shortestDuration), preferredTimescale: 600)
        applySeek { _ in seekCMTime }
    }

    // MARK: - 監視と後始末

    /// 共通シークバーは1本ぶんの時間軸で足りるので、いちばん長い動画だけを見張る。
    private func observeLeadPlayer() {
        guard let leadPlayer = players.max(by: {
            ($0.currentItem?.duration.seconds ?? 0) < ($1.currentItem?.duration.seconds ?? 0)
        }) else { return }
        self.leadPlayer = leadPlayer

        leadPlayer.publisher(for: \.currentItem?.duration)
            .compactMap { $0?.seconds }
            .filter { !$0.isNaN && $0 > 0 }
            .sink { [weak self] duration in
                self?.onDurationUpdate?(duration)
            }
            .store(in: &cancellables)

        leadTimeObserver = leadPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.onTimeUpdate?(time.seconds)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: leadPlayer.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onPlayToEnd?()
            }
        }
    }

    func cleanup() {
        syncStartTask?.cancel()
        syncStartTask = nil
        cancellables.removeAll()
        if let leadTimeObserver {
            leadPlayer?.removeTimeObserver(leadTimeObserver)
            self.leadTimeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        leadPlayer = nil
        onTimeUpdate = nil
        onDurationUpdate = nil
        onPlayToEnd = nil
        players.forEach { $0.pause() }
    }
}
