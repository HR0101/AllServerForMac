import AppKit
import AVKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class VideoPlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var chapterPoints: [ChapterPoint] = []
    @Published var currentVideo: VideoItem
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1.0
    @Published var isPlaybackPlaying = false

    /// 前後移動の対象となる動画リスト（動画のみ）
    let allVideos: [VideoItem]
    private let dataManager: LibraryViewModel
    /// 視聴位置と再生履歴の保管庫（ブラウザ・iPhone と共有）。
    private let watchState: WatchStateStore
    /// 自動再生・リピート・シャッフル・再生速度。
    let settings: PlaybackSettings
    /// 「◯:◯◯ から再開しました」の一時表示。nil のときは出さない。
    @Published var resumeNotice: String?
    /// いま観ている動画がお気に入りか。
    /// ビューは `dataManager` を監視していない（巨大な配列の更新で再描画が走らないよう
    /// ただの let で持っている）ので、表示に要る分だけここへ写しておく。
    @Published private(set) var isCurrentVideoFavorite = false
    /// この動画が持つ音声トラック（2本以上あるときだけ選択 UI を出す）。
    @Published private(set) var audioTracks: [MediaTrackChoice] = []
    /// この動画が持つ字幕トラック。先頭は必ず「オフ」。空なら字幕なし。
    @Published private(set) var subtitleTracks: [MediaTrackChoice] = []
    @Published private(set) var selectedAudioIndex = MediaTrackChoice.offIndex
    @Published private(set) var selectedSubtitleIndex = MediaTrackChoice.offIndex
    private var chapterGenerationTask: Task<Void, Never>?
    private var playerTimeObserver: Any?
    private weak var observedPlayer: AVPlayer?
    private var cancellables = Set<AnyCancellable>()
    private var preloadTasks: [UUID: Task<Void, Never>] = [:]
    private var assetCache: [UUID: AVURLAsset] = [:]
    private var isSliderEditing = false
    private var resumeNoticeTask: Task<Void, Never>?
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var mediaSelectionTask: Task<Void, Never>?
    /// コントロールセンター表示とメディアキーの受け口。
    private let nowPlaying = NowPlayingCenter()
    /// 前回の続きへシークしている最中。この間の再生位置は「まだ移動前の値」なので、
    /// 記録に使うとせっかくの視聴位置を先頭付近で上書きしてしまう。
    private var isRestoringPosition = false
    /// ループ先頭へシークしている間，末尾側の時刻通知で表示位置を戻さないためのフラグ．
    private var isRestartingLoop = false
    /// シャッフル再生の「袋」。まだ流していない動画を混ぜて入れておき、端から取り出す。
    /// 毎回その場で randomElement() を引くと、数本前に観たものがすぐ再来するうえ、
    /// 「全部観たら終わり」を表現できない（袋が空になったかどうかが一巡の合図になる）。
    /// セッション限りの状態なので、UserDefaults へ保存する `PlaybackSettings` には置かない。
    private var shuffleBag: [UUID] = []
    /// 袋を一度でも作ったか。「まだ作っていない」と「使い切った」を区別しないと、
    /// 再生の途中でシャッフルを入れたときに空の袋を「もう全部観た」と誤解して即座に止まる。
    private var isShuffleBagPrepared = false
    /// 実際に再生した順（古い順）。シャッフル中の「前へ」は、リストの並びではなくこちらを遡る。
    private var playedStack: [UUID] = []
    /// プレイヤーを開いている間ずっと張っておく購読。
    /// プレイヤー側の購読（`cancellables`）は動画を切り替えるたびに張り直すので、
    /// 寿命が違うこちらは別に持つ。
    private var sessionObservers = Set<AnyCancellable>()
    private let adjacentPreloadRadius = 4
    /// 遡れる履歴の上限。これより古いところまで戻ることは実際には無い。
    private let maxPlayedStackCount = 100
    /// 切り替えた直後の「準備が整うまで待ってから再生する」処理。
    private var pendingStartTask: Task<Void, Never>?
    /// 連打で追い越された準備が、もう映していない動画の再生を始めてしまわないための世代番号。
    private var playbackStartGeneration = 0
    private let chapterGenerationDelayNanoseconds: UInt64 = 280_000_000
    private let playerTimeObserverInterval: TimeInterval = 0.25
    /// 差し替えた直後にデコードの準備を待つ上限。壊れたファイルを掴んでも
    /// 「次へ送ったのに始まらない」にならないよう、ここを過ぎたら暖めを諦めてそのまま再生する。
    private let playbackStartReadyTimeoutSeconds: TimeInterval = 1.5
    private let playbackStartPollNanoseconds: UInt64 = 20_000_000
    private let defaultDuration: Double = 1.0

    /// 音量とミュート。動画を切り替えても、次にプレイヤーを開いたときも引き継ぐ。
    @Published var volume: Float {
        didSet {
            player?.volume = volume
            UserDefaults.standard.set(Double(volume), forKey: Self.volumeDefaultsKey)
        }
    }
    @Published var isMuted: Bool {
        didSet {
            player?.isMuted = isMuted
            UserDefaults.standard.set(isMuted, forKey: Self.mutedDefaultsKey)
        }
    }

    /// 映像を画面いっぱいに広げる（上下左右は切り落とす）。
    /// レターボックスごと焼き込まれている素材を観るための切り替え。
    @Published var fillsScreen: Bool {
        didSet { UserDefaults.standard.set(fillsScreen, forKey: Self.fillsScreenDefaultsKey) }
    }

    /// 映像面へ渡す収め方。`fillsScreen` の言い換えだが、
    /// レイヤー側が AVFoundation の型しか受け取らないのでここで変換する。
    var videoGravity: AVLayerVideoGravity { fillsScreen ? .resizeAspectFill : .resizeAspect }

    static let volumeDefaultsKey = "player.volume"
    static let mutedDefaultsKey = "player.muted"
    static let fillsScreenDefaultsKey = "player.fillsScreen"

    init(
        videos: [VideoItem],
        currentVideo: VideoItem,
        dataManager: LibraryViewModel,
        watchState: WatchStateStore,
        settings: PlaybackSettings
    ) {
        self.allVideos = videos
        self.currentVideo = currentVideo
        self.dataManager = dataManager
        self.watchState = watchState
        self.settings = settings
        // 未設定なら最大音量から始める（bool/double の既定値 0 をそのまま使うと無音になる）。
        let storedVolume = UserDefaults.standard.object(forKey: Self.volumeDefaultsKey) as? Double
        self.volume = Float(storedVolume ?? 1.0)
        self.isMuted = UserDefaults.standard.bool(forKey: Self.mutedDefaultsKey)
        // 未設定なら従来どおり全体が収まる表示。
        self.fillsScreen = UserDefaults.standard.bool(forKey: Self.fillsScreenDefaultsKey)
    }

    func setupPlayer() {
        guard player == nil else { return }
        guard let item = playerItem(for: currentVideo) else {
            self.player = nil
            return
        }
        // View 更新中に @Published を変更しないよう次のループで実行する
        Task { @MainActor in
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.automaticallyWaitsToMinimizeStalling = false
            // 終端で映像面を消さず，先頭フレームの準備中も最後のフレームを保持する．
            newPlayer.actionAtItemEnd = .none
            // didSet は init 中に走らないので、プレイヤー生成時に現在値を当て直す。
            newPlayer.volume = self.volume
            newPlayer.isMuted = self.isMuted
            // play() が使う速度。rate に直接入れると一時停止中でも再生が始まってしまう。
            newPlayer.defaultRate = Float(self.settings.rate)
            self.player = newPlayer
            self.configurePlaybackMonitoring(for: newPlayer)
            self.observeSessionState()
            self.startWatching(self.currentVideo, on: newPlayer)
            self.activateNowPlaying()
            // 1本目も同じ順序で始める。開いた直後の頭が引っかかるのは切り替え時と同じ理由。
            self.startPlaybackWhenReady(on: newPlayer, item: item)
            self.preloadNearbyAssets(around: self.currentVideo)
            self.generateChapterPoints()
        }
    }

    private func generateChapterPoints() {
        chapterGenerationTask?.cancel()
        chapterGenerationTask = Task {
            let targetID = currentVideo.id
            guard let targetAsset = player?.currentItem?.asset else { return }
            chapterPoints.removeAll()

            try? await Task.sleep(nanoseconds: chapterGenerationDelayNanoseconds)
            if Task.isCancelled || currentVideo.id != targetID { return }

            guard let asset = player?.currentItem?.asset,
                  asset === targetAsset,
                  let duration = try? await asset.load(.duration) else { return }

            for i in 0..<10 {
                if Task.isCancelled || currentVideo.id != targetID { return }
                let percentage = Double(i) / 10.0
                let timeInSeconds = duration.seconds * percentage
                guard timeInSeconds.isFinite else { continue }
                let time = CMTime(seconds: timeInSeconds, preferredTimescale: 600)

                let cgImage = await PlayerThumbnailGenerator.generateLiveThumbnail(for: asset, at: time)
                let chapterPoint = ChapterPoint(
                    percentage: percentage,
                    time: time,
                    thumbnail: cgImage != nil ? Image(nsImage: NSImage(cgImage: cgImage!, size: .zero)) : nil
                )
                if Task.isCancelled || currentVideo.id != targetID { return }
                self.chapterPoints.append(chapterPoint)
                self.chapterPoints.sort { $0.percentage < $1.percentage }
            }
        }
    }

    func cleanup() {
        commitProgress()
        nowPlaying.deactivate()
        mediaSelectionTask?.cancel()
        resumeNoticeTask?.cancel()
        resumeNotice = nil
        chapterGenerationTask?.cancel()
        cancelPendingPlaybackStart()
        if let observer = playerTimeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(observer)
        }
        playerTimeObserver = nil
        observedPlayer = nil
        cancellables.removeAll()
        sessionObservers.removeAll()
        shuffleBag.removeAll()
        isShuffleBagPrepared = false
        playedStack.removeAll()
        preloadTasks.values.forEach { $0.cancel() }
        preloadTasks.removeAll()
        assetCache.removeAll()
        player?.pause()
        player = nil
        currentTime = 0
        duration = defaultDuration
        isPlaybackPlaying = false
        isRestartingLoop = false
    }

    func seek(by seconds: Double) {
        guard let player else { return }
        let baseSeconds = player.currentTime().seconds
        guard baseSeconds.isFinite else { return }
        seek(toSeconds: baseSeconds + seconds)
    }

    func seek(toPercentage percentage: Double) {
        guard let player = player, let duration = player.currentItem?.duration, duration.seconds > 0 else { return }
        seek(toSeconds: duration.seconds * percentage)
    }

    func seekToRandomTime() {
        guard let player = player, let duration = player.currentItem?.duration, duration.seconds > 0 else { return }
        seek(toSeconds: Double.random(in: 0..<duration.seconds))
    }

    func playPause() {
        guard let player = player else { return }
        if player.rate == 0 {
            player.play()
            isPlaybackPlaying = true
            refreshNowPlaying()
        } else {
            // 準備待ちの直後に Space を2回叩かれた場合でも、止めたまま保つ。
            cancelPendingPlaybackStart()
            isRestartingLoop = false
            player.pause()
            isPlaybackPlaying = false
            commitProgress()
        }
    }

    func play() {
        guard let player, player.rate == 0 else { return }
        player.play()
        isPlaybackPlaying = true
        refreshNowPlaying()
    }

    func pause() {
        // 準備待ちの最中は rate が 0 なので guard に弾かれる。その前に待ちを畳まないと、
        // リモート操作やメディアキーで止めたのに暖め終わった瞬間に走り出す。
        cancelPendingPlaybackStart()
        guard let player, player.rate != 0 else { return }
        isRestartingLoop = false
        player.pause()
        isPlaybackPlaying = false
        commitProgress()
    }

    /// 位置を確定させ、一覧の視聴済みバーにも反映させる。
    /// 一時停止・動画の切り替え・プレイヤーを閉じた時など区切りの良い所でだけ呼ぶ。
    private func commitProgress() {
        recordCurrentProgress(force: true)
        watchState.publishPendingChanges()
        refreshNowPlaying()
    }

    func playbackSliderEditingChanged(isEditing: Bool) {
        isSliderEditing = isEditing
        guard !isEditing else { return }
        seek(toSeconds: currentTime)
    }

    /// 再生する動画を差し替える。
    /// `recordsPlayedStack` は「前へ」で戻ってきた時だけ false にする
    /// （戻った先をもう一度履歴に積むと、← を押し続けても同じ2本を往復してしまう）。
    /// 差し替えられたら true。読めないファイル（外付けを抜いた、名前を変えた等）では false を返す。
    /// 袋や履歴を先に動かしてから失敗すると辻褄が合わなくなるので、呼び出し側が戻せるようにしてある。
    @discardableResult
    private func changeVideo(to newVideo: VideoItem, recordsPlayedStack: Bool = true) -> Bool {
        guard let newItem = playerItem(for: newVideo) else { return false }
        isRestartingLoop = false
        // 切り替える前に、いま観ていた動画の位置を確定させる。
        commitProgress()
        if recordsPlayedStack, newVideo.id != currentVideo.id {
            playedStack.append(currentVideo.id)
            if playedStack.count > maxPlayedStackCount { playedStack.removeFirst() }
        }
        // 実際に流したものは袋から必ず抜く。手動で飛んだ動画が袋に残っていると、
        // そのあとの自動再生がもう一度同じものを選んでしまう。
        shuffleBag.removeAll { $0 == newVideo.id }
        self.currentVideo = newVideo
        self.currentTime = 0
        self.duration = defaultDuration
        self.isSliderEditing = false
        self.player?.replaceCurrentItem(with: newItem)
        if let player {
            // 再開位置のシークを先に出してから準備待ちへ入る。順序が逆だと
            // 暖めている最中にシークが割り込み、preroll が毎回無駄になる。
            startWatching(newVideo, on: player)
            startPlaybackWhenReady(on: player, item: newItem)
        }
        preloadNearbyAssets(around: newVideo)
        generateChapterPoints()
        return true
    }

    /// 差し替えた item が再生可能になり、デコードが暖まってから再生を始める。
    ///
    /// `replaceCurrentItem` の直後に `play()` すると、先頭フレームが揃う前に走り出すので
    /// 自動再生で次へ送った瞬間に画が引っかかる（`preferredForwardBufferDuration` が 1 秒しかなく、
    /// `preloadNearbyAssets` が先読みしているのも `.isPlayable` と `.duration` だけで、
    /// デコーダのバッファは冷たいまま）。同時再生の `SynchronizedPlayerGroup` が使っている
    /// 「再生可能になるまで待つ → preroll → 開始」という順序をここでも踏む。
    private func startPlaybackWhenReady(on player: AVPlayer, item: AVPlayerItem) {
        // 次へ次へと連打されたときは、最後の1本だけが走り出せばよい。追い越された準備が
        // 後から完了しても、世代番号が合わないので再生を始めない。
        pendingStartTask?.cancel()
        playbackStartGeneration &+= 1
        let generation = playbackStartGeneration
        let deadline = Date().addingTimeInterval(playbackStartReadyTimeoutSeconds)
        let pollNanoseconds = playbackStartPollNanoseconds
        // 走らせたまま準備すると、暖め終わる前に AVPlayer が自分で新しい item を流し始めて
        // preroll が無駄になる（rate は item を差し替えても引き継がれる）。
        player.pause()

        pendingStartTask = Task { @MainActor [weak self, weak player] in
            var canWarmUp = false
            while Date() < deadline {
                guard let self, self.playbackStartGeneration == generation,
                      let player, player.currentItem === item else { return }
                // 再開位置へのシークが走っている間に preroll すると必ず割り込まれて false が返る。
                // `isRestoringPosition` はそのシークが片付いたかどうかの目印なので、これが開くまで待つ。
                if item.status == .readyToPlay, !self.isRestoringPosition {
                    canWarmUp = true
                    break
                }
                // 読めないファイルをいくら待っても readyToPlay にはならない。暖めずに先へ進む。
                if item.status == .failed { break }
                try? await Task.sleep(nanoseconds: pollNanoseconds)
                if Task.isCancelled { return }
            }

            guard let self, !Task.isCancelled,
                  self.playbackStartGeneration == generation,
                  let player, self.player === player,
                  player.currentItem === item else { return }

            // 速度は待ち始めた時点ではなく**ここで**読む。待っている間は player.rate が 0 なので
            // applyRate() が生の rate を書き換えられず、開始時に古い値を入れると
            // 画面の「1.25×」表示と実際の速度が食い違ったまま残る。
            let playbackRate = Float(self.settings.rate)

            if canWarmUp {
                // preroll はシークに割り込まれると false を返す。ここは普段からシークと重なる
                // 場所なので、結果は「暖まるのを待つ」ためだけに使い、成否で分岐しない。
                // 失敗を理由に止めてしまうと「次へ送ったのに何も起きない」になる。
                _ = await player.preroll(atRate: playbackRate)
                guard !Task.isCancelled,
                      self.playbackStartGeneration == generation,
                      self.player === player,
                      player.currentItem === item else { return }
            }
            player.playImmediately(atRate: playbackRate)
            self.isPlaybackPlaying = true
            self.refreshNowPlaying()
        }
    }

    /// 準備待ちの取り消し。待っている間に止めたのに、暖め終わってから走り出すのを防ぐ。
    private func cancelPendingPlaybackStart() {
        playbackStartGeneration &+= 1
        pendingStartTask?.cancel()
        pendingStartTask = nil
    }

    // MARK: - 字幕・音声トラック

    /// 音声・字幕トラック1件分。`AVMediaSelectionOption` をそのまま SwiftUI へ渡すと
    /// Identifiable/Hashable が扱いづらいので、グループ内の位置だけを持ち回る。
    struct MediaTrackChoice: Identifiable, Hashable {
        /// `AVMediaSelectionGroup.options` のインデックス。`offIndex` は「オフ」。
        let index: Int
        let displayName: String

        static let offIndex = -1
        var id: Int { index }
    }

    /// いま鳴っている item から選択肢を読み直す。読み込みは非同期なので、
    /// 戻ってきた時点で対象がまだ同じかを必ず確かめる。
    private func reloadMediaSelections(for video: VideoItem) {
        mediaSelectionTask?.cancel()
        audibleGroup = nil
        legibleGroup = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioIndex = MediaTrackChoice.offIndex
        selectedSubtitleIndex = MediaTrackChoice.offIndex

        guard let item = player?.currentItem else { return }
        let asset = item.asset
        let targetID = video.id

        mediaSelectionTask = Task { [weak self] in
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled else { return }
            guard let self, self.currentVideo.id == targetID, self.player?.currentItem === item else { return }
            self.applyMediaSelectionGroups(audible: audible, legible: legible, in: item)
        }
    }

    private func applyMediaSelectionGroups(
        audible: AVMediaSelectionGroup?,
        legible: AVMediaSelectionGroup?,
        in item: AVPlayerItem
    ) {
        audibleGroup = audible
        legibleGroup = legible

        // 音声に「オフ」は出さない（消したいならミュートを使う）。
        audioTracks = (audible?.options ?? []).enumerated().map { offset, option in
            MediaTrackChoice(index: offset, displayName: Self.trackName(option, fallbackIndex: offset))
        }

        let legibleOptions = legible?.options ?? []
        subtitleTracks = legibleOptions.isEmpty ? [] : [
            MediaTrackChoice(index: MediaTrackChoice.offIndex, displayName: "オフ")
        ] + legibleOptions.enumerated().map { offset, option in
            MediaTrackChoice(index: offset, displayName: Self.trackName(option, fallbackIndex: offset))
        }

        let selection = item.currentMediaSelection
        selectedAudioIndex = audible
            .flatMap { group in selection.selectedMediaOption(in: group).flatMap(group.options.firstIndex(of:)) }
            ?? (audioTracks.isEmpty ? MediaTrackChoice.offIndex : 0)
        selectedSubtitleIndex = legible
            .flatMap { group in selection.selectedMediaOption(in: group).flatMap(group.options.firstIndex(of:)) }
            ?? MediaTrackChoice.offIndex
    }

    private static func trackName(_ option: AVMediaSelectionOption, fallbackIndex: Int) -> String {
        let name = option.displayName
        return name.isEmpty ? "トラック \(fallbackIndex + 1)" : name
    }

    func selectAudioTrack(index: Int) {
        guard let group = audibleGroup, let item = player?.currentItem,
              group.options.indices.contains(index) else { return }
        item.select(group.options[index], in: group)
        selectedAudioIndex = index
    }

    func selectSubtitleTrack(index: Int) {
        guard let group = legibleGroup, let item = player?.currentItem else { return }
        if index == MediaTrackChoice.offIndex {
            // グループが空選択を許さない場合、この指示は無視される（字幕を消せない動画がある）。
            item.select(nil, in: group)
        } else if group.options.indices.contains(index) {
            item.select(group.options[index], in: group)
        } else {
            return
        }
        selectedSubtitleIndex = index
    }

    // MARK: - コントロールセンター表示とメディアキー

    private func activateNowPlaying() {
        nowPlaying.activate(
            handlers: NowPlayingCenter.Handlers(
                play: { [weak self] in self?.play() },
                pause: { [weak self] in self?.pause() },
                toggle: { [weak self] in self?.playPause() },
                next: { [weak self] in self?.playNextVideo() },
                previous: { [weak self] in self?.playPreviousVideo() },
                seek: { [weak self] seconds in self?.seek(toSeconds: seconds) },
                skip: { [weak self] seconds in self?.seek(by: seconds) }
            )
        )
    }

    /// 再生・一時停止・シーク・動画の切り替えといった節目で呼ぶ
    /// （経過時間はシステムが再生速度から補間するので、毎秒は要らない）。
    private func refreshNowPlaying() {
        nowPlaying.update(
            title: (currentVideo.originalFilename as NSString).deletingPathExtension,
            duration: effectiveDuration,
            elapsed: currentTime,
            rate: isPlaybackPlaying ? settings.rate : 0,
            artworkURL: dataManager.thumbnailStorageURL
                .appendingPathComponent(currentVideo.id.uuidString)
                .appendingPathExtension("jpg")
        )
    }

    // MARK: - 終端の処理（自動再生・リピート・シャッフル）

    /// 最後まで再生し終わったときの分岐。
    /// 「自動再生」が次へ進むかどうかの親スイッチで、「リストをリピート」は
    /// その上で末尾を先頭へ折り返すかを決める。1本リピートだけは進む話ではないので常に効く。
    private func handlePlaybackEnded() {
        // 最後まで観たので視聴位置は捨てる（次に開いたら頭から）。
        watchState.markFinished(videoID: currentVideo.id)
        watchState.publishPendingChanges()

        if settings.repeatMode == .one {
            restartCurrentVideoSmoothly()
            return
        }

        guard settings.autoPlayNext, let next = nextVideoForAutoPlay() else {
            player?.pause()
            isPlaybackPlaying = false
            return
        }
        if next.id == currentVideo.id {
            restartCurrentVideoSmoothly()
            return
        }
        changeVideo(to: next)
    }

    /// 終端のフレームを表示したまま先頭へ移動し，シーク完了後に再生を再開する．
    private func restartCurrentVideoSmoothly() {
        guard let player, let currentItem = player.currentItem else { return }
        let playbackRate = Float(settings.rate)
        currentTime = 0
        isRestartingLoop = true
        refreshNowPlaying()

        player.seek(
            to: .zero,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak player] finished in
            Task { @MainActor [weak self, weak player] in
                guard let self else { return }
                guard self.isRestartingLoop else { return }
                self.isRestartingLoop = false
                guard finished,
                      let player,
                      self.player === player,
                      player.currentItem === currentItem else { return }
                player.playImmediately(atRate: playbackRate)
                self.isPlaybackPlaying = true
                self.refreshNowPlaying()
            }
        }
    }

    /// 自動再生で次に流す動画。無ければ nil（＝その場で止まる）。
    /// シャッフル中は袋から1本取り出すので、**呼ぶと袋が減る**。
    /// 減らさずに「次があるか」だけ知りたいときは `hasNextVideo` を使う。
    private func nextVideoForAutoPlay() -> VideoItem? {
        guard allVideos.count > 1 else {
            return settings.repeatMode == .all ? currentVideo : nil
        }
        if settings.isShuffleEnabled {
            return takeNextShuffledVideo()
        }
        guard let index = allVideos.firstIndex(of: currentVideo) else { return allVideos.first }
        let nextIndex = index + 1
        if allVideos.indices.contains(nextIndex) { return allVideos[nextIndex] }
        return settings.repeatMode == .all ? allVideos.first : nil
    }

    /// 次に流せる動画があるか。ボタンの活性判定はビューの描画中に何度も読まれるので、
    /// 袋を減らさずに答える必要がある（`nextVideoForAutoPlay()` は取り出してしまう）。
    /// 判断の中身は `nextVideoForAutoPlay()` と必ず揃えること。ここがズレると
    /// 「ボタンは灰色なのに自動再生は次へ進む」が復活する。
    private var hasNextVideo: Bool {
        guard allVideos.count > 1 else { return settings.repeatMode == .all }
        if settings.isShuffleEnabled {
            // 袋を作る前＝まだ一巡していないので必ず次がある。
            // 使い切った後に続くのは、リストをリピートする時だけ。
            return !isShuffleBagPrepared || !shuffleBag.isEmpty || settings.repeatMode == .all
        }
        guard let index = allVideos.firstIndex(of: currentVideo) else { return true }
        return allVideos.indices.contains(index + 1) || settings.repeatMode == .all
    }

    /// 袋から次の1本を取り出す。袋が空になったのは「リストを一巡した」ということなので、
    /// 折り返すのは `リストをリピート` の時だけ。リピートなしのシャッフルは
    /// 全部流し終えたら止まるのが正しい（以前はここで無条件に抽選し続けていた）。
    private func takeNextShuffledVideo() -> VideoItem? {
        if !isShuffleBagPrepared {
            refillShuffleBag()
        } else if shuffleBag.isEmpty {
            guard settings.repeatMode == .all else { return nil }
            refillShuffleBag()
        }

        let itemByID = Dictionary(
            allVideos.lazy.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        // 袋を作った後にリストから消えた動画は読み飛ばす。
        while let id = shuffleBag.popLast() {
            if let item = itemByID[id], item.id != currentVideo.id { return item }
        }
        return nil
    }

    /// 袋を詰め直す。いま流している動画は入れない（次の1本として選ばれてしまう）。
    private func refillShuffleBag() {
        let currentID = currentVideo.id
        shuffleBag = allVideos.lazy.map(\.id).filter { $0 != currentID }.shuffled()
        isShuffleBagPrepared = true
    }

    /// プレイヤーを開いている間ずっと見ておくもの。
    private func observeSessionState() {
        sessionObservers.removeAll()

        // シャッフルを入れ直したら袋を作り直す。使いかけの袋を持ち越すと、
        // 入れ直した直後に「もう全部観た」と誤解して自動再生が止まる。
        // `@Published` の購読は登録した時点で現在値が1回流れるので、
        // 再生開始時にシャッフルが入っていればここで袋が用意される。
        settings.$isShuffleEnabled
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.shuffleBag.removeAll()
                    self.isShuffleBagPrepared = false
                    if isEnabled { self.refillShuffleBag() }
                }
            }
            .store(in: &sessionObservers)

        // iPhone やブラウザでお気に入りを付け外しすると、`/sync` の通知を受けて
        // ライブラリ側が書き換わる。その時に再生画面の表示も追従させる。
        watchState.$favorites
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshFavoriteState() }
            }
            .store(in: &sessionObservers)
    }

    // MARK: - 音量・ミュート

    /// 音量を1段変える。全画面再生中はメニューバーもウィンドウのツールバーも出ないので、
    /// キーで触れないと右上へカーソルを運ぶしかない。
    func adjustVolume(by delta: Float) {
        let updated = min(max(volume + delta, 0), 1)
        // 音を上げたのに無音のままだと操作が効いていないように見えるので、ミュートは解く。
        if isMuted, delta > 0 { isMuted = false }
        guard abs(updated - volume) > 0.0001 else { return }
        volume = updated
    }

    func toggleMute() { isMuted.toggle() }

    // MARK: - 映像の収め方

    func toggleFillsScreen() { fillsScreen.toggle() }

    // MARK: - コマ送り

    /// 1コマ進める／戻す。コマ送りは止めて確かめるための操作なので、まず止める。
    ///
    /// `isPlaybackPlaying` で分岐させないこと。切り替え直後の準備待ち（`startPlaybackWhenReady`）は
    /// まだ rate が 0 なのでここが false になり、分岐させると待ちが畳まれないまま
    /// コマを送った直後に再生が走り出す。`pause()` は待ちを畳んでから
    /// 実際に止まっているかを見るので、そのまま呼んで構わない。
    func stepFrame(by count: Int) {
        guard count != 0, let item = player?.currentItem else { return }
        pause()
        guard count > 0 ? item.canStepForward : item.canStepBackward else { return }
        item.step(byCount: count)
        // step 直後は currentTime がまだ動いていないことがあるので、次のループで表示を合わせる。
        Task { @MainActor [weak self] in
            guard let self, let item = self.player?.currentItem else { return }
            let seconds = item.currentTime().seconds
            guard seconds.isFinite else { return }
            self.currentTime = min(max(seconds, 0), self.duration)
            self.recordCurrentProgress(force: true)
            self.refreshNowPlaying()
        }
    }

    // MARK: - お気に入り

    /// 観ている最中に付け外しする。一覧側と同じ `LibraryViewModel.toggleFavorite` を通すので、
    /// iPhone・ブラウザへの橋渡し（`AppViewModel.bridgeFavorites()`）もそのまま働く。
    func toggleCurrentVideoFavorite() {
        dataManager.toggleFavorite(videoIDs: [currentVideo.id])
        refreshFavoriteState()
    }

    /// `dataManager.videos` を正として読み直す。
    private func refreshFavoriteState() {
        let id = currentVideo.id
        isCurrentVideoFavorite = dataManager.videos.first(where: { $0.id == id })?.isFavorite ?? false
    }

    // MARK: - 再生速度

    /// 速度を変える。一時停止中は次に再生した時から効かせる（勝手に再生を始めない）。
    func applyRate(_ rate: Double) {
        settings.rate = PlaybackSettings.normalizedRate(rate)
        guard let player else { return }
        player.defaultRate = Float(settings.rate)
        if player.rate != 0 { player.rate = Float(settings.rate) }
        refreshNowPlaying()
    }

    func stepRate(by steps: Int) {
        settings.stepRate(by: steps)
        applyRate(settings.rate)
    }

    // MARK: - 視聴位置と再生履歴

    /// 履歴に積み、前回の続きがあればそこへ飛ばす。
    private func startWatching(_ video: VideoItem, on player: AVPlayer) {
        watchState.recordHistory(videoID: video.id)
        reloadMediaSelections(for: video)
        refreshFavoriteState()
        refreshNowPlaying()

        guard let resume = watchState.resumeSeconds(for: video.id, duration: video.duration) else {
            // 続きのない動画へ移ったら、前の動画のシークを待っていた蓋をここで外す。
            // 前の seek 完了は動画 ID で弾かれるため、ここで外さないと開かずじまいになり、
            // 時刻通知が素通しされて再生位置がまったく進まなくなる。
            isRestoringPosition = false
            resumeNotice = nil
            return
        }
        // seek 完了を待たずに currentTime を進めておく。シークバーが一瞬 0 に戻るのを防ぐ。
        currentTime = resume
        // 完了までの間に届く「移動前の再生位置」で視聴位置を上書きしないよう蓋をする。
        // 別のシークに割り込まれた場合も finished: false で必ず呼ばれるので開けっ放しにならない。
        isRestoringPosition = true
        player.seek(
            to: CMTime(seconds: resume, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // 連続で動画を切り替えたとき、古い seek の完了で次の動画の蓋を外さない。
                guard let self, self.currentVideo.id == video.id else { return }
                self.isRestoringPosition = false
            }
        }
        showResumeNotice(seconds: resume)
    }

    /// 勝手に途中から始まったように見えないよう、再開位置を数秒だけ知らせる。
    private func showResumeNotice(seconds: Double) {
        withAnimation(.easeOut(duration: 0.2)) {
            resumeNotice = "\(Self.timeLabel(seconds)) から再開しました"
        }
        resumeNoticeTask?.cancel()
        resumeNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self?.resumeNotice = nil
            }
        }
    }

    /// いま観ている位置を保管庫へ書く。`force` でないと間引かれる。
    private func recordCurrentProgress(force: Bool) {
        let seconds = currentTime
        guard seconds.isFinite, seconds > 0 else { return }
        watchState.recordProgress(
            videoID: currentVideo.id,
            seconds: seconds,
            duration: effectiveDuration,
            force: force
        )
    }

    /// VideoItem の duration は取り込み時の値。実ファイルから読めた尺があればそちらを優先する。
    private var effectiveDuration: TimeInterval {
        duration > defaultDuration ? duration : currentVideo.duration
    }

    static func timeLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// シャッフル中は「実際に再生した順」を遡るので、リストの並びは関係ない。
    var canPlayPreviousVideo: Bool {
        if settings.isShuffleEnabled { return !playedStack.isEmpty }
        guard let currentIndex = allVideos.firstIndex(of: currentVideo) else { return false }
        if allVideos.indices.contains(currentIndex - 1) { return true }
        // 「次へ」が末尾で先頭へ折り返すなら、「前へ」も先頭で末尾へ回れないと辻褄が合わない。
        return settings.repeatMode == .all && allVideos.count > 1
    }

    /// 自動再生が次に進めるかどうかと同じ判断を使う。
    /// ここだけ配列の index で見ていたころは、リストの末尾で
    /// 「ボタンは押せないのに数秒後に勝手に先頭へ戻る」というズレが出ていた。
    var canPlayNextVideo: Bool { hasNextVideo }

    private func configurePlaybackMonitoring(for player: AVPlayer) {
        if let observer = playerTimeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(observer)
        }
        playerTimeObserver = nil
        observedPlayer = player
        cancellables.removeAll()
        currentTime = 0
        duration = defaultDuration
        isPlaybackPlaying = player.rate != 0

        player.publisher(for: \.currentItem?.duration)
            .compactMap { $0?.seconds }
            .filter { $0.isFinite && $0 > 0 }
            .sink { [weak self] seconds in
                Task { @MainActor [weak self] in
                    self?.duration = seconds
                }
            }
            .store(in: &cancellables)

        player.publisher(for: \.rate)
            .sink { [weak self] rate in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isPlaybackPlaying = rate != 0
                    // play() 直後もここを通る。通さないとコントロールセンターが
                    // 「一時停止中」の表示のまま取り残される。
                    self.refreshNowPlaying()
                }
            }
            .store(in: &cancellables)

        // 終端の通知は object を絞らずに受け、いま鳴っている item かどうかで判定する。
        // replaceCurrentItem で item が入れ替わるため、購読し直すより取りこぼしが少ない。
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .compactMap { $0.object as? AVPlayerItem }
            .sink { [weak self] endedItem in
                Task { @MainActor [weak self] in
                    guard let self, endedItem === self.player?.currentItem else { return }
                    self.handlePlaybackEnded()
                }
            }
            .store(in: &cancellables)

        playerTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: playerTimeObserverInterval, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isSliderEditing, !self.isRestoringPosition,
                      !self.isRestartingLoop,
                      time.seconds.isFinite else { return }
                self.currentTime = min(max(time.seconds, 0), self.duration)
                // 保管庫側で間引くので、ここは毎回呼んでよい。
                self.recordCurrentProgress(force: false)
            }
        }
    }

    func seek(toSeconds seconds: Double) {
        guard let player = player else { return }
        // 自分でシークしたなら、もう再開位置へ戻す途中ではない。
        isRestoringPosition = false
        isRestartingLoop = false
        let effectiveDuration = player.currentItem?.duration.seconds ?? duration
        let upperBound = effectiveDuration.isFinite && effectiveDuration > 0 ? effectiveDuration : duration
        let clampedSeconds = min(max(seconds, 0), max(upperBound, 0))
        let targetTime = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        currentTime = clampedSeconds
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        refreshNowPlaying()
    }

    private func playerItem(for video: VideoItem) -> AVPlayerItem? {
        guard let url = dataManager.fileURL(for: video) else { return nil }
        let asset = cachedAsset(for: video, url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1
        return item
    }

    private func cachedAsset(for video: VideoItem, url: URL) -> AVURLAsset {
        if let cached = assetCache[video.id] { return cached }
        let asset = AVURLAsset(url: url)
        assetCache[video.id] = asset
        return asset
    }

    private func preloadNearbyAssets(around video: VideoItem) {
        guard let currentIndex = allVideos.firstIndex(of: video) else { return }
        let lowerBound = max(0, currentIndex - adjacentPreloadRadius)
        let upperBound = min(allVideos.count - 1, currentIndex + adjacentPreloadRadius)
        guard lowerBound <= upperBound else { return }

        let nearbyVideos = Array(allVideos[lowerBound...upperBound])
        let keepIDs = Set(nearbyVideos.map(\.id))

        for (id, task) in preloadTasks where !keepIDs.contains(id) {
            task.cancel()
            preloadTasks[id] = nil
        }
        assetCache = assetCache.filter { keepIDs.contains($0.key) }

        for item in nearbyVideos {
            preloadAsset(for: item)
        }
    }

    private func preloadAsset(for video: VideoItem) {
        guard preloadTasks[video.id] == nil,
              let url = dataManager.fileURL(for: video) else { return }

        let asset = cachedAsset(for: video, url: url)
        preloadTasks[video.id] = Task {
            _ = try? await asset.load(.isPlayable)
            if Task.isCancelled { return }
            _ = try? await asset.load(.duration)
            if Task.isCancelled { return }
            preloadTasks[video.id] = nil
        }
    }

    /// 「次へ」。自動再生と同じ選び方をする（シャッフル中は袋から、末尾では
    /// リピート設定に従って折り返す）。ボタンの活性も同じ判断なので食い違わない。
    func playNextVideo() {
        guard let next = nextVideoForAutoPlay() else { return }
        // 1本しか無いリストで「リストをリピート」のときだけ、次＝自分自身になる。
        // 自動再生の終端処理と同じく頭から流し直す。ここで黙って return すると
        // 「ボタンは押せるのに何も起きない」になり、`hasNextVideo` との約束が破れる。
        guard next.id != currentVideo.id else {
            restartCurrentVideoSmoothly()
            return
        }
        changeVideo(to: next)
    }

    /// 「前へ」。シャッフル中はリストの並びを遡っても意味がないので、
    /// 実際に再生した順を1つ戻る。
    func playPreviousVideo() {
        if settings.isShuffleEnabled {
            // 履歴はまだ減らさない（`last` で覗くだけ）。先に減らしてから差し替えに失敗すると、
            // 何も起きていないのに1つ分の履歴が消え、次の ← が2本ぶん飛んでしまう。
            guard let previousID = playedStack.last,
                  let previous = allVideos.first(where: { $0.id == previousID }) else { return }
            // いま観ていた1本は「まだ流していない」側へ戻す。戻さないと、← を押した時点で
            // その動画が今回の一巡から抜け落ちる（袋にも履歴にも居なくなる）。
            // 次に取り出される位置へ入れるので、→ を押せばそのまま元へ戻れる。
            let leavingID = currentVideo.id
            shuffleBag.removeAll { $0 == leavingID }
            shuffleBag.append(leavingID)
            guard changeVideo(to: previous, recordsPlayedStack: false) else {
                // 読めないファイルだった。袋を触る前に戻す
                // （戻さないと「いま流している動画が袋に入っている」状態になり、
                //   → が押せるのに何も起きなくなる）。
                shuffleBag.removeAll { $0 == leavingID }
                return
            }
            playedStack.removeLast()
            return
        }
        guard let currentIndex = allVideos.firstIndex(of: currentVideo) else { return }
        let previousIndex = currentIndex - 1
        if allVideos.indices.contains(previousIndex) {
            changeVideo(to: allVideos[previousIndex])
        } else if settings.repeatMode == .all, let last = allVideos.last, last.id != currentVideo.id {
            changeVideo(to: last)
        }
    }

    func playVideo(_ video: VideoItem) {
        guard video.id != currentVideo.id, allVideos.contains(video) else { return }
        changeVideo(to: video)
    }

    /// シークバーのホバープレビュー用。いま鳴っている素材。
    var currentAsset: AVAsset? { player?.currentItem?.asset }

    var otherVideos: [VideoItem] {
        allVideos.filter { $0.id != currentVideo.id }
    }
}
