import AppKit
import Darwin
import QuickLookUI
import SwiftUI

@main
struct AllServerForMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.raiseFileDescriptorLimit()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 680)
        }
        .commands {
            AppMenuCommands()
        }
    }

    /// GUIアプリはLaunchServices経由の起動だとNOFILEソフトリミットが既定256のままになりやすく、
    /// 紐づけフォルダの監視（アルバム1件につきfd+DispatchSourceを1つ張る）が数百件になると
    /// すぐに枯渇し、フォント/CoreUIアセット読み込み失敗（EMFILE）を起こして描画が壊れる。
    /// ハードリミットの範囲内でソフトリミットを引き上げておく。
    private static func raiseFileDescriptorLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let desired: rlim_t = 8192
        guard limit.rlim_cur < desired else { return }
        limit.rlim_cur = min(desired, limit.rlim_max)
        setrlimit(RLIMIT_NOFILE, &limit)
    }
}

struct AppMenuContext {
    let isLibraryLoaded: Bool
    let isServerRunning: Bool
    let serverURL: String?
    let canRefreshLinkedFolders: Bool
    let isPresentingPlayer: Bool
    let canToggleMiniPlayer: Bool
    let isMiniPlayerActive: Bool
    let showPreferences: () -> Void
    let showStorageManager: () -> Void
    let showAccessLog: () -> Void
    let showHome: () -> Void
    let showAllVideos: () -> Void
    let showAllPhotos: () -> Void
    let showFavorites: () -> Void
    let showTrash: () -> Void
    let refreshLinkedFolders: () -> Void
    let openDataFolder: () -> Void
    let startServer: () -> Void
    let stopServer: () -> Void
    let openServerInBrowser: () -> Void
    let copyServerURL: () -> Void
    let closePlayer: () -> Void
    let toggleMiniPlayer: () -> Void
}

private struct AppMenuContextKey: FocusedValueKey {
    typealias Value = AppMenuContext
}

extension FocusedValues {
    var appMenuContext: AppMenuContext? {
        get { self[AppMenuContextKey.self] }
        set { self[AppMenuContextKey.self] = newValue }
    }
}

struct AppMenuCommands: Commands {
    @FocusedValue(\.appMenuContext) private var context

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("全画面表示／解除") {
                toggleFullScreen()
            }
            .keyboardShortcut("f", modifiers: [.control, .command])
        }

        CommandGroup(replacing: .appSettings) {
            Button("詳細設定…") {
                context?.showPreferences()
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(context == nil)

            Button("ストレージ管理…") {
                context?.showStorageManager()
            }
            .disabled(context == nil)
        }

        CommandMenu("ライブラリ") {
            Button("ホーム") {
                context?.showHome()
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(context == nil)

            Button("すべての動画") {
                context?.showAllVideos()
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(context?.isLibraryLoaded != true)

            Button("すべての画像") {
                context?.showAllPhotos()
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(context?.isLibraryLoaded != true)

            Button("お気に入り") {
                context?.showFavorites()
            }
            .keyboardShortcut("4", modifiers: .command)
            .disabled(context == nil)

            Button("ゴミ箱") {
                context?.showTrash()
            }
            .keyboardShortcut("5", modifiers: .command)
            .disabled(context == nil)

            Divider()

            Button("連携フォルダを更新") {
                context?.refreshLinkedFolders()
            }
            .disabled(context?.canRefreshLinkedFolders != true)

            Button("データフォルダをFinderで表示") {
                context?.openDataFolder()
            }
            .disabled(context == nil)
        }

        CommandMenu("サーバー") {
            Button("サーバーを開始") {
                context?.startServer()
            }
            .disabled(
                context?.isLibraryLoaded != true
                    || context?.isServerRunning == true
            )

            Button("サーバーを停止") {
                context?.stopServer()
            }
            .disabled(context?.isServerRunning != true)

            Divider()

            Button("ブラウザで開く") {
                context?.openServerInBrowser()
            }
            .disabled(context?.serverURL == nil)

            Button("サーバーURLをコピー") {
                context?.copyServerURL()
            }
            .disabled(context?.serverURL == nil)

            Button("アクセスログ…") {
                context?.showAccessLog()
            }
            .disabled(context == nil)
        }

        CommandMenu("再生") {
            Button("プレイヤーを閉じる") {
                context?.closePlayer()
            }
            .disabled(context?.isPresentingPlayer != true)

            Button(
                context?.isMiniPlayerActive == true
                    ? "フルサイズに戻す"
                    : "ミニプレイヤーにする"
            ) {
                context?.toggleMiniPlayer()
            }
            .disabled(context?.canToggleMiniPlayer != true)
        }
    }

    private func toggleFullScreen() {
        let focusedWindow = NSApp.keyWindow
        let contentWindow = focusedWindow?.sheetParent ?? focusedWindow ?? NSApp.mainWindow
        contentWindow?.toggleFullScreen(nil)
    }
}

/// クイックルックパネルの制御役。
///
/// QLPreviewPanel は「誰がパネルを制御するか」をレスポンダチェーンを辿って決める。
/// 一覧グリッドは SwiftUI の .focusable()/.onKeyPress でファーストレスポンダを使っており、
/// そこへ AppKit のビューを割り込ませると矢印キーでの項目移動が壊れる。
/// チェーンの終点であるアプリのデリゲートで受ければ、フォーカスに一切触らずに済む。
final class AppDelegate: NSObject, NSApplicationDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookPreviewController.shared
        // 矢印キーを一覧の選択移動へ回すために、キー入力も受け取る。
        panel.delegate = QuickLookPreviewController.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        QuickLookPreviewController.shared.panelControlEnded()
    }
}
