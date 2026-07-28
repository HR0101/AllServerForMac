import SwiftUI

// MARK: - メインビュー
struct ContentView: View {
    @StateObject private var viewModel: AppViewModel
    @ObservedObject private var dataManager: LibraryViewModel
    @ObservedObject private var playbackCoordinator: PlaybackCoordinator
    @ObservedObject private var appSettings: AppSettings
    private let sidebarMinWidth: CGFloat = 300
    private let sidebarIdealWidth: CGFloat = 320
    private let sidebarMaxWidth: CGFloat = 360

    init() {
        let viewModel = AppViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        _dataManager = ObservedObject(wrappedValue: viewModel.dataManager)
        _playbackCoordinator = ObservedObject(
            wrappedValue: viewModel.playbackCoordinator
        )
        _appSettings = ObservedObject(wrappedValue: viewModel.appSettings)
    }

    init(viewModel: AppViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _dataManager = ObservedObject(wrappedValue: viewModel.dataManager)
        _playbackCoordinator = ObservedObject(
            wrappedValue: viewModel.playbackCoordinator
        )
        _appSettings = ObservedObject(wrappedValue: viewModel.appSettings)
    }

    var body: some View {
        // 再生中はライブラリ画面（サイドバー/ツールバー含む）ごとプレイヤーに差し替え、
        // 他のUIが前面に残らない完全な全画面にする（元アプリと同じ方式）。
        // ただし通常再生をIキーでミニプレイヤー化した間はアルバム一覧を操作できるよう裏に残す。
        ZStack(alignment: .bottomTrailing) {
            // ライブラリ画面を外した瞬間に素の（＝黒い）ウィンドウ背景が覗かないよう、
            // 常駐する下地を1枚敷いておく。上端の黒帯対策の要はこの下地とウィンドウ設定であって、
            // ライブラリ画面を出しっぱなしにすることではない。
            NeomorphicTheme.background
                .ignoresSafeArea()

            // 再生中はライブラリ画面を本当に破棄する。opacity 0 で残すと、
            // ホームの1秒ごとのシステム監視・アルバム一覧のサムネイル・影付きカードが
            // 再生中もずっと描画され続け、動画がカクつく。
            if shouldShowLibraryView {
                libraryView
            }

            if let mode = playbackCoordinator.mode {
                playerOverlay(for: mode)
            }
        }
        // ウィンドウのクロム設定はライブラリ画面の有無に関わらず効かせる必要があるため、
        // ライブラリ画面ではなくこの常駐の階層に付ける。
        .toolbar(isToolbarHidden ? .hidden : .automatic, for: .windowToolbar)
        .toolbarBackground(NeomorphicTheme.background, for: .windowToolbar)
        .toolbarBackground(
            isToolbarHidden ? .hidden : .visible,
            for: .windowToolbar
        )
        .background(
            WindowChromeConfigurator(isToolbarHidden: isToolbarHidden)
        )
        .tint(NeomorphicTheme.accent)
        .preferredColorScheme(appSettings.neomorphicDarkBase ? .dark : .light)
        .environmentObject(playbackCoordinator)
        .environmentObject(appSettings)
    }

    /// ミニプレイヤー表示中は通常再生の裏でライブラリも操作できるようにする。
    private var shouldShowLibraryView: Bool {
        guard let mode = playbackCoordinator.mode else { return true }
        if case .single = mode {
            return playbackCoordinator.isMiniPlayerActive
        }
        return false
    }

    private var isToolbarHidden: Bool {
        playbackCoordinator.mode != nil && !shouldShowLibraryView
    }

    /// 再生中はウィンドウ全体を占有するプレイヤー（通常再生はIキーでミニプレイヤー化できる）
    @ViewBuilder
    private func playerOverlay(for mode: PlaybackCoordinator.Mode) -> some View {
        switch mode {
        case .single(let playlist, let current):
            VideoPlayerView(
                videos: playlist,
                currentVideo: current,
                dataManager: dataManager
            )
        case .multi(let videos):
            MultiVideoPlayerView(videos: videos, dataManager: dataManager)
                .ignoresSafeArea()
        case .slideshow(let videos):
            SlideshowPlayerView(videos: videos, dataManager: dataManager)
                .ignoresSafeArea()
        case .splitPlay(let video, let splitCount):
            SplitVideoPlayerView(
                video: video,
                splitCount: splitCount,
                dataManager: dataManager
            )
                .ignoresSafeArea()
        case .photos(let playlist, let current):
            PhotoViewerView(
                photos: playlist,
                current: current,
                dataManager: dataManager
            )
        }
    }

    private var libraryView: some View {
        ZStack {
            // ツールバーの背後まで同じ背景を広げ，フルスクリーン時の色の段差をなくす。
            CommandDeckBackground()

            NavigationSplitView {
                MainSidebarView(
                    dataManager: dataManager,
                    webServerManager: viewModel.webServerManager,
                    selection: $viewModel.selection
                )
                    .navigationSplitViewColumnWidth(
                        min: sidebarMinWidth,
                        ideal: sidebarIdealWidth,
                        max: sidebarMaxWidth
                    )
            } detail: {
                NavigationStack {
                    switch viewModel.selection {
                    case .home:
                        HomeView(
                            dataManager: dataManager,
                            webServerManager: viewModel.webServerManager
                        )
                            .navigationTitle("ホーム")
                    case .favorites:
                        LibraryCategoryView(
                            kind: .favorites,
                            dataManager: dataManager
                        )
                            .navigationTitle("お気に入り")
                    case .trash:
                        LibraryCategoryView(
                            kind: .trash,
                            dataManager: dataManager
                        )
                            .navigationTitle("ゴミ箱")
                    case .album(let albumID):
                        if let album = dataManager.albums.first(
                            where: { $0.id == albumID }
                        ) {
                            AlbumDetailView(
                                album: album,
                                dataManager: dataManager
                            )
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
        // tint / preferredColorScheme / toolbarBackground / WindowChromeConfigurator は
        // 再生中もウィンドウに効かせ続ける必要があるため body 側（常駐する階層）に付けてある。
        .ignoresSafeArea()
        // ベースカラーを切り替えたら、色を静的に参照している全ビュー（CommandDeckBackground・
        // カード・サイドバー等）を確実に描き直すため、ライブラリ画面ごと作り直す。
        // これをしないと一部だけ色が更新されず、白背景に白文字などのちぐはぐが起きる。
        .id(appSettings.neomorphicDarkBase)
    }
}
