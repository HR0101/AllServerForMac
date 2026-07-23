import AppKit
import SwiftUI


enum NavigationSelection: Hashable {
    case home
    case favorites
    case trash
    case album(UUID)
}

// MARK: - メインビュー
struct ContentView: View {
    @StateObject private var dataManager: VideoDataManager
    @StateObject private var webServerManager: WebServerManager

    @State private var selection: NavigationSelection? = .home

    @StateObject private var coordinator = PlaybackCoordinator()
    @StateObject private var appSettings = AppSettings()
    private let sidebarMinWidth: CGFloat = 300
    private let sidebarIdealWidth: CGFloat = 320
    private let sidebarMaxWidth: CGFloat = 360

    init() {
        let manager = VideoDataManager()
        _dataManager = StateObject(wrappedValue: manager)
        _webServerManager = StateObject(wrappedValue: WebServerManager(dataManager: manager))
    }

    var body: some View {
        // 再生中はライブラリ画面（サイドバー/ツールバー含む）ごとプレイヤーに差し替え、
        // 他のUIが前面に残らない完全な全画面にする（元アプリと同じ方式）。
        // ただし通常再生をIキーでミニプレイヤー化した間はアルバム一覧を操作できるよう裏に残す。
        ZStack(alignment: .bottomTrailing) {
            NeomorphicTheme.background
                .ignoresSafeArea()

            libraryView
                .opacity(shouldShowLibraryView ? 1 : 0)
                .allowsHitTesting(shouldShowLibraryView)
                .accessibilityHidden(!shouldShowLibraryView)

            if let mode = coordinator.mode {
                playerOverlay(for: mode)
            }
        }
        .toolbar(isToolbarHidden ? .hidden : .automatic, for: .windowToolbar)
        .environmentObject(coordinator)
        .environmentObject(appSettings)
    }

    /// ミニプレイヤー表示中は通常再生の裏でライブラリも操作できるようにする。
    private var shouldShowLibraryView: Bool {
        guard let mode = coordinator.mode else { return true }
        if case .single = mode {
            return coordinator.isMiniPlayerActive
        }
        return false
    }

    private var isToolbarHidden: Bool {
        coordinator.mode != nil && !shouldShowLibraryView
    }

    /// 再生中はウィンドウ全体を占有するプレイヤー（通常再生はIキーでミニプレイヤー化できる）
    @ViewBuilder
    private func playerOverlay(for mode: PlaybackCoordinator.Mode) -> some View {
        switch mode {
        case .single(let playlist, let current):
            VideoPlayerView(videos: playlist, currentVideo: current, dataManager: dataManager)
        case .multi(let videos):
            MultiVideoPlayerView(videos: videos, dataManager: dataManager)
                .ignoresSafeArea()
        case .slideshow(let videos):
            SlideshowPlayerView(videos: videos, dataManager: dataManager)
                .ignoresSafeArea()
        case .splitPlay(let video, let splitCount):
            SplitVideoPlayerView(video: video, splitCount: splitCount, dataManager: dataManager)
                .ignoresSafeArea()
        case .photos(let playlist, let current):
            PhotoViewerView(photos: playlist, current: current, dataManager: dataManager)
        }
    }

    private var libraryView: some View {
        ZStack {
            // ツールバーの背後まで同じ背景を広げ，フルスクリーン時の色の段差をなくす。
            CommandDeckBackground()

            NavigationSplitView {
                MainSidebarView(dataManager: dataManager, webServerManager: webServerManager, selection: $selection)
                    .navigationSplitViewColumnWidth(
                        min: sidebarMinWidth,
                        ideal: sidebarIdealWidth,
                        max: sidebarMaxWidth
                    )
            } detail: {
                NavigationStack {
                    switch selection {
                    case .home:
                        HomeView(dataManager: dataManager, webServerManager: webServerManager)
                            .navigationTitle("ホーム")
                    case .favorites:
                        LibraryCategoryView(kind: .favorites, dataManager: dataManager)
                            .navigationTitle("お気に入り")
                    case .trash:
                        LibraryCategoryView(kind: .trash, dataManager: dataManager)
                            .navigationTitle("ゴミ箱")
                    case .album(let albumID):
                        if let album = dataManager.albums.first(where: { $0.id == albumID }) {
                            AlbumDetailView(album: album, dataManager: dataManager)
                                .navigationTitle(album.name)
                        } else {
                            ContentUnavailableView("アルバムが見つかりません", systemImage: "questionmark.folder")
                        }
                    case .none:
                        ContentUnavailableView("サイドバーから項目を選択してください", systemImage: "sidebar.left")
                    }
                }
            }
        }
        .tint(NeomorphicTheme.accent)
        .preferredColorScheme(appSettings.neomorphicDarkBase ? .dark : .light)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(WindowChromeConfigurator())
        .ignoresSafeArea()
        // ベースカラーを切り替えたら、色を静的に参照している全ビュー（CommandDeckBackground・
        // カード・サイドバー等）を確実に描き直すため、ライブラリ画面ごと作り直す。
        // これをしないと一部だけ色が更新されず、白背景に白文字などのちぐはぐが起きる。
        .id(appSettings.neomorphicDarkBase)
    }
}

/// macOS標準のタイトルバーをコンテンツと同じ黒い背景に重ねるための設定です。
/// toolbarBackgroundだけではタイトルバー領域の外観を完全に消せないため，
/// NSWindowをフルサイズコンテンツビューとして明示的に構成します。
private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowChromeView {
        WindowChromeView()
    }

    func updateNSView(_ nsView: WindowChromeView, context: Context) {
        nsView.applyWindowChrome()
    }
}

private final class WindowChromeView: NSView {
    private var fullScreenObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeFullScreenTransitions()
        applyWindowChrome()
    }

    /// フルスクリーンへ出入りするとタイトルバー／ツールバーの背景ビューが作り直され、
    /// 上端に黒い帯が出る。遷移のたびに設定し直す（背景ビューは遷移直後に生成されるため
    /// 通知の同期タイミングに加えて次のループでも当てる）。
    private func observeFullScreenTransitions() {
        fullScreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        fullScreenObservers.removeAll()
        guard let window else { return }
        let names: [NSNotification.Name] = [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didResizeNotification
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.applyWindowChrome()
                DispatchQueue.main.async { self?.applyWindowChrome() }
            }
            fullScreenObservers.append(token)
        }
    }

    deinit {
        fullScreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func applyWindowChrome() {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.toolbar?.showsBaselineSeparator = false
        // ウィンドウのクロム（タイトルバー・ツールバー）をアプリのテーマに固定する。
        // システムがダークだと、フルスクリーンの上端が黒く見える一因になるため。
        window.appearance = NSAppearance(named: NeomorphicTheme.isDarkBase ? .darkAqua : .aqua)
        window.backgroundColor = NeomorphicTheme.isDarkBase
            ? NSColor(red: 0.08, green: 0.085, blue: 0.09, alpha: 1.0)
            : NSColor(red: 0.89, green: 0.92, blue: 0.93, alpha: 1.0)
        window.toolbarStyle = .unifiedCompact
        clearTitlebarBackground(of: window)
    }

    /// タイトルバー／ツールバー領域に付く不透明な背景（フルスクリーン時の黒帯の実体）を透明化する。
    /// `titlebarAppearsTransparent` だけでは全画面で残るため、背景の視覚効果ビューを直接消して
    /// 背後のコンテンツ（CommandDeckBackground）が透けるようにする。ツールバーのボタン等は
    /// 別ビューなので残る。
    private func clearTitlebarBackground(of window: NSWindow) {
        guard let frameView = window.contentView?.superview else { return }
        for container in titlebarContainers(in: frameView) {
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.clear.cgColor
            configureTitlebarSubviews(in: container)
        }
    }

    /// 全画面ではツールバー背景が深い階層へ移動するため，再帰的に視覚効果ビューを処理する。
    private func configureTitlebarSubviews(in view: NSView) {
        for subview in view.subviews {
            if let background = subview as? NSVisualEffectView {
                if containsToolbar(background) {
                    // ツールバーボタンを維持しつつ，背景はウィンドウのテーマ色を参照させる。
                    background.isHidden = false
                    background.material = .underWindowBackground
                    background.blendingMode = .withinWindow
                    background.state = .active
                } else {
                    background.isHidden = true
                }
            }
            configureTitlebarSubviews(in: subview)
        }
    }

    /// フレームビュー配下から NSTitlebarContainerView を（入れ子でも）探す。
    private func titlebarContainers(in view: NSView) -> [NSView] {
        var result: [NSView] = []
        for sub in view.subviews {
            if String(describing: type(of: sub)) == "NSTitlebarContainerView" {
                result.append(sub)
            }
            result.append(contentsOf: titlebarContainers(in: sub))
        }
        return result
    }

    /// ビュー配下にツールバー系のビューが含まれるか（背景として消してよいか判定するため）。
    private func containsToolbar(_ view: NSView) -> Bool {
        if String(describing: type(of: view)).contains("Toolbar") { return true }
        for sub in view.subviews {
            if String(describing: type(of: sub)).contains("Toolbar") { return true }
            if containsToolbar(sub) { return true }
        }
        return false
    }
}
