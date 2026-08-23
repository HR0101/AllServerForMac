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
    ///
    /// この猶予はそのまま「再生を押してから絵が動き出すまで」の待ち時間になる。
    /// 4K60 を6本並べて実測したところ、配り終えるのにかかるのは 2ms 程度で、
    /// 待ち時間は 0.08 秒以下にすると 82ms 前後で頭打ちになった（0.15 秒だと 153ms）。
    /// 配布コストの40倍の余裕を残しつつ、頭打ちの手前まで詰めた値。
    private static let syncStartLeadSeconds: Double = 0.08
    /// 再生可能になるまで待つ上限。壊れたファイルが1つ混じっても止まらないようにする。
    private static let readyTimeoutSeconds: Double = 5

    private var leadPlayer: AVPlayer?
    private var leadTimeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var syncStartTask: Task<Void, Never>?
    /// 同期準備中は全プレイヤーの rate が一時的に0になるため，利用者が望む再生状態を別に持つ．
    private var shouldBePlaying = false
    /// 相対シークを連打したとき，途中まで移動した各プレイヤーの現在位置を基準にしないための目標値．
    private var pendingRelativeSeekSeconds: Double?
    private var relativeSeekRequestID = 0
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

    var isPlaying: Bool { shouldBePlaying }

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

    func play() {
        invalidatePendingRelativeSeek()
        startInSync()
    }

    func pause() {
        shouldBePlaying = false
        invalidatePendingRelativeSeek()
        syncStartTask?.cancel()
        syncStartTask = nil
        players.forEach { $0.pause() }
    }

    /// 全プレイヤーを同じ瞬間に走らせる。`seek` を渡すと、まずその位置へ揃えてから開始する。
    func startInSync(
        seek target: (@MainActor (AVPlayer) -> CMTime?)? = nil,
        onStarted: (@MainActor () -> Void)? = nil
    ) {
        syncStartTask?.cancel()
        let players = self.players
        guard !players.isEmpty else { return }
        shouldBePlaying = true

        // 走ったまま準備を進めると、その間に各プレイヤーが進んでしまって揃わない。
        players.forEach { $0.pause() }
        // キーを連打したとき，キャンセル済みの古いシークが後から完了して位置を戻さないようにする。
        players.forEach { $0.currentItem?.cancelPendingSeeks() }
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

            // `pause()` は1本ずつ止まるので、止まった位置が数十ミリ秒ばらつく（実測 0.03 秒）。
            // ここで `.invalid`（＝各自がいま指している位置から）で走らせると、そのばらつきが
            // 固定されたうえ一時停止のたびに積み上がる（実測: 一時停止と再生を5往復して 0.34 秒）。
            // 開始位置を明示して揃えれば、同じ5往復でも 0.07 秒に収まる。
            //
            // 全員が同じ時刻へシークした場合は，再開位置にも同じ時刻を明示する。
            // 動画ごとに尺が違う割合シークだけは，各自の行き先を維持する。
            let alignment = Self.alignmentTime(
                for: seekTargets,
                players: players
            )

            let startHostTime = CMClockGetTime(CMClockGetHostTimeClock())
                + CMTime(seconds: Self.syncStartLeadSeconds, preferredTimescale: 600)
            for player in players {
                player.setRate(1.0, time: alignment, atHostTime: startHostTime)
            }
            onStarted?()
        }
    }

    /// 全員へ同じ絶対時刻を指定したシークなら，再開位置にもその時刻を明示する．
    /// 動画ごとに異なる割合シークでは，それぞれのシーク先を維持するため `.invalid` を使う．
    private static func alignmentTime(
        for seekTargets: [(player: AVPlayer, time: CMTime?)],
        players: [AVPlayer]
    ) -> CMTime {
        let requestedSeconds = seekTargets.compactMap { entry -> Double? in
            guard let time = entry.time, time.seconds.isFinite else { return nil }
            return time.seconds
        }
        guard !requestedSeconds.isEmpty else { return commonStartTime(of: players) }
        guard requestedSeconds.count == players.count,
              let earliest = requestedSeconds.min(),
              let latest = requestedSeconds.max(),
              latest - earliest <= 1.0 / 600.0 else {
            return .invalid
        }
        return CMTime(seconds: earliest, preferredTimescale: 600)
    }

    /// そろえにいく開きの上限。これを超えていたら位置には触らない。
    ///
    /// そろえるのは「一時停止のたびに出る数十ミリ秒のばらつき」を消すため。
    /// 同時再生は動画ごとに尺が違い、短いものが終われば位置が何十秒も開くが、
    /// それは直すべきずれではない（そこへ巻き戻すと長いほうが逆再生したように見える）。
    private static let maxAlignableSpread: Double = 1.0

    /// 一斉スタートの基準にする位置。いちばん遅れているものに合わせる
    /// （進んでいるほうへ合わせると、遅れている側が前へ飛んで数フレーム抜ける）。
    /// そろえる根拠がないときは `.invalid`＝各自がいま指している位置のまま走らせる。
    private static func commonStartTime(of players: [AVPlayer]) -> CMTime {
        // 最後まで行ったものはそこで止まったままなので、基準から外す。
        let seconds = players.compactMap { player -> Double? in
            let value = player.currentTime().seconds
            guard value.isFinite else { return nil }
            if let duration = player.currentItem?.duration.seconds, duration.isFinite,
               value >= duration - 0.05 {
                return nil
            }
            return value
        }
        guard let earliest = seconds.min(), let latest = seconds.max() else { return .invalid }
        guard latest - earliest <= maxAlignableSpread else { return .invalid }
        return CMTime(seconds: earliest, preferredTimescale: 600)
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
        invalidatePendingRelativeSeek()
        performSeek(target)
    }

    private func performSeek(
        _ target: @escaping @MainActor (AVPlayer) -> CMTime?,
        onCompleted: (@MainActor () -> Void)? = nil
    ) {
        guard !shouldBePlaying else {
            startInSync(seek: target, onStarted: onCompleted)
            return
        }
        syncStartTask?.cancel()
        players.forEach { $0.currentItem?.cancelPendingSeeks() }
        let seekTargets = players.map { player in (player: player, time: target(player)) }
        syncStartTask = Task { @MainActor in
            for entry in seekTargets {
                guard let time = entry.time else { continue }
                await entry.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                if Task.isCancelled { return }
            }
            onCompleted?()
        }
    }

    func seekAll(by seconds: Double) {
        let base = pendingRelativeSeekSeconds ?? referenceCurrentTime()
        guard base.isFinite else { return }

        let unclampedTarget = max(0, base + seconds)
        let targetSeconds: Double
        if let shortestDuration = shortestFiniteDuration() {
            targetSeconds = min(unclampedTarget, shortestDuration)
        } else {
            targetSeconds = unclampedTarget
        }

        relativeSeekRequestID &+= 1
        let requestID = relativeSeekRequestID
        pendingRelativeSeekSeconds = targetSeconds
        let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        performSeek({ _ in target }) { [weak self] in
            guard let self, self.relativeSeekRequestID == requestID else { return }
            self.pendingRelativeSeekSeconds = nil
        }
    }

    /// シークバーの監視対象と同じ代表動画を基準にし，全員の微小なずれを持ち越さない．
    private func referenceCurrentTime() -> Double {
        if let seconds = leadPlayer?.currentTime().seconds, seconds.isFinite {
            return seconds
        }
        return players.compactMap { player -> Double? in
            let seconds = player.currentTime().seconds
            return seconds.isFinite ? seconds : nil
        }.min() ?? 0
    }

    private func shortestFiniteDuration() -> Double? {
        players.compactMap { player -> Double? in
            guard let seconds = player.currentItem?.duration.seconds,
                  seconds.isFinite,
                  seconds > 0 else { return nil }
            return seconds
        }.min()
    }

    private func invalidatePendingRelativeSeek() {
        relativeSeekRequestID &+= 1
        pendingRelativeSeekSeconds = nil
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
        shouldBePlaying = false
        invalidatePendingRelativeSeek()
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
