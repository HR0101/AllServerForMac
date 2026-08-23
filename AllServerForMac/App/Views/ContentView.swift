import AppKit
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

            if let error = dataManager.storageInitializationError {
                LibraryStorageInitializationErrorView(error: error)
            } else {
                // 再生中はライブラリ画面を本当に破棄する。opacity 0 で残すと、
                // ホームの1秒ごとのシステム監視・アルバム一覧のサムネイル・影付きカードが
                // 再生中もずっと描画され続け、動画がカクつく。差分探索画面はライブラリとは
                // 独立した兄弟Viewなので、こちらを外しても探索位置は保持される。
                if shouldShowLibraryView {
                    libraryView
                }

                if let albumID = playbackCoordinator.variantFinderAlbumID {
                    variantFinderOverlay(albumID: albumID)
                        .zIndex(1)
                }

                if let mode = playbackCoordinator.mode {
                    playerOverlay(for: mode)
                        .zIndex(2)
                }
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
        .environmentObject(viewModel.remotePlaybackSession)
        .environmentObject(appSettings)
        .environmentObject(viewModel.variantFinder)
        .focusedSceneValue(
            \.appMenuContext,
            dataManager.isStorageReady ? appMenuContext : nil
        )
        .sheet(isPresented: $viewModel.isShowingPreferences) {
            PreferencesView(
                dataManager: dataManager,
                webServerManager: viewModel.webServerManager,
                appSettings: appSettings
            )
        }
        .sheet(isPresented: $viewModel.isShowingStorageManager) {
            StorageManagerView(dataManager: dataManager)
        }
        .sheet(isPresented: $viewModel.isShowingAccessLog) {
            AccessLogView(webServerManager: viewModel.webServerManager)
        }
        .alert(
            "ファイル操作の結果",
            isPresented: Binding(
                get: { dataManager.mediaDeletionNotice != nil },
                set: { if !$0 { dataManager.mediaDeletionNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                dataManager.mediaDeletionNotice = nil
            }
        } message: {
            Text(dataManager.mediaDeletionNotice ?? "")
        }
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
        guard let mode = playbackCoordinator.mode else { return false }
        if case .single = mode, playbackCoordinator.isMiniPlayerActive { return false }
        return true
    }

    /// sheet は別ウィンドウ扱いになり、ContentView のプレイヤーをその上へ重ねられない。
    /// 同じ ZStack に探索画面を置き、再生時はこの View を残したままプレイヤーを最前面へ出す。
    private func variantFinderOverlay(albumID: UUID) -> some View {
        ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()

            VariantVideoView(
                items: variantFinderItems,
                dataManager: dataManager,
                hostWindowSize: playbackCoordinator.variantFinderHostSize,
                onClose: playbackCoordinator.closeVariantFinder
            )
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.42), radius: 28, y: 12)
            .id(albumID)
        }
    }

    /// 開いた時点の検索・並べ替え順を保ちつつ、削除された項目は現在のライブラリから除く。
    private var variantFinderItems: [VideoItem] {
        let itemsByID = Dictionary(
            dataManager.videos.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        return playbackCoordinator.variantFinderItemIDs.compactMap { id in
            guard let item = itemsByID[id], !item.isInTrash else { return nil }
            return item
        }
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
                .id(current.id)
        case .multi(let videos):
            MultiVideoPlayerView(videos: videos, dataManager: dataManager)
                .ignoresSafeArea()
        case .variantSwitch(let videos):
            VariantSwitchPlayerView(videos: videos, dataManager: dataManager)
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
                    selection: $viewModel.selection,
                    isShowingPreferences: $viewModel.isShowingPreferences,
                    isShowingStorageManager: $viewModel.isShowingStorageManager
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
                    case .folder(let path, let isPhoto):
                        FolderDetailView(
                            path: path,
                            isPhoto: isPhoto,
                            dataManager: dataManager,
                            selection: $viewModel.selection
                        )
                            .navigationTitle(path.components(separatedBy: "/").last ?? path)
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

    private var appMenuContext: AppMenuContext {
        AppMenuContext(
            isLibraryLoaded: dataManager.isLibraryLoaded,
            isServerRunning: viewModel.isServerRunning,
            serverURL: viewModel.currentServerURL,
            canRefreshLinkedFolders: dataManager.linkedFolderCount > 0,
            isPresentingPlayer: playbackCoordinator.isPresenting,
            canToggleMiniPlayer: isSingleVideoPlayback,
            isMiniPlayerActive: playbackCoordinator.isMiniPlayerActive,
            showPreferences: { viewModel.isShowingPreferences = true },
            showStorageManager: { viewModel.isShowingStorageManager = true },
            showAccessLog: { viewModel.isShowingAccessLog = true },
            showHome: { viewModel.selection = .home },
            showAllVideos: {
                selectSystemAlbum(named: LibraryViewModel.allVideosAlbumName)
            },
            showAllPhotos: {
                selectSystemAlbum(named: LibraryViewModel.allPhotosAlbumName)
            },
            showFavorites: { viewModel.selection = .favorites },
            showTrash: { viewModel.selection = .trash },
            refreshLinkedFolders: {
                Task { await dataManager.rescanAllLinkedFolders() }
            },
            openDataFolder: dataManager.openAppRootFolderInFinder,
            startServer: viewModel.webServerManager.startServer,
            stopServer: viewModel.webServerManager.stopServer,
            openServerInBrowser: openServerInBrowser,
            copyServerURL: copyServerURL,
            closePlayer: playbackCoordinator.close,
            toggleMiniPlayer: toggleMiniPlayer
        )
    }

    private var isSingleVideoPlayback: Bool {
        guard let mode = playbackCoordinator.mode else { return false }
        if case .single = mode {
            return true
        }
        return false
    }

    private func selectSystemAlbum(named name: String) {
        guard let albumID = dataManager.albums.first(
            where: { $0.name == name }
        )?.id else {
            return
        }
        viewModel.selection = .album(albumID)
    }

    private func openServerInBrowser() {
        guard let value = viewModel.currentServerURL,
              let url = URL(string: value) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func copyServerURL() {
        guard let value = viewModel.currentServerURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func toggleMiniPlayer() {
        guard isSingleVideoPlayback else { return }
        playbackCoordinator.isMiniPlayerActive.toggle()
    }
}

private struct LibraryStorageInitializationErrorView: View {
    let error: LibraryStorageInitializationError

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.red)

            VStack(spacing: 8) {
                Text("ライブラリ保存先を準備できませんでした")
                    .font(.title2.bold())
                Text("データを保護するため，ライブラリの読み込みとサーバー起動を停止しています．")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                errorRow(title: "対象", value: error.locationName)
                errorRow(title: "パス", value: error.targetPath)
                errorRow(title: "原因", value: error.reason)
                errorRow(title: "確認事項", value: error.recoverySuggestion)
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        error.targetPath,
                        forType: .string
                    )
                } label: {
                    Label("パスをコピー", systemImage: "doc.on.doc")
                }

                Button("終了") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
