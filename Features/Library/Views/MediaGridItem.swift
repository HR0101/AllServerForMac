import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - メディアグリッドアイテム（ホバー/選択ハイライト付き）
struct MediaGridItem: View {
    let video: VideoItem
    let dataManager: LibraryViewModel
    let isSelected: Bool
    var showTitle: Bool = true
    var showImportDate: Bool = true
    let showRemoveFromAlbum: Bool
    let onSingleTap: (NSEvent.ModifierFlags) -> Void
    let onDoubleTap: () -> Void
    let onOpen: () -> Void
    let onOpenExternal: () -> Void
    let onReveal: () -> Void
    let onRemoveFromAlbum: () -> Void
    let onDelete: () -> Void
    var isTrashView: Bool = false
    var onToggleFavorite: () -> Void = {}
    var onMoveToTrash: () -> Void = {}
    var onRestore: () -> Void = {}
    var currentAlbumID: UUID? = nil
    var onMoveToAlbum: (UUID) -> Void = { _ in }
    var onMoveToNewAlbum: () -> Void = {}
    /// このセルのメニュー操作が実際に対象とする項目（表示順）。
    /// 複数選択中に右クリックすると選択全体が対象になるため、
    /// 確認文が「このセル1件」の話に見えないよう、対象の実態をここで受け取る。
    var affectedItems: [VideoItem] = []

    @State private var isHovering = false
    @State private var showDeleteConfirmation = false

    /// 削除確認の本文。対象が複数のときは件数と中身を並べて、
    /// 「1件だけ消えるつもりが選択全体だった」という取り違えを防ぐ。
    private var deleteConfirmationMessage: String {
        let targets = affectedItems.isEmpty ? [video] : affectedItems
        guard targets.count > 1 else {
            return isTrashView
                ? "「\(video.originalFilename)」を完全に削除します。この操作は取り消せません。"
                : "「\(video.originalFilename)」をゴミ箱に入れますか？それとも完全に削除しますか？"
        }
        let head = isTrashView
            ? "選択した\(targets.count)件を完全に削除します。この操作は取り消せません。"
            : "選択した\(targets.count)件をゴミ箱に入れますか？それとも完全に削除しますか？"
        return "\(head)\n\n\(SelectionSummary.text(for: targets))"
    }

    /// 移動先候補（システムアルバム・現在のアルバムを除き、メディアタイプが互換のもの）
    private var moveTargetAlbums: [Album] {
        dataManager.albums.filter { album in
            album.name != LibraryViewModel.allVideosAlbumName &&
            album.name != LibraryViewModel.allPhotosAlbumName &&
            album.id != currentAlbumID &&
            (album.type == .mixed
             || (video.mediaType == .video && album.type == .video)
             || (video.mediaType == .photo && album.type == .photo))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MacVideoThumbnailView(videoItem: video, dataManager: dataManager)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(7)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if video.mediaType == .video, video.duration > 0 {
                        Text(formatDuration(video.duration))
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.65)))
                            .padding(7)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // 常時は状態表示のみ（お気に入り済みならハート）。ホバー中は右クリック
                    // メニューを開かなくてもワンクリックでトグルできるボタンにする。
                    if isHovering && !isTrashView {
                        Button(action: onToggleFavorite) {
                            Image(systemName: video.isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                                .padding(7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(video.isFavorite ? "お気に入りから外す" : "お気に入りに追加")
                    } else if video.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .padding(7)
                    }
                }

            if showTitle || showImportDate {
                VStack(alignment: .leading, spacing: 2) {
                    if showTitle {
                        Text(video.originalFilename)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if showImportDate {
                        Text(MediaGridItem.itemFormatter.string(from: video.importDate))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(MediaGridLayout.itemInset)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.12)
                      : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            // アニメーション付きだとセルの出入りのたびにトランザクションが発生し、
            // 大量枚数のグリッドでスクロールがカクつく原因になるため即時反映にしている。
            isHovering = hovering
        }
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture(count: 1) {
            onSingleTap(NSApp.currentEvent?.modifierFlags ?? [])
        }
        .contextMenu {
            Button("開く") { onOpen() }
            Button("外部プレイヤーで開く") { onOpenExternal() }
            Button("Finderで表示") { onReveal() }
            Button("フォルダにエクスポート…") { exportThisItem() }
            Divider()
            if isTrashView {
                Button("元に戻す") { onRestore() }
                Button("完全に削除…", role: .destructive) { showDeleteConfirmation = true }
            } else {
                Button(video.isFavorite ? "お気に入りから外す" : "お気に入りに追加") { onToggleFavorite() }
                Menu("アルバムに移動") {
                    ForEach(moveTargetAlbums) { album in
                        Button(album.name) { onMoveToAlbum(album.id) }
                    }
                    if !moveTargetAlbums.isEmpty { Divider() }
                    Button("新規アルバム…") { onMoveToNewAlbum() }
                }
                if showRemoveFromAlbum {
                    Button("アルバムから外す") { onRemoveFromAlbum() }
                }
                Divider()
                Button("削除…", role: .destructive) { showDeleteConfirmation = true }
            }
        }
        // 削除は必ず「ゴミ箱に入れる」か「完全に削除」かを確認してから実行する
        // （元ファイルの誤削除を繰り返さないための安全策）。
        .confirmationDialog(
            isTrashView ? "完全に削除しますか？" : "削除方法を選んでください",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if !isTrashView {
                Button("ゴミ箱に入れる") { onMoveToTrash() }
            }
            Button("完全に削除", role: .destructive) { onDelete() }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    /// この1件を選んだフォルダへコピーとして書き出す（元ファイルを万一失っても手元にコピーが残る安全弁）。
    private func exportThisItem() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "書き出し先のフォルダを選択してください"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        Task { await dataManager.exportMedia(videoIDs: [video.id], to: folderURL) }
    }

    private static let itemFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private func formatDuration(_ totalSeconds: TimeInterval) -> String {
        let secondsInt = Int(totalSeconds)
        return String(format: "%02d:%02d", secondsInt / 60, secondsInt % 60)
    }
}
