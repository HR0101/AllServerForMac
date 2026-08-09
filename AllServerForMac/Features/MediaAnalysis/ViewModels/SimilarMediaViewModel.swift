import Combine
import Foundation

@MainActor
final class SimilarMediaViewModel: ObservableObject {
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

    func scan(items: [VideoItem], dataManager: LibraryViewModel) {
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
