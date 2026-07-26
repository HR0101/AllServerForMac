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
