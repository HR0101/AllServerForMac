import AppKit
import Combine
import SwiftUI

// MARK: - 操作系の自動的な出し入れ
//
// 一般的な動画プレイヤーと同じ振る舞い。シークバーや各種ボタンはカーソルを動かしている間だけ出し、
// しばらく動かさなければ引っ込める（そのときポインタも消す）。
//
// ただし「引っ込めてはいけない事情」がいくつかある。つまみの上にポインタが乗っている間に
// 消えると操作できなくなるし、止まっているときに消えると再生ボタンの在り処が分からなくなる。
// そういう事情を `Hold` として積んでおき、1つでも残っている間は出したままにする。
//
// 通常再生（`VideoPlayerView`）だけはこれを使っていない。あちらは同じ表示条件で
// 関連動画パネルやサムネイル帯まで出し分けており、素直にこの形へ収まらないため、
// 先に入れた自前の実装をそのまま残してある（振る舞いと 2.5 秒という間隔は揃えてある）。
@MainActor
final class PlayerChromeController: ObservableObject {
    /// 出したままにしておく理由。1つでも立っていれば引っ込めない。
    struct Hold: OptionSet, Sendable {
        let rawValue: Int
        /// ポインタが操作系の上にある。触っている最中に消えると操作できない。
        static let pointerOverControls = Hold(rawValue: 1 << 0)
        /// ショートカット一覧など、別のものを重ねて出している。
        static let overlayVisible = Hold(rawValue: 1 << 1)
        /// 止まっている。消えていると再生ボタンの在り処が分からなくなる。
        static let paused = Hold(rawValue: 1 << 2)
    }

    /// 引っ込めるまでの無操作時間。通常再生（`VideoPlayerView`）と同じにしてある。
    /// 既定引数から読むので、アクター隔離の外に置く。
    nonisolated static let autoHideSeconds: Double = 2.5

    /// 最近カーソルが動いたか。
    @Published private(set) var isActive = true
    /// 手動で出しっぱなしに固定しているか。
    @Published private(set) var isPinned = false
    @Published private(set) var holds: Hold = []

    /// 中身の出し分けはこれを見る。
    var isShown: Bool { isPinned || !holds.isEmpty || isActive }

    private var hideTask: Task<Void, Never>?

    /// 作った時点で引っ込めるまでの時計を動かし始める。
    /// 呼び出し側の `reveal()` 待ちにすると、それを書き忘れたプレイヤーで
    /// 操作系が永久に出したままになる（＝いちばん避けたい壊れ方）。
    init() {
        scheduleHide()
    }

    // MARK: - カーソル

    /// カーソルが動いた。出したうえで、引っ込めるまでの時計を測り直す。
    func reveal() {
        if !isActive {
            withAnimation(.easeOut(duration: 0.16)) { isActive = true }
        }
        scheduleHide()
    }

    /// カーソルがこの画面の外（別のスクリーンなど）へ出た。待たずに引っ込める。
    func pointerLeft() {
        scheduleHide(after: 0)
    }

    // MARK: - 事情の出し入れ

    func setHold(_ hold: Hold, _ isHeld: Bool) {
        var next = holds
        if isHeld { next.insert(hold) } else { next.remove(hold) }
        guard next != holds else { return }
        holds = next
        // 事情が立った瞬間は出す。消えた瞬間は、そこから時計を測り直す。
        if isHeld { reveal() } else { scheduleHide() }
    }

    // MARK: - 固定

    func togglePin() {
        isPinned.toggle()
        if isPinned {
            hideTask?.cancel()
            if !self.isActive {
                withAnimation(.easeOut(duration: 0.16)) { self.isActive = true }
            }
        } else {
            scheduleHide()
        }
    }

    // MARK: - 後始末

    func cancel() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func scheduleHide(after seconds: Double = autoHideSeconds) {
        hideTask?.cancel()
        guard !isPinned else { return }
        hideTask = Task { @MainActor [weak self] in
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            guard let self, !Task.isCancelled, !self.isPinned, self.holds.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.isActive = false }
            // 何も出ていない状態になったら、ポインタも引っ込める（次に動かせば戻る）。
            if !self.isShown { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }
}

extension View {
    /// カーソルの動きを `controller` へつなぐ。操作系を持つプレイヤーの一番外側に付ける。
    func playerChromeActivity(_ controller: PlayerChromeController) -> some View {
        contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active: controller.reveal()
                case .ended: controller.pointerLeft()
                }
            }
    }

    /// 操作系そのものに付ける。ポインタが乗っている間は引っ込めない。
    func playerChromeHoverGuard(_ controller: PlayerChromeController) -> some View {
        onHover { controller.setHold(.pointerOverControls, $0) }
    }
}
