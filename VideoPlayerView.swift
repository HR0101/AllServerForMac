import Foundation
import SwiftUI
import AVKit
import Combine

// MARK: - Single playback (3-A)
// 通常再生モード: 自動チャプターサイドバー / 充実したシーク操作 / 前後の動画へ移動。
// データモデルはサーバーアプリの VideoItem + VideoDataManager.fileURL(for:) に合わせて移植している。

@MainActor
final class VideoPlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var chapterPoints: [ChapterPoint] = []
    @Published var currentVideo: VideoItem

    /// 前後移動の対象となる動画リスト（動画のみ）
    let allVideos: [VideoItem]
    private let dataManager: VideoDataManager
    private var chapterGenerationTask: Task<Void, Never>?
    private var preloadTasks: [UUID: Task<Void, Never>] = [:]
    private var assetCache: [UUID: AVURLAsset] = [:]
    private let adjacentPreloadRadius = 4
    private let chapterGenerationDelayNanoseconds: UInt64 = 280_000_000

    init(videos: [VideoItem], currentVideo: VideoItem, dataManager: VideoDataManager) {
        self.allVideos = videos
        self.currentVideo = currentVideo
        self.dataManager = dataManager
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
            self.player = newPlayer
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

            for i in 1...9 {
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
        preloadTasks.values.forEach { $0.cancel() }
        preloadTasks.removeAll()
        assetCache.removeAll()
        player?.pause()
        player = nil
    }

    func seek(by seconds: Double) {
        guard let player = player, let currentTime = player.currentItem?.currentTime() else { return }
        let newTime = CMTimeGetSeconds(currentTime) + seconds
        let seekTime = CMTime(seconds: newTime, preferredTimescale: .max)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(toPercentage percentage: Double) {
        guard let player = player, let duration = player.currentItem?.duration, duration.seconds > 0 else { return }
        let targetSeconds = duration.seconds * percentage
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekToRandomTime() {
        guard let player = player, let duration = player.currentItem?.duration, duration.seconds > 0 else { return }
        let randomSeconds = Double.random(in: 0..<duration.seconds)
        let randomTime = CMTime(seconds: randomSeconds, preferredTimescale: 600)
        player.seek(to: randomTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func playPause() {
        guard let player = player else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
    }

    private func changeVideo(to newVideo: VideoItem) {
        guard let newItem = playerItem(for: newVideo) else { return }
        self.currentVideo = newVideo
        self.player?.replaceCurrentItem(with: newItem)
        self.player?.play()
        preloadNearbyAssets(around: newVideo)
        generateChapterPoints()
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
}

/// サイドバーの各チャプター行
private struct ChapterRow: View {
    let chapter: ChapterPoint
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                (chapter.thumbnail ?? Image(systemName: "film"))
                    .resizable()
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .cornerRadius(4)
                Text(chapter.timeString)
                    .font(.caption.monospacedDigit())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct VideoPlayerView: View {
    @StateObject private var viewModel: VideoPlayerViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator

    @FocusState private var isViewFocused: Bool
    @State private var isSidebarVisible = false
    @State private var showShortcutHelp = false
    @AppStorage(MediaShortcutSettings.versionKey) private var shortcutSettingsVersion = 0
    private let sidebarWidth: CGFloat = 240
    private let triggerWidth: CGFloat = 10

    init(videos: [VideoItem], currentVideo: VideoItem, dataManager: VideoDataManager) {
        _viewModel = StateObject(wrappedValue: VideoPlayerViewModel(videos: videos, currentVideo: currentVideo, dataManager: dataManager))
    }

    private var shortcutList: [(key: String, action: String)] {
        _ = shortcutSettingsVersion
        return MediaShortcutSettings.shortcutList(
            for: [
                .videoPlayPause,
                .videoPreviousItem,
                .videoNextItem,
                .videoSeekBack15,
                .videoSeekBack10,
                .videoSeekBack5,
                .videoSeekForward5,
                .videoSeekForward10,
                .videoSeekForward15,
                .videoRandomSeek
            ],
            extraItems: [
                ("0〜9", "動画の 0%〜90% の位置へジャンプ"),
                ("?", "ショートカット一覧を表示"),
                ("画面右端にマウス", "チャプター一覧を表示"),
                ("Esc", "プレイヤーを閉じる")
            ]
        )
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            ZStack {
                Color.black
                // 左上にはアプリ独自の「ヘルプ／閉じる」操作を配置しているため、
                // AVKit標準のPiP／フルスクリーン操作を非表示にして重なりを防ぐ。
                // 再生・シークなどのインラインコントロールはそのまま使用する。
                PlayerContainerView(
                    player: viewModel.player,
                    showsFullScreenToggleButton: false,
                    allowsPictureInPicturePlayback: false
                )
            }
            sidebar

            // サイドバーは右端ホバーで出るため、ボタンは左上に置いて干渉を避ける
            VStack {
                HStack {
                    PlayerCornerControls(showShortcutHelp: $showShortcutHelp) {
                        coordinator.close()
                    }
                    Spacer()
                }
                Spacer()
            }

            if showShortcutHelp {
                ShortcutHelpPanel(title: "通常再生のショートカット", shortcuts: shortcutList) {
                    showShortcutHelp = false
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .focusable()
        .focused($isViewFocused)
        .onAppear {
            isViewFocused = true
            viewModel.setupPlayer()
        }
        .onDisappear { viewModel.cleanup() }
        .onKeyPress(phases: .down, action: handleKeyPress)
    }

    /// チャプターサムネイルを表示するサイドバー（右端ホバーで展開）
    private var sidebar: some View {
        ZStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.chapterPoints) { chapter in
                        ChapterRow(chapter: chapter) {
                            viewModel.seek(toPercentage: chapter.percentage)
                        }
                    }
                }
                .padding(8)
            }
            .frame(width: sidebarWidth)
            .background(.regularMaterial)
            .offset(x: isSidebarVisible ? 0 : sidebarWidth)
        }
        .frame(width: isSidebarVisible ? sidebarWidth : triggerWidth)
        .contentShape(Rectangle())
        .onHover { hovering in
            if isSidebarVisible != hovering {
                withAnimation(.easeInOut(duration: 0.2)) { isSidebarVisible = hovering }
            }
        }
    }

    private func handleKeyPress(press: KeyPress) -> KeyPress.Result {
        if let digit = press.key.character.wholeNumberValue {
            viewModel.seek(toPercentage: Double(digit) / 10.0)
            return .handled
        }

        switch press.key {
        case .escape:
            if showShortcutHelp { showShortcutHelp = false } else { coordinator.close() }
            return .handled
        case "?":
            showShortcutHelp.toggle()
            return .handled
        case .space:
            if press.modifiers.contains(.option) {
                coordinator.close()
                return .handled
            }
            break
        default:
            break
        }

        if MediaShortcutSettings.matches(.videoPlayPause, press: press) {
            viewModel.playPause()
            return .handled
        } else if MediaShortcutSettings.matches(.videoPreviousItem, press: press) {
            viewModel.playPreviousVideo()
            return .handled
        } else if MediaShortcutSettings.matches(.videoNextItem, press: press) {
            viewModel.playNextVideo()
            return .handled
        } else if MediaShortcutSettings.matches(.videoRandomSeek, press: press) {
            viewModel.seekToRandomTime()
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekBack15, press: press) {
            viewModel.seek(by: -15)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekBack10, press: press) {
            viewModel.seek(by: -10)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekBack5, press: press) {
            viewModel.seek(by: -5)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekForward5, press: press) {
            viewModel.seek(by: 5)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekForward10, press: press) {
            viewModel.seek(by: 10)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekForward15, press: press) {
            viewModel.seek(by: 15)
            return .handled
        }

        return .ignored
    }
}
