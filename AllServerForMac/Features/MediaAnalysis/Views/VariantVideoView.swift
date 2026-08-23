import AppKit
import SwiftUI

// MARK: - 差分動画を探して切り替え再生へ渡す
//
// 「似ているものを探す」が消す候補を挙げる画面なのに対し、こちらは残すのが前提。
// 同じ尺・同じ動きで絵だけが違うものを束にして見せ、選んだぶんを差分切り替え再生へ送る。

struct VariantVideoView: View {
    let items: [VideoItem]
    @ObservedObject var dataManager: LibraryViewModel
    /// 開いた時点の親ウィンドウの大きさ。ここへ合わせて開く。
    var hostWindowSize: CGSize?
    /// sheet ではなく ContentView のオーバーレイとして表示するため、閉じ方は呼び出し側へ任せる。
    var onClose: () -> Void

    /// 探索結果は `AppViewModel` が持つ。プレイヤーはこの画面の上へ重なり、
    /// 見つけたグループと選んだ組み合わせもこの View ごとそのまま残る。
    @EnvironmentObject private var model: VariantVideoViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator

    /// サムネイルの一辺。広いウィンドウでは大きく見たいので、その場で変えられるようにする。
    @AppStorage("variantFinder.thumbnailSide") private var thumbnailSide: Double = 168
    /// 同時にデコードし続けられる本数の上限（`PlaybackCoordinator.playVariantSwitch` と揃える）。
    private let maxPlayableCount = 9

    /// 親ウィンドウをほぼ埋めるオーバーレイの大きさ。
    private var overlaySize: CGSize {
        let host = hostWindowSize ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: max(960, host.width - 56), height: max(640, host.height - 56))
    }

    /// グループの札を横に並べる。縦一列に積むと、ウィンドウを広げても右側が余るだけになる
    /// （1グループはたいてい数本なので、1行ぶんの幅しか使わない）。
    /// 札1枚にタイルが2〜3個入る幅を下限にして、広ければ札の数を増やす。
    private var groupColumns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbnailSide * 2.3 + 48), spacing: 14, alignment: .top)]
    }

    /// 札の中でタイルを敷き詰める。`maximum` に幅を持たせておくと、
    /// 割り切れないぶんをタイル側が吸ってくれて右端に隙間が残らない。
    private var tileColumns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbnailSide, maximum: thumbnailSide * 1.45), spacing: 10, alignment: .top)]
    }

    var body: some View {
        finder
            .frame(
                minWidth: overlaySize.width, idealWidth: overlaySize.width,
                minHeight: overlaySize.height, idealHeight: overlaySize.height
            )
    }

    private var finder: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.scan(items: items, dataManager: dataManager) }
        .onDisappear { model.cancelScan() }
        // 再生中もこの View は背後に残るので onAppear は再度呼ばれない。
        // プレイヤーを閉じた時点で、中断した照合と削除後の顔ぶれ確認を再開する。
        .onChange(of: coordinator.mode) { oldMode, newMode in
            guard oldMode != nil, newMode == nil else { return }
            model.scan(items: items, dataManager: dataManager)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("差分動画を探す", systemImage: "rectangle.on.rectangle.angled")
                .font(.headline)
            Text("尺が揃っていて、絵だけが違うものを束にします")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.rescan()
            } label: {
                Label("探し直す", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning)
            .help("取り込み直したファイルを拾わせたいときに、フレームの照合をやり直します")
            Button("閉じる") { onClose() }
                // 背後の View に付いたショートカットもプレイヤー越しに反応するため、
                // 再生中は外して Esc が探索画面まで閉じないようにする。
                .keyboardShortcut(coordinator.isPlayingOverVariantFinder ? nil : .cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        // 前回の指紋が残っていれば走査中でも先に一覧が出る。待たずに再生へ進めるようにする。
        if model.isScanning && model.groups.isEmpty {
            VStack(spacing: 14) {
                ProgressView(value: model.progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 260)
                Text("フレームを照合中… \(model.scannedCount) / \(model.totalCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(model.reusedCount > 0
                     ? "\(model.reusedCount)件は前回の結果をそのまま使っています"
                     : "尺が揃った動画だけを対象にしています")
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
            VStack(spacing: 0) {
                if model.isScanning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("残り \(max(0, model.totalCount - model.scannedCount))件を照合中… 見つかったぶんは先に選べます")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("中止") { model.cancelScan() }
                            .font(.caption)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.25))
                }
                ScrollView {
                    LazyVGrid(columns: groupColumns, alignment: .leading, spacing: 14) {
                        ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                            groupRow(group, at: index)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    /// グループ1つぶんの札。横に並べるので、見出しを1行に詰め込まず縦に組む。
    private func groupRow(_ group: VariantVideoViewModel.Group, at index: Int) -> some View {
        let selectedCount = group.selectedIDs.count
        let isPlayable = (2...maxPlayableCount).contains(selectedCount)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(group.items.count)本の差分 ・ \(formatDuration(group.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("すべて選ぶ") { model.selectAll(inGroupAt: index) }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(selectedCount == group.items.count)
            }

            if let stats = group.stats {
                Text(evidenceText(stats))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .help("絵の差はフレームどうしのハミング距離（小さいほど似ている）、名前の近さは 0〜1。名前の近さはしきい値を上下させる補助に使っています")
            }

            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: 10) {
                ForEach(group.items) { item in
                    candidateCell(item, group: group, groupIndex: index)
                }
            }

            Button {
                play(group.selectedItems)
            } label: {
                Label("切り替え再生（\(selectedCount)本）", systemImage: "rectangle.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!isPlayable)
            .help(isPlayable
                  ? "選んだ差分を同期再生し、一定間隔／キー操作で切り替えます"
                  : "2〜\(maxPlayableCount)本を選んでください")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
    }

    private func candidateCell(_ item: VideoItem, group: VariantVideoViewModel.Group, groupIndex: Int) -> some View {
        let isSelected = group.selectedIDs.contains(item.id)
        return VStack(spacing: 5) {
            MacVideoThumbnailView(videoItem: item, dataManager: dataManager)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
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
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
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

                Spacer()
            }

            HStack(spacing: 10) {
                Text("タイトルの効き")
                    .font(.caption)
                Slider(value: $model.titleInfluence, in: 0...8, step: 1)
                    .frame(width: 150)
                Text("±\(Int(model.titleInfluence))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 34, alignment: .leading)
                Text(titleInfluenceHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 10) {
                Text("サムネイル")
                    .font(.caption)
                Slider(value: $thumbnailSide, in: 110...320, step: 2)
                    .frame(width: 150)
                Text("\(Int(thumbnailSide))px")
                    .font(.caption.monospacedDigit())
                    .frame(width: 46, alignment: .leading)

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

    /// 名前が近いほど「似ている度合い」を何点ぶん甘く見るか、を実際の数字で見せる。
    private var titleInfluenceHint: String {
        guard model.titleInfluence > 0 else {
            return "0 ならファイル名を見ず、絵だけで判定します"
        }
        let loose = VariantVideoDetector.effectiveThreshold(
            base: model.maxAverageDistance, titleSimilarity: 1, influence: model.titleInfluence)
        let tight = VariantVideoDetector.effectiveThreshold(
            base: model.maxAverageDistance, titleSimilarity: 0, influence: model.titleInfluence)
        return String(format: "名前がそっくりなら %.0f まで、まるで違えば %.0f までに絞ります", loose, tight)
    }

    private func evidenceText(_ stats: VariantVideoDetector.GroupStats) -> String {
        String(
            format: "絵の差 %.1f〜%.1f ・ 名前の近さ %.2f〜%.2f",
            stats.frameDistance.lowerBound, stats.frameDistance.upperBound,
            stats.titleSimilarity.lowerBound, stats.titleSimilarity.upperBound
        )
    }

    private func play(_ videos: [VideoItem]) {
        guard videos.count >= 2 else { return }
        // フレームの展開は重いので、再生している間は止める。
        // 途中まで作った指紋は残るため、閉じたときに続きから進む。
        model.cancelScan()
        coordinator.playVariantSwitch(videos)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
