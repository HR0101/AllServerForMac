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
    private let adjacentPreloadRadius = 4
    private let chapterGenerationDelayNanoseconds: UInt64 = 280_000_000
    private let playerTimeObserverInterval: TimeInterval = 0.25
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

    static let volumeDefaultsKey = "player.volume"
    static let mutedDefaultsKey = "player.muted"

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
            // didSet は init 中に走らないので、プレイヤー生成時に現在値を当て直す。
            newPlayer.volume = self.volume
            newPlayer.isMuted = self.isMuted
            // play() が使う速度。rate に直接入れると一時停止中でも再生が始まってしまう。
            newPlayer.defaultRate = Float(self.settings.rate)
            self.player = newPlayer
            self.configurePlaybackMonitoring(for: newPlayer)
            self.startWatching(self.currentVideo, on: newPlayer)
            self.activateNowPlaying()
            newPlayer.play()
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
        if let observer = playerTimeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(observer)
        }
        playerTimeObserver = nil
        observedPlayer = nil
        cancellables.removeAll()
        preloadTasks.values.forEach { $0.cancel() }
        preloadTasks.removeAll()
        assetCache.removeAll()
        player?.pause()
        player = nil
        currentTime = 0
        duration = defaultDuration
        isPlaybackPlaying = false
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
        guard let player, player.rate != 0 else { return }
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

    private func changeVideo(to newVideo: VideoItem) {
        guard let newItem = playerItem(for: newVideo) else { return }
        // 切り替える前に、いま観ていた動画の位置を確定させる。
        commitProgress()
        self.currentVideo = newVideo
        self.currentTime = 0
        self.duration = defaultDuration
        self.isSliderEditing = false
        self.player?.replaceCurrentItem(with: newItem)
        if let player { startWatching(newVideo, on: player) }
        self.player?.play()
        preloadNearbyAssets(around: newVideo)
        generateChapterPoints()
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
            seek(toSeconds: 0)
            player?.play()
            return
        }

        guard settings.autoPlayNext, let next = nextVideoForAutoPlay() else {
            isPlaybackPlaying = false
            return
        }
        changeVideo(to: next)
    }

    /// 自動再生で次に流す動画。無ければ nil（＝その場で止まる）。
    private func nextVideoForAutoPlay() -> VideoItem? {
        guard allVideos.count > 1 else {
            return settings.repeatMode == .all ? currentVideo : nil
        }
        if settings.isShuffleEnabled {
            return allVideos.filter { $0.id != currentVideo.id }.randomElement()
        }
        guard let index = allVideos.firstIndex(of: currentVideo) else { return allVideos.first }
        let nextIndex = index + 1
        if allVideos.indices.contains(nextIndex) { return allVideos[nextIndex] }
        return settings.repeatMode == .all ? allVideos.first : nil
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
        refreshNowPlaying()

        guard let resume = watchState.resumeSeconds(for: video.id, duration: video.duration) else {
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

    var canPlayPreviousVideo: Bool {
        guard let currentIndex = allVideos.firstIndex(of: currentVideo) else { return false }
        return allVideos.indices.contains(currentIndex - 1)
    }

    var canPlayNextVideo: Bool {
        guard let currentIndex = allVideos.firstIndex(of: currentVideo) else { return false }
        return allVideos.indices.contains(currentIndex + 1)
    }

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

    func playNextVideo() {
        guard let currentIndex = allVideos.firstIndex(of: currentVideo) else { return }
        let nextIndex = currentIndex + 1
        if allVideos.indices.contains(nextIndex) { changeVideo(to: allVideos[nextIndex]) }
    }

    func playPreviousVideo() {
        guard let currentIndex = allVideos.firstIndex(of: currentVideo) else { return }
        let previousIndex = currentIndex - 1
        if allVideos.indices.contains(previousIndex) { changeVideo(to: allVideos[previousIndex]) }
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
