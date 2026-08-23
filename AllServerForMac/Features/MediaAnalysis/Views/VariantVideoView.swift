import SwiftUI

// MARK: - 差分動画を探して切り替え再生へ渡す
//
// 「似ているものを探す」が消す候補を挙げる画面なのに対し、こちらは残すのが前提。
// 同じ尺・同じ動きで絵だけが違うものを束にして見せ、選んだぶんを差分切り替え再生へ送る。

struct VariantVideoView: View {
    let items: [VideoItem]
    @ObservedObject var dataManager: LibraryViewModel
    /// 選んだ差分を再生する。シートを閉じたあとに呼ばれる。
    var onPlay: ([VideoItem]) -> Void

    @StateObject private var model = VariantVideoViewModel()
    @Environment(\.dismiss) private var dismiss

    private let thumbnailSide: CGFloat = 116
    /// 同時にデコードし続けられる本数の上限（`PlaybackCoordinator.playVariantSwitch` と揃える）。
    private let maxPlayableCount = 9

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 860, idealWidth: 1040, minHeight: 560, idealHeight: 720)
        .onAppear { model.scan(items: items, dataManager: dataManager) }
        .onDisappear { model.cancelScan() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("差分動画を探す", systemImage: "rectangle.on.rectangle.angled")
                .font(.headline)
            Text("尺が揃っていて、絵だけが違うものを束にします")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Text("フレームを照合中… \(model.scannedCount) / \(model.totalCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("尺が揃った動画だけを対象にしています")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("中止") { model.cancelScan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.groups.isEmpty {
            ContentUnavailableView(
                "差分動画は見つかりませんでした",
                systemImage: "rectangle.on.rectangle.slash",
                description: Text("差分は「尺がほぼ同じ」ことが手がかりです。尺の許容差か似ている度合いをゆるめると候補が増えます。")
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

    private func groupRow(_ group: VariantVideoViewModel.Group, at index: Int) -> some View {
        let selectedCount = group.selectedIDs.count
        let isPlayable = (2...maxPlayableCount).contains(selectedCount)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(group.items.count)本の差分 ・ \(formatDuration(group.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("すべて選ぶ") { model.selectAll(inGroupAt: index) }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(selectedCount == group.items.count)
                Button {
                    play(group.selectedItems)
                } label: {
                    Label("切り替え再生（\(selectedCount)本）", systemImage: "rectangle.on.rectangle.angled")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isPlayable)
                .help(isPlayable
                      ? "選んだ差分を同期再生し、一定間隔／キー操作で切り替えます"
                      : "2〜\(maxPlayableCount)本を選んでください")
            }

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

    private func candidateCell(_ item: VideoItem, group: VariantVideoViewModel.Group, groupIndex: Int) -> some View {
        let isSelected = group.selectedIDs.contains(item.id)
        return VStack(spacing: 4) {
            MacVideoThumbnailView(videoItem: item, dataManager: dataManager)
                .frame(width: thumbnailSide, height: thumbnailSide)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                            lineWidth: isSelected ? 3 : 1
                        )
                )
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.4))
                        .padding(6)
                }
                .opacity(isSelected ? 1 : 0.6)
                .onTapGesture { model.toggle(item.id, inGroupAt: groupIndex) }

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
                Text("尺の許容差")
                    .font(.caption)
                Slider(value: $model.durationTolerance, in: 0...2, step: 0.05)
                    .frame(width: 150)
                Text(String(format: "±%.2f秒", model.durationTolerance))
                    .font(.caption.monospacedDigit())
                    .frame(width: 62, alignment: .leading)

                Text("似ている度合い")
                    .font(.caption)
                Slider(value: $model.maxAverageDistance, in: 2...20, step: 1)
                    .frame(width: 150)
                Text("±\(Int(model.maxAverageDistance))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 34, alignment: .leading)

                Text("大きくすると、同じ動きでも別キャラの動画まで混ざります")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 10) {
                Text("\(model.groups.count)グループ / \(model.totalGroupedCount)本")
                    .font(.subheadline)
                if model.unreadableCount > 0 {
                    Text("フレームを読めなかった項目: \(model.unreadableCount)件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func play(_ videos: [VideoItem]) {
        guard videos.count >= 2 else { return }
        dismiss()
        onPlay(videos)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
