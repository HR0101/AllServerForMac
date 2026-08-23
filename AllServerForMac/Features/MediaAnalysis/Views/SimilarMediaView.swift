import SwiftUI

// MARK: - 似ているメディアの検出と一括削除
//
// 「重複チェック」がファイルの中身の完全一致だけを見るのに対し、こちらは見た目の近さで探す。
// 書き出し直し・解像度違い・軽い加工違いなど、ファイルとしては別物になってしまうものが対象。
// 似ているだけで別物のこともあるので、必ずこの画面で目視してから消す。

struct SimilarMediaView: View {
    let items: [VideoItem]
    @ObservedObject var dataManager: LibraryViewModel
    var onFinish: () -> Void = {}

    @StateObject private var model = SimilarMediaViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false

    private let thumbnailSide: CGFloat = 116

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 1020, minHeight: 540, idealHeight: 700)
        .onAppear {
            model.configure { dataManager.fileMetadata(for: $0).size }
            model.scan(items: items, dataManager: dataManager)
        }
        .onDisappear { model.cancelScan() }
        .sheet(isPresented: $showDeleteConfirmation) {
            MediaDeletionConfirmationSheet(
                items: model.selectedItems,
                dataManager: dataManager,
                onMoveToAppTrash: {
                    apply { dataManager.moveToTrash(videoIDs: $0) }
                },
                onDeleteCompletely: {
                    apply { dataManager.deleteVideos(videoIDs: $0) }
                },
                onMoveToSystemTrash: {
                    apply { dataManager.moveMediaFilesToSystemTrash(videoIDs: $0) }
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("似ているメディアの整理", systemImage: "square.on.square.dashed")
                .font(.headline)
            Spacer()
            Button("閉じる") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            VStack(spacing: 14) {
                ProgressView(value: model.progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 260)
                Text("照合中… \(model.scannedCount) / \(model.totalCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("中止") { model.cancelScan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.groups.isEmpty {
            ContentUnavailableView(
                "似ているメディアはありません",
                systemImage: "checkmark.circle",
                description: Text("「似ている度合い」をゆるめると候補が増えます。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                        groupRow(group, at: index)
                    }
                }
                .padding(14)
            }
        }
    }

    private func groupRow(_ group: SimilarMediaViewModel.Group, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(group.items.count)件が似ています")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(group.items) { item in
                        candidateCell(item, group: group, groupIndex: index)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
    }

    private func candidateCell(_ item: VideoItem, group: SimilarMediaViewModel.Group, groupIndex: Int) -> some View {
        let isKept = group.keepID == item.id
        let isSelected = model.selectedIDs.contains(item.id)
        return VStack(spacing: 4) {
            MacVideoThumbnailView(videoItem: item, dataManager: dataManager)
                .frame(width: thumbnailSide, height: thumbnailSide)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isKept ? Color.green : (isSelected ? Color.red : Color.secondary.opacity(0.25)),
                            lineWidth: isKept || isSelected ? 3 : 1
                        )
                )
                .overlay(alignment: .bottomLeading) {
                    Text(isKept ? "残す" : (isSelected ? "削除" : "対象外"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(isKept ? Color.green : (isSelected ? Color.red : Color.gray)))
                        .padding(5)
                }
                .opacity(isSelected ? 1 : 0.75)
                .onTapGesture { model.toggle(item.id) }

            Button("これを残す") { model.setKeep(item.id, inGroupAt: groupIndex) }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(isKept ? Color.secondary : Color.accentColor)
                .disabled(isKept)

            Text(item.originalFilename)
                .font(.system(size: 9))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: thumbnailSide)
                .foregroundStyle(.secondary)
        }
        .help(item.originalFilename)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("似ている度合い")
                    .font(.caption)
                Slider(value: $model.maxDistance, in: 0...16, step: 1)
                    .frame(width: 200)
                Text("±\(Int(model.maxDistance))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .leading)
                Text("小さいほど「ほぼ同じ」だけに絞られます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 10) {
                Text("\(model.groups.count)グループ / \(model.selectedIDs.count)件を削除対象")
                    .font(.subheadline)
                if model.unreadableCount > 0 {
                    Text("照合できなかった項目: \(model.unreadableCount)件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("選択した\(model.selectedIDs.count)件を削除", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedIDs.isEmpty || model.isScanning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func apply(_ action: ([UUID]) -> Void) {
        let ids = model.selectedItems.map(\.id)
        guard !ids.isEmpty else { return }
        action(ids)
        onFinish()
        dismiss()
    }
}
