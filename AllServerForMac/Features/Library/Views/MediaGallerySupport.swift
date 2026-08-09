import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// サムネイル一覧の余白。密度を高めつつ，選択枠とホバー状態を見分けられる最小限の間隔を保つ。
enum MediaGridLayout {
    static let spacing: CGFloat = 3
    static let itemInset: CGFloat = 1
    static let contentInset: CGFloat = 5
}

/// 一覧グリッドの矢印キー移動。アルバム詳細とお気に入り/ゴミ箱の両方、
/// さらにクイックルック表示中の送りも同じ計算を使う。
enum MediaGridNavigation {
    static func direction(for press: KeyPress) -> QuickLookPreviewController.NavigationDirection? {
        if MediaShortcutSettings.matches(.libraryMoveUp, press: press) { return .up }
        if MediaShortcutSettings.matches(.libraryMoveDown, press: press) { return .down }
        if MediaShortcutSettings.matches(.libraryMoveLeft, press: press) { return .left }
        if MediaShortcutSettings.matches(.libraryMoveRight, press: press) { return .right }
        return nil
    }

    /// 移動先の添字。端で動けないときは nil。
    static func nextIndex(
        from index: Int,
        direction: QuickLookPreviewController.NavigationDirection,
        columnCount: Int,
        itemCount: Int
    ) -> Int? {
        let next: Int
        switch direction {
        case .up: next = index - columnCount
        case .down: next = index + columnCount
        case .left: next = index - 1
        case .right: next = index + 1
        }
        return (0..<itemCount).contains(next) ? next : nil
    }
}

/// 削除の確認などで「どれを選んだのか」を小さく添えるための一覧文。
///
/// 件数だけだと、選んだつもりのものと実際の選択がずれていても気づけない。
/// かといって全部並べるとダイアログが画面を埋めるので、先頭数件だけ出して残りは件数でまとめる。
enum SelectionSummary {
    /// 名前を並べる上限。これを超えたぶんは「ほか◯件」に畳む。
    private static let maxListedNames = 8
    /// 1行の長さの上限。超えたら真ん中を省略する。
    private static let maxNameLength = 44

    /// `items` は表示順で渡すこと（画面で見えている並びと一致していないと確認の役に立たない）。
    static func text(for items: [VideoItem]) -> String {
        guard !items.isEmpty else { return "" }
        var lines = items.prefix(maxListedNames).map { "・" + shortened($0.originalFilename) }
        let remainder = items.count - lines.count
        if remainder > 0 {
            lines.append("・ほか\(remainder)件")
        }
        return lines.joined(separator: "\n")
    }

    /// 長い名前は真ん中を省略する。末尾には連番や拡張子が来ることが多く、
    /// 先頭だけ残すより見分けがつきやすい。
    private static func shortened(_ name: String) -> String {
        guard name.count > maxNameLength else { return name }
        let sideLength = maxNameLength / 2 - 1
        return "\(name.prefix(sideLength))…\(name.suffix(sideLength))"
    }
}

/// インポート進捗の @State 更新を間引くカウンタ。
/// 1件ごとに @State を更新すると、その回数だけビュー全体（displayedItems の全件
/// フィルタ+ソート含む）が再評価され、せっかくの一括反映最適化を打ち消してしまう。
/// 表示は25件刻みで十分なので、まとめて反映する。
@MainActor
final class ImportProgressThrottle {
    private(set) var count = 0
    private let onUpdate: (Int) -> Void

    init(onUpdate: @escaping (Int) -> Void) {
        self.onUpdate = onUpdate
    }

    func tick() {
        count += 1
        if count % 25 == 0 { onUpdate(count) }
    }

    func finish() {
        onUpdate(count)
    }
}
