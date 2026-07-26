import Combine
import SwiftUI

// MARK: - 似ているメディアの検出と一括削除
//
// 「重複チェック」がファイルの中身の完全一致だけを見るのに対し、こちらは見た目の近さで探す。
// 書き出し直し・解像度違い・軽い加工違いなど、ファイルとしては別物になってしまうものが対象。
// 似ているだけで別物のこともあるので、必ずこの画面で目視してから消す。

@MainActor
final class SimilarMediaModel: ObservableObject {
    struct Group: Identifiable {
        let id = UUID()
        var items: [VideoItem]
        /// 残す1件。既定ではファイルサイズが最大のもの（＝いちばん劣化していない可能性が高い）。
        var keepID: UUID
    }

    @Published private(set) var isScanning = false
    @Published private(set) var scannedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var groups: [Group] = []
    @Published private(set) var unreadableCount = 0
    /// 消す対象。既定では各グループの「残す1件」以外すべて。
    @Published var selectedIDs = Set<UUID>()

    /// 何ビットまでの違いを「似ている」とみなすか。dHash は 64 ビット。
    /// 縮小・低画質での再書き出し・明るさ違いは距離 0〜1 に収まる一方、
    /// 別物どうしでも構図が単純だと 7 程度まで近づくため、既定はその手前に置く。
    @Published var maxDistance: Double = 5 {
        didSet { rebuildGroups() }
    }

    private var hashes: [(id: UUID, hash: PerceptualHash)] = []
    private var itemsByID: [UUID: VideoItem] = [:]
    private var scanTask: Task<Void, Never>?

    var progress: Double {
        totalCount == 0 ? 0 : Double(scannedCount) / Double(totalCount)
    }

    var selectedItems: [VideoItem] {
        groups.flatMap { $0.items }.filter { selectedIDs.contains($0.id) }
    }

    func scan(items: [VideoItem], dataManager: VideoDataManager) {
        guard !isScanning else { return }

        // 画像はファイルそのもの、動画は生成済みサムネイルを見る。
        // 動画から毎回フレームを起こすのは高くつくうえ、一覧で見えている絵と judgement がずれる。
        let targets: [(VideoItem, URL)] = items.compactMap { item in
            switch item.mediaType {
            case .photo:
                guard let url = dataManager.fileURL(for: item) else { return nil }
                return (item, url)
            default:
                let thumbnail = dataManager.thumbnailStorageURL
                    .appendingPathComponent(item.id.uuidString)
                    .appendingPathExtension("jpg")
                guard FileManager.default.fileExists(atPath: thumbnail.path) else { return nil }
                return (item, thumbnail)
            }
        }

        isScanning = true
        scannedCount = 0
        totalCount = targets.count
        groups = []
        selectedIDs = []
        hashes = []
        unreadableCount = items.count - targets.count
        itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })

        scanTask = Task { @MainActor in
            var collected: [(id: UUID, hash: PerceptualHash)] = []
            let progressStride = max(1, targets.count / 100)

            for (offset, entry) in targets.enumerated() {
                if Task.isCancelled { break }
                let url = entry.1
                let hash = await Task.detached(priority: .utility) {
                    PerceptualHasher.hash(forImageAt: url)
                }.value

                if let hash {
                    collected.append((entry.0.id, hash))
                } else {
                    unreadableCount += 1
                }
                if offset % progressStride == 0 { scannedCount = offset + 1 }
            }

            scannedCount = targets.count
            hashes = collected
            rebuildGroups()
            isScanning = false
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    /// 残す1件を選び直す。選び直したものは消す対象から外し、代わりに元の1件を対象に入れる。
    func setKeep(_ id: UUID, inGroupAt index: Int) {
        guard groups.indices.contains(index) else { return }
        groups[index].keepID = id
        for item in groups[index].items {
            if item.id == id { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
        }
    }

    func toggle(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func rebuildGroups() {
        let grouped = SimilarityGrouping.groups(of: hashes, maxDistance: Int(maxDistance))
        groups = grouped.compactMap { ids in
            let items = ids.compactMap { itemsByID[$0] }
            guard items.count > 1 else { return nil }
            // いちばんファイルサイズが大きいものを既定の「残す1件」にする。
            let keep = items.max { fileSize(of: $0) < fileSize(of: $1) } ?? items[0]
            return Group(items: items, keepID: keep.id)
        }
        selectedIDs = Set(groups.flatMap { group in
            group.items.map(\.id).filter { $0 != group.keepID }
        })
    }

    /// 並べ替えでも使っているキャッシュ済みの属性を読む（ここでの stat 追加は起きない）。
    private var fileSizeProvider: ((VideoItem) -> Int64)?

    func configure(fileSizeProvider: @escaping (VideoItem) -> Int64) {
        self.fileSizeProvider = fileSizeProvider
    }

    private func fileSize(of item: VideoItem) -> Int64 {
        fileSizeProvider?(item) ?? 0
    }
}

struct SimilarMediaView: View {
    let items: [VideoItem]
    @ObservedObject var dataManager: VideoDataManager
    var onFinish: () -> Void = {}

    @StateObject private var model = SimilarMediaModel()
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
        .confirmationDialog(
            "削除方法を選んでください",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("ゴミ箱に入れる") { apply { dataManager.moveToTrash(videoIDs: $0) } }
            Button("完全に削除", role: .destructive) { apply { dataManager.deleteVideos(videoIDs: $0) } }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("選択した\(model.selectedIDs.count)件をゴミ箱に入れますか？それとも完全に削除しますか？この操作は元に戻せません（完全に削除の場合）。\n\n\(SelectionSummary.text(for: model.selectedItems))")
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

    private func groupRow(_ group: SimilarMediaModel.Group, at index: Int) -> some View {
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

    private func candidateCell(_ item: VideoItem, group: SimilarMediaModel.Group, groupIndex: Int) -> some View {
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
