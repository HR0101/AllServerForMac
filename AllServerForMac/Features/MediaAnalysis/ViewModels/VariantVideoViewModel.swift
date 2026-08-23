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
        /// 何を根拠にまとまったのか（画面に出して、しきい値の調整の手がかりにする）。
        var stats: VariantVideoDetector.GroupStats?

        var selectedItems: [VideoItem] { items.filter { selectedIDs.contains($0.id) } }
    }

    @Published private(set) var isScanning = false
    @Published private(set) var scannedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var groups: [Group] = []
    /// 尺は揃っていたのに指紋を作れなかった本数（フレームを起こせないファイル）。
    @Published private(set) var unreadableCount = 0
    /// 前回までに作った指紋をそのまま使えた本数（＝フレームを起こし直さずに済んだ本数）。
    @Published private(set) var reusedCount = 0

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

    /// ファイル名の近さでフレームのしきい値をどれだけ上下させるか（0 なら名前を見ない）。
    /// 名前は「無関係かどうか」はよく言い当てるが「別キャラかどうか」は言い当てられないので、
    /// 実測のフレーム距離の隔たり（差分 2〜9 / 別キャラ 14〜19）を名前だけで埋められない
    /// 大きさに既定を置いている。詳しくは `TitleSimilarity`。
    @Published var titleInfluence: Double = 4 {
        didSet { rebuildGroups() }
    }

    /// 指紋は尺のしきい値を変えても使い回せるので、項目ごとに取っておく。
    private var fingerprints: [UUID: VariantVideoDetector.Fingerprint] = [:]
    private var buckets: [[VideoItem]] = []
    private var scanTask: Task<Void, Never>?
    private var lastScanInput: ScanInput?
    /// 最後まで探し終えた顔ぶれ。同じものを渡されたら結果をそのまま見せる。
    /// 途中で中止したときは埋めないので、次に開いたときに続きから進む。
    private var completedScanKey: [UUID]?
    /// 前回までに作った指紋の保存先。画面を閉じて再生して戻ってきても作り直さずに済ませる。
    private var signatureStore: VariantSignatureStore?

    private struct ScanInput {
        var items: [VideoItem]
        var urls: [UUID: URL]
        /// 保存してある指紋がまだそのファイルのものか確かめるための印。
        var stamps: [UUID: VariantSignatureStore.Stamp]
    }

    /// フレームの展開はデコーダ待ちが長いので何本か並べて回す。
    /// 4K を無制限に並べるとメモリが跳ねるため、控えめな本数で止める。
    private static let signatureConcurrency = 3

    var progress: Double {
        totalCount == 0 ? 0 : Double(scannedCount) / Double(totalCount)
    }

    var totalGroupedCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    /// 探索の入口。すでに同じ顔ぶれを探し終えていれば何もしない。
    ///
    /// 再生に入るとライブラリ画面ごと差し替わり、戻ってきたときにこの画面は作り直される。
    /// そのたびに探し直すと、選び直した組み合わせまで消えてしまう。
    func scan(items: [VideoItem], dataManager: LibraryViewModel) {
        guard !isScanning else { return }

        let videos = items.filter { $0.mediaType == .video && !$0.isInTrash }
        if completedScanKey == videos.map(\.id) { return }
        var urls: [UUID: URL] = [:]
        var stamps: [UUID: VariantSignatureStore.Stamp] = [:]
        for video in videos {
            guard let url = dataManager.fileURL(for: video) else { continue }
            urls[video.id] = url
            // すでにキャッシュ済みの属性なので、ここで stat が増えることはない。
            let metadata = dataManager.fileMetadata(for: video)
            stamps[video.id] = VariantSignatureStore.Stamp(
                size: metadata.size,
                modified: metadata.modificationDate
            )
        }
        if signatureStore == nil {
            signatureStore = VariantSignatureStore(directory: dataManager.appRootURL)
        }
        lastScanInput = ScanInput(items: videos, urls: urls, stamps: stamps)
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
        let bucketMembers = buckets.flatMap { $0 }

        // ここで groups を空にしない。指紋がキャッシュに残っていれば直後に組み直せるので、
        // 空にすると「進捗画面が一瞬出て、すぐ一覧に戻る」というちらつきになるだけ。
        unreadableCount = 0
        reusedCount = 0
        scannedCount = 0
        totalCount = 0

        isScanning = true
        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // ディスクに残っている指紋を先に拾う。ここで足りれば、
            // 画面を開き直しても待ち時間なしで一覧が出る。
            let missing = await self.reuseStoredSignatures(for: bucketMembers, input: input)
            if Task.isCancelled { return }
            // 拾えたぶんだけで一度組み上げて見せる（残りは後から足りていく）。
            self.rebuildGroups()

            self.totalCount = missing.count
            if !missing.isEmpty {
                await self.buildSignatures(for: missing, input: input)
            }
            guard !Task.isCancelled else { return }
            self.isScanning = false
            self.rebuildGroups()
            self.completedScanKey = input.items.map(\.id)
            await self.signatureStore?.save()
        }
    }

    /// 保存してある指紋のうち使えるものを取り込み、作り直しが要るものだけを返す。
    private func reuseStoredSignatures(
        for members: [VideoItem],
        input: ScanInput
    ) async -> [VideoItem] {
        var missing: [VideoItem] = []
        for item in members {
            if fingerprints[item.id] != nil { continue }
            guard let store = signatureStore, let stamp = input.stamps[item.id] else {
                missing.append(item)
                continue
            }
            if let signature = await store.signature(for: item.id, stamp: stamp) {
                fingerprints[item.id] = VariantVideoDetector.Fingerprint(
                    signature: signature,
                    filename: item.originalFilename
                )
                reusedCount += 1
            } else {
                missing.append(item)
            }
        }
        return missing
    }

    private func buildSignatures(for pending: [VideoItem], input: ScanInput) async {
        var index = 0
        while index < pending.count {
            if Task.isCancelled { return }
            let slice = pending[index..<min(index + Self.signatureConcurrency, pending.count)]
            index += slice.count

            let results = await withTaskGroup(of: (UUID, VideoFrameSignature?).self) { taskGroup in
                for item in slice {
                    guard let url = input.urls[item.id] else { continue }
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
            let filenames = Dictionary(slice.map { ($0.id, $0.originalFilename) },
                                       uniquingKeysWith: { current, _ in current })
            for (id, signature) in results {
                if let signature, let filename = filenames[id] {
                    fingerprints[id] = VariantVideoDetector.Fingerprint(signature: signature, filename: filename)
                    // 次にこの画面を開いたときに作り直さなくて済むよう、その場で控える。
                    if let stamp = input.stamps[id] {
                        await signatureStore?.store(signature, for: id, stamp: stamp)
                    }
                } else {
                    unreadableCount += 1
                }
            }
            scannedCount = min(index, pending.count)
            // 途中でも見えているぶんから触れるようにする（全部そろうまで待たせない）。
            rebuildGroups()
        }
    }

    /// 「探し直す」ボタン用。取り込み直したファイルを拾わせたいときに使う。
    func rescan() {
        guard !isScanning, lastScanInput != nil else { return }
        completedScanKey = nil
        runScan()
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        // 途中まで作った指紋も次回のために残す。
        if let store = signatureStore {
            Task { await store.save() }
        }
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
                fingerprints: fingerprints,
                maxAverageDistance: maxAverageDistance,
                titleInfluence: titleInfluence
            ).map { items -> Group in
                let ids = Set(items.map(\.id))
                return Group(
                    items: items,
                    duration: items.first?.duration ?? 0,
                    selectedIDs: previousSelections[ids] ?? ids,
                    stats: VariantVideoDetector.stats(for: items, fingerprints: fingerprints)
                )
            }
        }
        // 本数の多い束＝見比べがいのある束を上に。
        .sorted { $0.items.count > $1.items.count }
    }
}
