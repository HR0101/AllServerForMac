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

/// 削除対象をタイトルではなくサムネイルで確認する共通シート。
/// 大量選択でも画面を埋めないよう，サムネイル領域だけをスクロールさせる。
struct MediaDeletionConfirmationSheet: View {
  let items: [VideoItem]
  let dataManager: LibraryViewModel
  let onMoveToAppTrash: (() -> Void)?
  let onDeleteCompletely: () -> Void
  let onMoveToSystemTrash: () -> Void

  @Environment(\.dismiss) private var dismiss

  private static let sheetWidth: CGFloat = 720
  private static let thumbnailMinimumSide: CGFloat = 104
  private static let thumbnailMaximumSide: CGFloat = 132
  private static let thumbnailSpacing: CGFloat = 10
  private static let thumbnailAreaMinimumHeight: CGFloat = 120
  private static let thumbnailAreaMaximumHeight: CGFloat = 390

  private var columns: [GridItem] {
    [
      GridItem(
        .adaptive(
          minimum: Self.thumbnailMinimumSide,
          maximum: Self.thumbnailMaximumSide
        ),
        spacing: Self.thumbnailSpacing
      )
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        Label("削除方法を選んでください", systemImage: "trash")
          .font(.title3.weight(.semibold))
        Spacer()
        Text("\(items.count)件を選択中")
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      Text("下のサムネイルが削除対象です．アプリ内のゴミ箱は復元できます．Macのゴミ箱へ移動すると，リンク元を含む実ファイルも移動します．")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      Divider()

      ScrollView {
        LazyVGrid(columns: columns, spacing: Self.thumbnailSpacing) {
          ForEach(items) { item in
            VStack(alignment: .leading, spacing: 6) {
              MacVideoThumbnailView(
                videoItem: item,
                dataManager: dataManager
              )
              .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark.circle.fill")
                  .font(.system(size: 17))
                  .symbolRenderingMode(.palette)
                  .foregroundStyle(.white, Color.red)
                  .padding(7)
              }

              Text(item.originalFilename)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel(item.originalFilename)
          }
        }
        .padding(4)
      }
      .frame(
        minHeight: Self.thumbnailAreaMinimumHeight,
        maxHeight: Self.thumbnailAreaMaximumHeight
      )

      Divider()

      HStack(spacing: 10) {
        Button("キャンセル", role: .cancel) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Spacer()

        if let onMoveToAppTrash {
          Button("アプリ内のゴミ箱へ") {
            perform(onMoveToAppTrash)
          }
        }

        Button("完全に削除", role: .destructive) {
          perform(onDeleteCompletely)
        }

        Button("実ファイルをMacのゴミ箱へ移動", role: .destructive) {
          perform(onMoveToSystemTrash)
        }
      }
    }
    .padding(20)
    .frame(width: Self.sheetWidth)
  }

  private func perform(_ action: () -> Void) {
    action()
    dismiss()
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
