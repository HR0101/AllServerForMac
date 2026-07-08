import Darwin
import SwiftUI

@main
struct AllServerForMacApp: App {
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
