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
    private var chapterGenerationTask: Task<Void, Never>?
    private var playerTimeObserver: Any?
    private weak var observedPlayer: AVPlayer?
    private var cancellables = Set<AnyCancellable>()
    private var preloadTasks: [UUID: Task<Void, Never>] = [:]
    private var assetCache: [UUID: AVURLAsset] = [:]
    private var isSliderEditing = false
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

    init(videos: [VideoItem], currentVideo: VideoItem, dataManager: LibraryViewModel) {
        self.allVideos = videos
        self.currentVideo = currentVideo
        self.dataManager = dataManager
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
            self.player = newPlayer
            self.configurePlaybackMonitoring(for: newPlayer)
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
        } else {
            player.pause()
            isPlaybackPlaying = false
        }
    }

    func playbackSliderEditingChanged(isEditing: Bool) {
        isSliderEditing = isEditing
        guard !isEditing else { return }
        seek(toSeconds: currentTime)
    }

    private func changeVideo(to newVideo: VideoItem) {
        guard let newItem = playerItem(for: newVideo) else { return }
        self.currentVideo = newVideo
        self.currentTime = 0
        self.duration = defaultDuration
        self.isSliderEditing = false
        self.player?.replaceCurrentItem(with: newItem)
        self.player?.play()
        preloadNearbyAssets(around: newVideo)
        generateChapterPoints()
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
                    self?.isPlaybackPlaying = rate != 0
                }
            }
            .store(in: &cancellables)

        playerTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: playerTimeObserverInterval, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isSliderEditing, time.seconds.isFinite else { return }
                self.currentTime = min(max(time.seconds, 0), self.duration)
            }
        }
    }

    private func seek(toSeconds seconds: Double) {
        guard let player = player else { return }
        let effectiveDuration = player.currentItem?.duration.seconds ?? duration
        let upperBound = effectiveDuration.isFinite && effectiveDuration > 0 ? effectiveDuration : duration
        let clampedSeconds = min(max(seconds, 0), max(upperBound, 0))
        let targetTime = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        currentTime = clampedSeconds
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
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

    var otherVideos: [VideoItem] {
        allVideos.filter { $0.id != currentVideo.id }
    }
}
