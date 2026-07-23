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
        .toolbarBackground(NeomorphicTheme.background, for: .windowToolbar)
        .toolbarBackground(
            isToolbarHidden ? .hidden : .visible,
            for: .windowToolbar
        )
        .background(
            WindowChromeConfigurator(isToolbarHidden: isToolbarHidden)
        )
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
    let isToolbarHidden: Bool

    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        view.isToolbarHidden = isToolbarHidden
        return view
    }

    func updateNSView(_ nsView: WindowChromeView, context: Context) {
        nsView.isToolbarHidden = isToolbarHidden
        nsView.applyWindowChrome()
    }
}

private final class WindowChromeView: NSView {
    var isToolbarHidden = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowChrome()
    }

    func applyWindowChrome() {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // ウィンドウのクロム（タイトルバー・ツールバー）をアプリのテーマに固定する。
        // システムがダークだと、フルスクリーンの上端が黒く見える一因になるため。
        window.appearance = NSAppearance(named: NeomorphicTheme.isDarkBase ? .darkAqua : .aqua)
        window.backgroundColor = NeomorphicTheme.isDarkBase
            ? NSColor(red: 0.08, green: 0.085, blue: 0.09, alpha: 1.0)
            : NSColor(red: 0.89, green: 0.92, blue: 0.93, alpha: 1.0)
        window.toolbarStyle = .unifiedCompact
        window.toolbar?.isVisible = !isToolbarHidden
    }
}
