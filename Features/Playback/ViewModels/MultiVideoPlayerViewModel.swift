import AVKit
import Combine
import Foundation

@MainActor
final class MultiVideoPlayerViewModel: ObservableObject {
    @Published var players: [AVPlayer] = []
    @Published var commonCurrentTime: Double = 0
    @Published var commonDuration: Double = 1.0

    private var leadPlayerTimeObserver: Any?
    private var leadPlayer: AVPlayer?
    private var cancellables = Set<AnyCancellable>()
    private var isSliderEditing = false
    private var syncStartTask: Task<Void, Never>?

    /// 一斉スタートを予約するときの猶予。全プレイヤーへ setRate を配り終える前に
    /// その時刻が過ぎてしまうと、結局バラバラに動き出す。
    private static let syncStartLeadSeconds: Double = 0.15
    /// 再生可能になるまで待つ上限。壊れたファイルが1つ混じっても止まらないようにする。
    private static let readyTimeoutSeconds: Double = 5

    /// タイル1枚ぶんの音声設定。並びは `players` と同じ＝画面の配置と同じ。
    struct TileAudio: Identifiable {
        let id: Int
        let title: String
        var volume: Float
        var isMuted: Bool
        /// -1（完全に左）〜 0（中央）〜 +1（完全に右）
        var pan: Float
    }

    @Published var tileAudio: [TileAudio] = []
    /// 処理タップへ値を渡す箱。`tileAudio` と同じ並び。
    private var tapSettings: [AudioTapSettings] = []

    init(videos: [VideoItem], dataManager: LibraryViewModel) {
        let playable = videos.compactMap { item -> (VideoItem, URL)? in
            guard let url = dataManager.fileURL(for: item) else { return nil }
            return (item, url)
        }

        self.players = playable.map { _, url in
            let player = AVPlayer(url: url)
            // 一斉スタート（setRate(_:time:atHostTime:)）を使うための前提。
            // 既定のままだとプレイヤーが自分の判断で再生開始を遅らせるので同期が崩れる。
            player.automaticallyWaitsToMinimizeStalling = false
            // 各プレイヤーの時間軸を共通のホストクロックに合わせる。
            player.sourceClock = CMClockGetHostTimeClock()
            return player
        }

        let defaultPans = MultiPlayerLayout.defaultPans(for: players.count)
        self.tileAudio = playable.enumerated().map { index, entry in
            TileAudio(
                id: index,
                title: entry.0.originalFilename,
                volume: 1,
                isMuted: false,
                pan: defaultPans[index] ?? 0
            )
        }
        self.tapSettings = tileAudio.map { tile in
            let settings = AudioTapSettings()
            settings.update(volume: tile.volume, isMuted: tile.isMuted, pan: tile.pan)
            return settings
        }

        setupLeadPlayerObserver()
        attachAudioProcessing()
    }

    /// 各プレイヤーの音声トラックに処理タップを挟む。
    /// トラックの読み込みは非同期なので、再生開始を待たせないように後から差し込む。
    private func attachAudioProcessing() {
        for (index, player) in players.enumerated() {
            guard let item = player.currentItem, index < tapSettings.count else { continue }
            let settings = tapSettings[index]
            Task { @MainActor in
                guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
                item.audioMix = MultiPlayerAudio.makeAudioMix(for: track, settings: settings)
            }
        }
    }

    /// コンソールで音量・ミュート・定位をいじったときに、その場で音へ反映する。
    func applyTileAudio(at index: Int) {
        guard tileAudio.indices.contains(index), tapSettings.indices.contains(index) else { return }
        let tile = tileAudio[index]
        tapSettings[index].update(volume: tile.volume, isMuted: tile.isMuted, pan: tile.pan)
    }

    /// 全タイルの定位を、いまの並びから決まる既定値へ戻す（音量・ミュートはそのまま）。
    func resetPansToLayout() {
        let defaultPans = MultiPlayerLayout.defaultPans(for: players.count)
        for index in tileAudio.indices {
            tileAudio[index].pan = defaultPans[index] ?? 0
            applyTileAudio(at: index)
        }
    }

    /// 自分以外を全部ミュートする（1つの音だけ聴きたいとき用）。
    func soloTile(at index: Int) {
        for i in tileAudio.indices {
            tileAudio[i].isMuted = (i != index)
            applyTileAudio(at: i)
        }
    }

    func unmuteAllTiles() {
        for i in tileAudio.indices {
            tileAudio[i].isMuted = false
            applyTileAudio(at: i)
        }
    }

    private func setupLeadPlayerObserver() {
        guard let leadPlayer = players.max(by: {
            ($0.currentItem?.duration.seconds ?? 0) < ($1.currentItem?.duration.seconds ?? 0)
        }) else { return }
        self.leadPlayer = leadPlayer

        leadPlayer.publisher(for: \.currentItem?.duration)
            .compactMap { $0?.seconds }
            .filter { !$0.isNaN && $0 > 0 }
            .assign(to: &$commonDuration)

        leadPlayerTimeObserver = leadPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isSliderEditing else { return }
                self.commonCurrentTime = time.seconds
            }
        }
    }

    func commonSliderEditingChanged(isEditing: Bool) {
        self.isSliderEditing = isEditing
        if !isEditing {
            guard commonDuration > 0 else { return }
            seekAll(toPercentage: commonCurrentTime / commonDuration)
        }
    }

    var isPlaying: Bool { players.contains { $0.rate > 0 } }

    func playAll() { startInSync() }

    func pauseAll() {
        syncStartTask?.cancel()
        syncStartTask = nil
        players.forEach { $0.pause() }
    }

    func togglePlayPauseAll() {
        if isPlaying {
            pauseAll()
        } else {
            startInSync()
        }
    }

    /// 全プレイヤーを同じ瞬間に走らせる。`seek` を渡すと、まずその位置へ揃えてから開始する。
    ///
    /// 個別に `play()` を呼ぶと、デコードの準備ができた順にバラバラと動き出すので、
    /// 同じ動画を並べても開始が数フレームずれる。ずれを無くすために
    /// 「目的位置へシーク → 全員が再生可能になるまで待つ → preroll でバッファを用意 →
    /// 共通のホストタイムを指定して一斉に setRate」という順で揃える。
    func startInSync(seek target: ((AVPlayer) -> CMTime?)? = nil) {
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

    /// 全プレイヤーの `currentItem` が再生可能になるまで待つ（上限つき）。
    private static func waitUntilAllReady(_ players: [AVPlayer]) async {
        let deadline = Date().addingTimeInterval(readyTimeoutSeconds)
        while Date() < deadline {
            if players.allSatisfy({ $0.currentItem?.status == .readyToPlay }) { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
            if Task.isCancelled { return }
        }
    }

    /// 再生中なら一斉スタートし直し、停止中ならシークだけして止まったままにする。
    private func applySeek(_ target: @escaping (AVPlayer) -> CMTime?) {
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

    /// 全動画を同じ秒数（最短動画の範囲内）へランダムシークする
    func seekAllToRandomTime() {
        let shortestDuration = players.compactMap { $0.currentItem?.duration.seconds }.min() ?? 0
        guard shortestDuration > 0 else { return }
        let seekCMTime = CMTime(seconds: Double.random(in: 0..<shortestDuration), preferredTimescale: 600)
        applySeek { _ in seekCMTime }
    }

    func cleanup() {
        syncStartTask?.cancel()
        syncStartTask = nil
        if let observer = leadPlayerTimeObserver {
            leadPlayer?.removeTimeObserver(observer)
            leadPlayerTimeObserver = nil
        }
        leadPlayer = nil
        players.forEach { $0.pause() }
        players.removeAll()
    }
}
