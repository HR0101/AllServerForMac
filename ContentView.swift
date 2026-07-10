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

    init() {
        let manager = VideoDataManager()
        _dataManager = StateObject(wrappedValue: manager)
        _webServerManager = StateObject(wrappedValue: WebServerManager(dataManager: manager))
    }

    var body: some View {
        Group {
            // 再生中はライブラリ画面（サイドバー/ツールバー含む）ごとプレイヤーに差し替え、
            // 他のUIが前面に残らない完全な全画面にする（元アプリと同じ方式）。
            if let mode = coordinator.mode {
                switch mode {
                case .photos:
                    playerOverlay(for: mode)
                default:
                    playerOverlay(for: mode)
                        .ignoresSafeArea()
                }
            } else {
                libraryView
            }
        }
        .environmentObject(coordinator)
        .environmentObject(appSettings)
    }

    /// 再生中はウィンドウ全体を占有するプレイヤー
    @ViewBuilder
    private func playerOverlay(for mode: PlaybackCoordinator.Mode) -> some View {
        switch mode {
        case .single(let playlist, let current):
            VideoPlayerView(videos: playlist, currentVideo: current, dataManager: dataManager)
        case .multi(let videos):
            MultiVideoPlayerView(videos: videos, dataManager: dataManager)
        case .slideshow(let videos):
            SlideshowPlayerView(videos: videos, dataManager: dataManager)
        case .splitPlay(let video, let splitCount):
            SplitVideoPlayerView(video: video, splitCount: splitCount, dataManager: dataManager)
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
        .tint(DS.cyan)
        .preferredColorScheme(.dark)
        .toolbarBackground(.hidden, for: .windowToolbar)
    }
}
