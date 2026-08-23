import Combine
import Foundation

@MainActor
final class VariantVideoViewModel: ObservableObject {
    struct Group: Identifiable {
        let id = UUID()
        var items: [VideoItem]
        /// この束の尺（束の中はどれもほぼ同じ）。
        var duration: TimeInterval
        /// 切り替え再生に持っていくもの。既定は全部。
        var selectedIDs: Set<UUID>

        var selectedItems: [VideoItem] { items.filter { selectedIDs.contains($0.id) } }
    }

    @Published private(set) var isScanning = false
    @Published private(set) var scannedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var groups: [Group] = []
    /// 尺は揃っていたのに指紋を作れなかった本数（フレームを起こせないファイル）。
    @Published private(set) var unreadableCount = 0

    /// 尺の一致とみなす幅（秒）。差分書き出しは同じタイムラインから出すのでフレーム単位で揃うが、
    /// 書き出し設定が違うと末尾が数フレームずれることがあるので、少しだけ余裕を持たせる。
    @Published var durationTolerance: Double = 0.2 {
        didSet { rescanIfIdle() }
    }

    /// 何ビットまでの平均差を「同じ映像の別バージョン」とみなすか（0〜64）。
    /// 実測では、衣装・状態だけが違うものは 2〜9、
    /// 同じ動きでもキャラが違えば 14〜19、まったく別の動画なら 26 以上に開く。
    /// 既定の 10 はその谷間に置いている。
    @Published var maxAverageDistance: Double = 10 {
        didSet { rebuildGroups() }
    }

    /// 指紋は尺のしきい値を変えても使い回せるので、項目ごとに取っておく。
    private var signatures: [UUID: VideoFrameSignature] = [:]
    private var buckets: [[VideoItem]] = []
    private var scanTask: Task<Void, Never>?
    private var lastScanInput: (items: [VideoItem], urls: [UUID: URL])?

    /// フレームの展開はデコーダ待ちが長いので何本か並べて回す。
    /// 4K を無制限に並べるとメモリが跳ねるため、控えめな本数で止める。
    private static let signatureConcurrency = 3

    var progress: Double {
        totalCount == 0 ? 0 : Double(scannedCount) / Double(totalCount)
    }

    var totalGroupedCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    func scan(items: [VideoItem], dataManager: LibraryViewModel) {
        guard !isScanning else { return }

        let videos = items.filter { $0.mediaType == .video && !$0.isInTrash }
        var urls: [UUID: URL] = [:]
        for video in videos {
            if let url = dataManager.fileURL(for: video) { urls[video.id] = url }
        }
        lastScanInput = (videos, urls)
        runScan()
    }

    private func rescanIfIdle() {
        guard !isScanning, lastScanInput != nil else { return }
        runScan()
    }

    private func runScan() {
        guard let input = lastScanInput else { return }
        scanTask?.cancel()

        // まず尺で束ねる。ここで大半が落ちるので、重いフレーム展開はごく一部で済む。
        buckets = VariantVideoDetector.durationBuckets(of: input.items, tolerance: durationTolerance)
        let pending = buckets.flatMap { $0 }.filter { signatures[$0.id] == nil }

        groups = []
        unreadableCount = 0
        scannedCount = 0
        totalCount = pending.count

        guard !pending.isEmpty else {
            rebuildGroups()
            return
        }

        isScanning = true
        scanTask = Task { @MainActor [weak self] in
            await self?.buildSignatures(for: pending, urls: input.urls)
            guard let self, !Task.isCancelled else { return }
            self.isScanning = false
            self.rebuildGroups()
        }
    }

    private func buildSignatures(for pending: [VideoItem], urls: [UUID: URL]) async {
        var index = 0
        while index < pending.count {
            if Task.isCancelled { return }
            let slice = pending[index..<min(index + Self.signatureConcurrency, pending.count)]
            index += slice.count

            let results = await withTaskGroup(of: (UUID, VideoFrameSignature?).self) { taskGroup in
                for item in slice {
                    guard let url = urls[item.id] else { continue }
                    let duration = item.duration
                    let id = item.id
                    taskGroup.addTask(priority: .utility) {
                        (id, await VariantFrameSampler.signature(forVideoAt: url, duration: duration))
                    }
                }
                var collected: [(UUID, VideoFrameSignature?)] = []
                for await result in taskGroup { collected.append(result) }
                return collected
            }

            if Task.isCancelled { return }
            for (id, signature) in results {
                if let signature { signatures[id] = signature } else { unreadableCount += 1 }
            }
            scannedCount = min(index, pending.count)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func toggle(_ id: UUID, inGroupAt index: Int) {
        guard groups.indices.contains(index) else { return }
        if groups[index].selectedIDs.contains(id) {
            groups[index].selectedIDs.remove(id)
        } else {
            groups[index].selectedIDs.insert(id)
        }
    }

    func selectAll(inGroupAt index: Int) {
        guard groups.indices.contains(index) else { return }
        groups[index].selectedIDs = Set(groups[index].items.map(\.id))
    }

    private func rebuildGroups() {
        // 選び直したものを、しきい値をいじっただけで捨てないように覚えておく。
        let previousSelections = Dictionary(
            groups.map { group in (Set(group.items.map(\.id)), group.selectedIDs) },
            uniquingKeysWith: { current, _ in current }
        )

        groups = buckets.flatMap { bucket in
            VariantVideoDetector.groups(
                in: bucket,
                signatures: signatures,
                maxAverageDistance: maxAverageDistance
            ).map { items -> Group in
                let ids = Set(items.map(\.id))
                return Group(
                    items: items,
                    duration: items.first?.duration ?? 0,
                    selectedIDs: previousSelections[ids] ?? ids
                )
            }
        }
        // 本数の多い束＝見比べがいのある束を上に。
        .sorted { $0.items.count > $1.items.count }
    }
}
