import Foundation
import SwiftUI
import AVKit
import Combine
import AppKit

// MARK: - Single playback (3-A)
// 通常再生モード: 自動チャプターサイドバー / 充実したシーク操作 / 前後の動画へ移動。
// データモデルはサーバーアプリの VideoItem + LibraryViewModel.fileURL(for:) に合わせて移植している。

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
    let dataManager: LibraryViewModel
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

/// 関連動画パネルの1行（YouTubeの「次の動画」リストと同じ、サムネイル＋タイトルの横並び）。
private struct UpNextVideoRow: View {
    let video: VideoItem
    let thumbnailURL: URL
    let action: () -> Void

    @State private var thumbnail: NSImage?

    private let thumbnailWidth: CGFloat = 158
    private let thumbnailHeight: CGFloat = 89

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    thumbnailImage
                        .frame(width: thumbnailWidth, height: thumbnailHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Text(durationString)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(4)
                }

                Text(displayName)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 2)

                Spacer(minLength: 0)
            }
            .padding(6)
            .contentShape(Rectangle())
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
                    Rectangle().fill(.white.opacity(0.08))
                    Image(systemName: "film")
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }

    private var displayName: String {
        (video.originalFilename as NSString).deletingPathExtension
    }

    private var durationString: String {
        let totalSeconds = Int(video.duration)
        guard totalSeconds >= 0 else { return "0:00" }
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
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

/// 数字キー(0〜9)による位置ジャンプ用の検出ビュー。
/// SwiftUIの.onKeyPressは再生ボタンなどをクリックした後にフォーカスがそちらへ移ると
/// 反応しなくなるため、ScrollWheelDetectorと同じくウィンドウレベルのイベント監視で拾う。
private struct DigitSeekDetector: NSViewRepresentable {
    let onDigit: (Int) -> Void

    func makeNSView(context: Context) -> DigitSeekDetectorView {
        let view = DigitSeekDetectorView()
        view.onDigit = onDigit
        return view
    }

    func updateNSView(_ nsView: DigitSeekDetectorView, context: Context) {
        nsView.onDigit = onDigit
    }
}

private final class DigitSeekDetectorView: NSView {
    var onDigit: ((Int) -> Void)?
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
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window else { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            guard let characters = event.charactersIgnoringModifiers,
                  characters.count == 1,
                  let digit = characters.first?.wholeNumberValue else { return event }

            self.onDigit?(digit)
            return nil
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
    private let dataManager: LibraryViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var remotePlaybackSession: RemotePlaybackSession

    @FocusState private var isViewFocused: Bool
    @State private var isSidebarVisible = false
    @State private var isVideoStripVisible = false
    @State private var showShortcutHelp = false
    @State private var areCornerControlsVisible = false
    @State private var cornerControlsActivityID = UUID()
    @State private var isUpNextPanelVisible = false
    @State private var isMiniControlsVisible = false
    // マウスドラッグで範囲選択してその領域へズームする状態。
    @State private var videoZoom = MarqueeZoomState()
    @State private var videoMarqueeStart: CGPoint?
    @State private var videoMarqueeCurrent: CGPoint?
    @AppStorage(MediaShortcutSettings.versionKey) private var shortcutSettingsVersion = 0
    /// 自動再生・リピート・シャッフル・再生速度。ViewModel が持つのと同じ実体。
    @ObservedObject private var settings: PlaybackSettings
    /// 他アプリの上に浮かぶ小窓（ミニプレイヤーとは別物）。
    @StateObject private var pictureInPicture = PictureInPictureCoordinator()
    /// シークバーをなぞっている位置のプレビュー。
    @StateObject private var scrubPreview = ScrubPreviewGenerator()
    /// なぞっている位置（0...1）。なぞっていなければ nil。
    @State private var scrubHoverFraction: Double?
    @State private var seekBarWidth: CGFloat = 0
    private let sidebarWidth: CGFloat = 240
    private let triggerWidth: CGFloat = 10
    private let upNextPanelWidth: CGFloat = 360
    private let miniPlayerWidth: CGFloat = 300
    private let miniPlayerHeight: CGFloat = 169
    private let cornerControlsAutoHideNanoseconds: UInt64 = 2_500_000_000
    private let playbackControlsMaxWidth: CGFloat = 780
    private let playbackControlsHorizontalPadding: CGFloat = 28
    private let playbackControlsBottomPadding: CGFloat = 24
    private let playbackControlButtonWidth: CGFloat = 26
    private let minimumSliderDuration: Double = 0.1
    private let videoStripScrollThreshold: CGFloat = 2
    private let secondsPerMinute = 60
    private let secondsPerHour = 3_600
    private let scrubPreviewWidth: CGFloat = 168
    private let scrubPreviewHeight: CGFloat = 95
    /// 札の総高さ（画像＋時刻＋余白）＋シークバーとの間隔。
    private let scrubPreviewTotalHeight: CGFloat = 138

    init(
        videos: [VideoItem],
        currentVideo: VideoItem,
        dataManager: LibraryViewModel,
        watchState: WatchStateStore,
        settings: PlaybackSettings
    ) {
        self.dataManager = dataManager
        _settings = ObservedObject(wrappedValue: settings)
        _viewModel = StateObject(
            wrappedValue: VideoPlayerViewModel(
                videos: videos,
                currentVideo: currentVideo,
                dataManager: dataManager,
                watchState: watchState,
                settings: settings
            )
        )
    }

    private var shortcutList: [(key: String, action: String)] {
        _ = shortcutSettingsVersion
        return MediaShortcutSettings.shortcutList(
            for: [
                .videoClose,
                .videoPlayPause,
                .videoPreviousItem,
                .videoNextItem,
                .videoSeekBack15,
                .videoSeekBack10,
                .videoSeekBack5,
                .videoSeekForward5,
                .videoSeekForward10,
                .videoSeekForward15,
                .videoRandomSeek,
                .videoToggleUpNextPanel,
                .videoToggleMiniPlayer,
                .videoToggleShuffle,
                .videoCycleRepeat,
                .videoRateDown,
                .videoRateUp,
                .videoTogglePictureInPicture
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
        Group {
            if coordinator.isMiniPlayerActive {
                miniPlayerView
            } else {
                fullPlayerView
            }
        }
        .onAppear {
            isViewFocused = true
            areCornerControlsVisible = false
            isVideoStripVisible = false
            isUpNextPanelVisible = false
            remotePlaybackSession.attach(viewModel)
            viewModel.setupPlayer()
        }
        // setupPlayer は次のループでプレイヤーを作るので、素材はそれを待ってから掴む。
        .onChange(of: viewModel.player == nil) { _, isMissing in
            guard !isMissing else { return }
            scrubPreview.prepare(asset: viewModel.currentAsset, videoID: viewModel.currentVideo.id)
        }
        .onChange(of: viewModel.currentVideo.id) { _, _ in
            videoZoom.reset()
            scrubHoverFraction = nil
            scrubPreview.prepare(asset: viewModel.currentAsset, videoID: viewModel.currentVideo.id)
        }
        // 一時停止したまま離席したときに画面が点きっぱなしにならないよう、
        // 実際の再生状態をコーディネーター（スリープ抑止の持ち主）へ伝える。
        .onChange(of: viewModel.isPlaybackPlaying) { _, isPlaying in
            coordinator.setPlaybackActive(isPlaying)
        }
        .onDisappear {
            remotePlaybackSession.detach(viewModel)
            // 小窓だけ残すと、止める手立てのない再生が居座る。
            pictureInPicture.detach()
            viewModel.cleanup()
        }
    }

    /// 通常のフルサイズ再生画面。
    private var fullPlayerView: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                videoPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isUpNextPanelVisible {
                    upNextPanel
                        .frame(width: upNextPanelWidth, alignment: .top)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            // シークバーと同じく，カーソル操作中だけ右上の補助操作を表示する。
            // パネルの開閉に関わらず常にウィンドウ右上端に留める。
            if areCornerControlsVisible || showShortcutHelp {
                PlayerCornerControls(
                    showShortcutHelp: $showShortcutHelp,
                    volume: $viewModel.volume,
                    isMuted: $viewModel.isMuted
                ) {
                    coordinator.close()
                }
                .transition(.opacity)
            }

            if let notice = viewModel.resumeNotice {
                resumeNoticeBadge(notice)
            }

            if showShortcutHelp {
                ShortcutHelpPanel(title: "通常再生のショートカット", shortcuts: shortcutList) {
                    showShortcutHelp = false
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($isViewFocused)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                revealCornerControls()
            case .ended:
                hideCornerControls()
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

    /// Iキーで切り替える、右下に小さく表示するミニプレイヤー。
    /// アルバム一覧側を操作できるよう、キーボードフォーカスは奪わない。
    private var miniPlayerView: some View {
        ZStack(alignment: .bottom) {
            Color.black
            PlayerLayerContainerView(player: viewModel.player)

            if isMiniControlsVisible {
                HStack(spacing: 8) {
                    Button {
                        viewModel.playPause()
                    } label: {
                        Image(systemName: viewModel.isPlaybackPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .help(viewModel.isPlaybackPlaying ? "一時停止" : "再生")

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            coordinator.isMiniPlayerActive = false
                        }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .help("フルスクリーンに戻す")

                    Button {
                        coordinator.close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .help("閉じる")
                }
                .padding(8)
            }
        }
        .frame(width: miniPlayerWidth, height: miniPlayerHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isMiniControlsVisible = hovering }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.22)) {
                coordinator.isMiniPlayerActive = false
            }
        }
        .padding(20)
    }

    /// 動画本体・シークバー・チャプターサイドバーをまとめた左側のペイン。
    /// 関連動画パネルが開くとこのペインだけが幅を縮めて左に寄る。
    private var videoPane: some View {
        ZStack(alignment: .leading) {
            ZStack {
                Color.black
                // AVKit標準コントロールは表示時に動画全体を暗くするため使わず、
                // 下部に独自のシークバーを重ねる。
                PlayerLayerContainerView(player: viewModel.player) { layer in
                    pictureInPicture.attach(playerLayer: layer)
                }
                .scaleEffect(x: videoZoom.scaleX, y: videoZoom.scaleY, anchor: .topLeading)
                .offset(videoZoom.offset)

                // マウスドラッグで範囲選択→その領域へズーム。ズーム中のクリックでフィット表示へ戻す。
                // 独自コントロール（シークバー等）はこの ZStack の外側にあるため、当たり判定は奪わない。
                GeometryReader { geo in
                    ZStack {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                marqueeZoomGesture(start: $videoMarqueeStart, current: $videoMarqueeCurrent, containerSize: geo.size) { rect in
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        videoZoom.zoom(into: rect, containerSize: geo.size)
                                    }
                                }
                            )
                            .onTapGesture {
                                if videoZoom.isZoomed {
                                    withAnimation(.easeInOut(duration: 0.2)) { videoZoom.reset() }
                                }
                            }
                        if let s = videoMarqueeStart, let c = videoMarqueeCurrent {
                            MarqueeRectangleShape(start: s, current: c)
                        }
                    }
                }
            }
            // ここでは切り抜かない。動画本体（AVPlayerView）を直に囲むクリップは
            // 再生中フレームごとのオフスクリーン描画を招きやすく、ズーム範囲の切り抜きは
            // 外側の videoPane 側の .clipped() が同じ範囲で担ってくれる。
            sidebar

            ScrollWheelDetector { deltaY in
                handlePlaybackScroll(deltaY: deltaY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            // 再生・前後移動などのボタンをクリックするとSwiftUIのフォーカスがそちらへ移り、
            // .onKeyPress側の数字キー判定が届かなくなるため、ウィンドウレベルのイベント監視で拾う。
            DigitSeekDetector { digit in
                viewModel.seek(toPercentage: Double(digit) / 10.0)
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
        }
        .clipped()
    }

    /// 前回の続きから始まったことを数秒だけ知らせる札。
    /// 何も出さずに途中から再生すると、不具合と区別がつかない。
    private func resumeNoticeBadge(_ notice: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
            Text(notice)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    /// Tキーで開閉する、YouTubeの「次の動画」風の同じアルバムの動画一覧パネル。
    private var upNextPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("同じアルバムの動画")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 12)

            if viewModel.otherVideos.isEmpty {
                Spacer()
                Text("他に動画がありません")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.otherVideos) { video in
                            UpNextVideoRow(
                                video: video,
                                thumbnailURL: thumbnailURL(for: video)
                            ) {
                                viewModel.playVideo(video)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
        }
    }

    private func thumbnailURL(for video: VideoItem) -> URL {
        dataManager.thumbnailStorageURL
            .appendingPathComponent(video.id.uuidString)
            .appendingPathExtension("jpg")
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

    /// マウスカーソルがウィンドウ外（別スクリーンなど）へ出たら即座にシークバーを閉じる。
    private func hideCornerControls() {
        guard areCornerControlsVisible, !showShortcutHelp else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            areCornerControlsVisible = false
        }
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
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { seekBarWidth = $0 }
            .onContinuousHover(coordinateSpace: .local) { phase in
                handleSeekBarHover(phase)
            }
            .overlay(alignment: .topLeading) {
                if let fraction = scrubHoverFraction, seekBarWidth > 0 {
                    scrubPreviewCard
                        .offset(x: scrubPreviewOffsetX(for: fraction), y: -scrubPreviewTotalHeight)
                }
            }

            Text(formatTime(viewModel.duration))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 46, alignment: .leading)

            Divider().frame(height: 18)

            Button {
                settings.isShuffleEnabled.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: playbackControlButtonWidth)
                    .foregroundStyle(settings.isShuffleEnabled ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
            .help(settings.isShuffleEnabled ? "シャッフル: オン" : "シャッフル: オフ")
            .accessibilityLabel("シャッフル")

            Button {
                settings.repeatMode = settings.repeatMode.next
            } label: {
                Image(systemName: settings.repeatMode.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: playbackControlButtonWidth)
                    .foregroundStyle(settings.repeatMode == .off ? Color.primary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(settings.repeatMode.title)
            .accessibilityLabel(settings.repeatMode.title)

            if PictureInPictureCoordinator.isSupported {
                Button {
                    pictureInPicture.toggle()
                } label: {
                    Image(systemName: pictureInPicture.isActive
                          ? "pip.exit"
                          : "pip.enter")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: playbackControlButtonWidth)
                        .foregroundStyle(pictureInPicture.isActive ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .disabled(!pictureInPicture.isPossible && !pictureInPicture.isActive)
                .help(pictureInPicture.isActive ? "小窓をやめて戻す" : "ピクチャインピクチャ（P）")
                .accessibilityLabel("ピクチャインピクチャ")
            }

            playbackOptionsMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: playbackControlsMaxWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, playbackControlsHorizontalPadding)
        .padding(.bottom, playbackControlsBottomPadding)
    }

    /// 再生速度と自動再生。ボタンを並べるには数が多いのでメニューにまとめる。
    private var playbackOptionsMenu: some View {
        Menu {
            Picker("再生速度", selection: rateBinding) {
                ForEach(PlaybackSettings.availableRates, id: \.self) { value in
                    Text(PlaybackSettings.label(forRate: value)).tag(value)
                }
            }
            .pickerStyle(.inline)

            // トラックが1つしかない動画にまで選択 UI を出しても選ぶものがない。
            if viewModel.audioTracks.count > 1 {
                Divider()
                Picker("音声", selection: audioTrackBinding) {
                    ForEach(viewModel.audioTracks) { track in
                        Text(track.displayName).tag(track.index)
                    }
                }
            }

            if !viewModel.subtitleTracks.isEmpty {
                Divider()
                Picker("字幕", selection: subtitleTrackBinding) {
                    ForEach(viewModel.subtitleTracks) { track in
                        Text(track.displayName).tag(track.index)
                    }
                }
            }

            Divider()

            Toggle("終わったら次の動画へ", isOn: $settings.autoPlayNext)
        } label: {
            HStack(spacing: 4) {
                if viewModel.selectedSubtitleIndex != VideoPlayerViewModel.MediaTrackChoice.offIndex {
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(settings.rateLabel)
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("再生速度・音声・字幕・自動再生")
        .accessibilityLabel("再生の設定")
    }

    /// なぞっている位置のプレビュー札。画像が来るまでは時刻だけ出す
    /// （出す/出さないを画像の有無で切り替えると、なぞるたびに札が点滅する）。
    private var scrubPreviewCard: some View {
        VStack(spacing: 4) {
            Group {
                if let image = scrubPreview.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.black.opacity(0.55))
                }
            }
            .frame(width: scrubPreviewWidth, height: scrubPreviewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            )

            Text(formatTime(hoveredSeconds ?? 0))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(5)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .allowsHitTesting(false)
    }

    /// なぞっている位置の秒数（プレビュー画像の実際の位置ではなく、カーソルが指している位置）。
    private var hoveredSeconds: Double? {
        guard let fraction = scrubHoverFraction else { return nil }
        return fraction * max(viewModel.duration, 0)
    }

    /// 札の中心をカーソルに合わせつつ、シークバーの端からはみ出さないように寄せる。
    private func scrubPreviewOffsetX(for fraction: Double) -> CGFloat {
        let cardWidth = scrubPreviewWidth + 10
        let centered = seekBarWidth * fraction - cardWidth / 2
        return min(max(centered, 0), max(seekBarWidth - cardWidth, 0))
    }

    private func handleSeekBarHover(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            // 操作系の表示維持は外側の onContinuousHover が既に担っている。
            guard seekBarWidth > 0, viewModel.duration > minimumSliderDuration else { return }
            let fraction = min(max(location.x / seekBarWidth, 0), 1)
            scrubHoverFraction = fraction
            scrubPreview.request(seconds: fraction * viewModel.duration)
        case .ended:
            scrubHoverFraction = nil
            scrubPreview.cancel()
        }
    }

    private var audioTrackBinding: Binding<Int> {
        Binding(
            get: { viewModel.selectedAudioIndex },
            set: { viewModel.selectAudioTrack(index: $0) }
        )
    }

    private var subtitleTrackBinding: Binding<Int> {
        Binding(
            get: { viewModel.selectedSubtitleIndex },
            set: { viewModel.selectSubtitleTrack(index: $0) }
        )
    }

    /// 速度の変更は ViewModel 経由。再生中のプレイヤーへ即座に効かせる必要がある。
    private var rateBinding: Binding<Double> {
        Binding(
            get: { settings.rate },
            set: { viewModel.applyRate($0) }
        )
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
        if MediaShortcutSettings.matches(.videoClose, press: press) {
            coordinator.close()
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
        } else if MediaShortcutSettings.matches(.videoToggleUpNextPanel, press: press) {
            withAnimation(.easeInOut(duration: 0.22)) {
                isUpNextPanelVisible.toggle()
            }
            return .handled
        } else if MediaShortcutSettings.matches(.videoToggleMiniPlayer, press: press) {
            withAnimation(.easeInOut(duration: 0.22)) {
                coordinator.isMiniPlayerActive = true
            }
            return .handled
        } else if MediaShortcutSettings.matches(.videoToggleShuffle, press: press) {
            settings.isShuffleEnabled.toggle()
            return .handled
        } else if MediaShortcutSettings.matches(.videoCycleRepeat, press: press) {
            settings.repeatMode = settings.repeatMode.next
            return .handled
        } else if MediaShortcutSettings.matches(.videoRateDown, press: press) {
            viewModel.stepRate(by: -1)
            return .handled
        } else if MediaShortcutSettings.matches(.videoRateUp, press: press) {
            viewModel.stepRate(by: 1)
            return .handled
        } else if MediaShortcutSettings.matches(.videoTogglePictureInPicture, press: press) {
            pictureInPicture.toggle()
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
