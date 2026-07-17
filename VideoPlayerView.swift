import Foundation
import SwiftUI
import AVKit
import Combine
import AppKit

// MARK: - Single playback (3-A)
// 通常再生モード: 自動チャプターサイドバー / 充実したシーク操作 / 前後の動画へ移動。
// データモデルはサーバーアプリの VideoItem + VideoDataManager.fileURL(for:) に合わせて移植している。

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
    private let dataManager: VideoDataManager
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

private struct PlaybackVideoStrip: View {
    let videos: [VideoItem]
    let dataManager: VideoDataManager
    let onSelect: (VideoItem) -> Void
    let onClose: () -> Void

    private let thumbnailWidth: CGFloat = 220
    private let thumbnailHeight: CGFloat = 124

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("他の動画")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.78))
                .help("動画一覧を閉じる")
                .accessibilityLabel("動画一覧を閉じる")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(videos) { video in
                        PlaybackVideoThumbnailButton(
                            video: video,
                            thumbnailURL: thumbnailURL(for: video),
                            width: thumbnailWidth,
                            height: thumbnailHeight
                        ) {
                            onSelect(video)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 30)
    }

    private func thumbnailURL(for video: VideoItem) -> URL {
        dataManager.thumbnailStorageURL
            .appendingPathComponent(video.id.uuidString)
            .appendingPathExtension("jpg")
    }
}

private struct PlaybackVideoThumbnailButton: View {
    let video: VideoItem
    let thumbnailURL: URL
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                thumbnailImage

                LinearGradient(
                    colors: [.clear, .black.opacity(0.68)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                Text(displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            )
            .opacity(0.84)
        }
        .buttonStyle(.plain)
        .help(displayName)
        .task(id: video.id) {
            await loadThumbnail()
        }
    }

    private var thumbnailImage: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.black.opacity(0.35))
                    Image(systemName: "film")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.48))
                }
            }
        }
    }

    private var displayName: String {
        (video.originalFilename as NSString).deletingPathExtension
    }

    private func loadThumbnail() async {
        let url = thumbnailURL
        let loadedThumbnail: NSImage? = await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value
        guard let loadedThumbnail else { return }
        thumbnail = loadedThumbnail
    }
}

private struct ScrollWheelDetector: NSViewRepresentable {
    let onVerticalScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelDetectorView {
        let view = ScrollWheelDetectorView()
        view.onVerticalScroll = onVerticalScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelDetectorView, context: Context) {
        nsView.onVerticalScroll = onVerticalScroll
    }
}

private final class ScrollWheelDetectorView: NSView {
    var onVerticalScroll: ((CGFloat) -> Void)?
    private var eventMonitor: Any?

    deinit {
        removeEventMonitor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeEventMonitor()
        } else {
            installEventMonitor()
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window else { return event }

            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }

            self.onVerticalScroll?(event.scrollingDeltaY)
            return event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

struct VideoPlayerView: View {
    @StateObject private var viewModel: VideoPlayerViewModel
    private let dataManager: VideoDataManager
    @EnvironmentObject private var coordinator: PlaybackCoordinator

    @FocusState private var isViewFocused: Bool
    @State private var isSidebarVisible = false
    @State private var isVideoStripVisible = false
    @State private var showShortcutHelp = false
    @State private var areCornerControlsVisible = false
    @State private var cornerControlsActivityID = UUID()
    @AppStorage(MediaShortcutSettings.versionKey) private var shortcutSettingsVersion = 0
    private let sidebarWidth: CGFloat = 240
    private let triggerWidth: CGFloat = 10
    private let cornerControlsAutoHideNanoseconds: UInt64 = 2_500_000_000
    private let playbackControlsMaxWidth: CGFloat = 780
    private let playbackControlsHorizontalPadding: CGFloat = 28
    private let playbackControlsBottomPadding: CGFloat = 24
    private let playbackControlButtonWidth: CGFloat = 26
    private let minimumSliderDuration: Double = 0.1
    private let videoStripScrollThreshold: CGFloat = 2
    private let secondsPerMinute = 60
    private let secondsPerHour = 3_600

    init(videos: [VideoItem], currentVideo: VideoItem, dataManager: VideoDataManager) {
        self.dataManager = dataManager
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
                ("画面左端にマウス", "10分割サムネイルを表示"),
                ("下スクロール", "他の動画を表示"),
                ("Esc", "プレイヤーを閉じる")
            ]
        )
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ZStack {
                Color.black
                // AVKit標準コントロールは表示時に動画全体を暗くするため使わず、
                // 下部に独自のシークバーを重ねる。
                PlayerContainerView(
                    player: viewModel.player,
                    controlsStyle: .none,
                    showsFullScreenToggleButton: false,
                    allowsPictureInPicturePlayback: false
                )
            }
            sidebar

            ScrollWheelDetector { deltaY in
                handlePlaybackScroll(deltaY: deltaY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            if areCornerControlsVisible || showShortcutHelp || isVideoStripVisible {
                VStack(spacing: 10) {
                    Spacer()
                    if isVideoStripVisible {
                        videoSelectionStrip
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if areCornerControlsVisible || showShortcutHelp {
                        playbackControls
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // シークバーと同じく，カーソル操作中だけ左上の補助操作を表示する。
            if areCornerControlsVisible || showShortcutHelp {
                VStack {
                    HStack {
                        Spacer()
                        PlayerCornerControls(showShortcutHelp: $showShortcutHelp) {
                            coordinator.close()
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
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
            areCornerControlsVisible = false
            isVideoStripVisible = false
            viewModel.setupPlayer()
        }
        .onDisappear { viewModel.cleanup() }
        .onContinuousHover { phase in
            if case .active = phase {
                revealCornerControls()
            }
        }
        .task(id: cornerControlsActivityID) {
            try? await Task.sleep(nanoseconds: cornerControlsAutoHideNanoseconds)
            guard !Task.isCancelled, !showShortcutHelp else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                areCornerControlsVisible = false
            }
        }
        .onKeyPress(phases: .down, action: handleKeyPress)
    }

    /// カーソル移動が続くたびに自動非表示タイマーを更新する。
    private func revealCornerControls() {
        if !areCornerControlsVisible {
            withAnimation(.easeOut(duration: 0.16)) {
                areCornerControlsVisible = true
            }
        }
        cornerControlsActivityID = UUID()
    }

    private func handlePlaybackScroll(deltaY: CGFloat) {
        guard abs(deltaY) >= videoStripScrollThreshold else { return }
        revealCornerControls()
        guard !viewModel.otherVideos.isEmpty else { return }
        if !isVideoStripVisible {
            withAnimation(.easeOut(duration: 0.18)) {
                isVideoStripVisible = true
            }
        }
    }

    /// AVKit標準の暗転を避けるための通常再生用コントロール。
    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.playPreviousVideo()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 15))
                    .frame(width: playbackControlButtonWidth)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canPlayPreviousVideo)
            .help("前の動画")
            .accessibilityLabel("前の動画")

            Button {
                viewModel.playPause()
            } label: {
                Image(systemName: viewModel.isPlaybackPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .frame(width: playbackControlButtonWidth)
            }
            .buttonStyle(.plain)
            .help(viewModel.isPlaybackPlaying ? "一時停止（Space）" : "再生（Space）")
            .accessibilityLabel(viewModel.isPlaybackPlaying ? "一時停止" : "再生")

            Button {
                viewModel.playNextVideo()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 15))
                    .frame(width: playbackControlButtonWidth)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canPlayNextVideo)
            .help("次の動画")
            .accessibilityLabel("次の動画")

            Text(formatTime(viewModel.currentTime))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 46, alignment: .trailing)

            Slider(
                value: $viewModel.currentTime,
                in: 0...max(viewModel.duration, minimumSliderDuration)
            ) { isEditing in
                viewModel.playbackSliderEditingChanged(isEditing: isEditing)
            }

            Text(formatTime(viewModel.duration))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 46, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: playbackControlsMaxWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, playbackControlsHorizontalPadding)
        .padding(.bottom, playbackControlsBottomPadding)
    }

    private var videoSelectionStrip: some View {
        PlaybackVideoStrip(
            videos: viewModel.otherVideos,
            dataManager: dataManager
        ) { video in
            viewModel.playVideo(video)
            withAnimation(.easeOut(duration: 0.16)) {
                isVideoStripVisible = false
            }
        } onClose: {
            withAnimation(.easeOut(duration: 0.16)) {
                isVideoStripVisible = false
            }
        }
        .padding(.bottom, areCornerControlsVisible || showShortcutHelp ? 0 : playbackControlsBottomPadding)
    }

    /// 10分割サムネイルを表示するサイドバー（左端ホバーで展開）
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
            .offset(x: isSidebarVisible ? 0 : -sidebarWidth + triggerWidth)
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

    private func formatTime(_ time: Double) -> String {
        let totalSeconds = Int(time)
        guard totalSeconds >= 0 else { return "0:00" }
        if totalSeconds >= secondsPerHour {
            return String(
                format: "%d:%02d:%02d",
                totalSeconds / secondsPerHour,
                (totalSeconds % secondsPerHour) / secondsPerMinute,
                totalSeconds % secondsPerMinute
            )
        }
        return String(format: "%d:%02d", totalSeconds / secondsPerMinute, totalSeconds % secondsPerMinute)
    }
}
