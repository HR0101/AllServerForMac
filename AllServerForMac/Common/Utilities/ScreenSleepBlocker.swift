import Foundation

/// 再生中だけ画面のスリープ（とシステムのアイドルスリープ）を止める。
///
/// `ProcessInfo.beginActivity` は macOS 標準の仕組みで、エンタイトルメントも管理者権限も要らない。
/// 返ってきたトークンを取り違えると二度と解除できなくなるため、
/// トークンの保持と解除はこのクラス1か所に閉じ込める。
@MainActor
final class ScreenSleepBlocker {

    private var token: NSObjectProtocol?
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    var isActive: Bool { token != nil }

    /// 同じ状態で何度呼ばれてもアクティビティは1本しか持たない（多重取得すると解除漏れになる）。
    func setActive(_ active: Bool) {
        if active {
            guard token == nil else { return }
            token = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                reason: reason
            )
        } else {
            guard let token else { return }
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }
}
