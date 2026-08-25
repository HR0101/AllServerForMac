import Combine
import Foundation

private struct VariantPartialMatchInput: Sendable {
    let id: UUID
    let duration: TimeInterval
    let signature: [PerceptualHash]
}

private struct VariantPartialMatchRecord: Sendable {
    let firstID: UUID
    let secondID: UUID
    let sharedDuration: TimeInterval
    let score: Double
}

@MainActor
final class VariantVideoViewModel: ObservableObject {
    enum ScanPhase: Equatable {
        case idle
        case extractingFrames
        case comparingCandidates
    }

    enum SearchMode: String, CaseIterable, Identifiable {
        case normal
        case partial

        var id: Self { self }
    }

    struct Group: Identifiable {
        let id = UUID()
        var items: [VideoItem]
        /// この束の尺（束の中はどれもほぼ同じ）。
        var duration: TimeInterval
        /// 切り替え再生に持っていくもの。既定は全部。
        var selectedIDs: Set<UUID>
        /// 何を根拠にまとまったのか（画面に出して、しきい値の調整の手がかりにする）。
        var stats: VariantVideoDetector.GroupStats?
        /// 強制差分候補では，動画内で一致した区間の長さを表示する．
        var sharedDuration: TimeInterval? = nil
        /// 強制差分候補の照合スコア．小さいほど映像が近い．
        var partialMatchScore: Double? = nil
        /// 候補をどちらの位置合わせ方式で再生するか．
        var alignmentMode: VariantPlaybackAlignmentMode = .sameTime

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
    @Published private(set) var searchMode: SearchMode = .normal
    @Published private(set) var scanPhase: ScanPhase = .idle
    @Published private(set) var comparedPairCount = 0
    @Published private(set) var totalPairCount = 0

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

    /// 強制差分候補として扱う最小の尺差．通常差分と同じ動画を重複表示しないために使う．
    @Published var minimumPartialDurationDifference: Double = 5 {
        didSet {
            guard !isScanning else { return }
            rebuildGroups()
        }
    }

    /// 指紋は尺のしきい値を変えても使い回せるので、項目ごとに取っておく。
    private var fingerprints: [UUID: VariantVideoDetector.Fingerprint] = [:]
    /// 強制差分候補用の，動画全体を2秒間隔で読んだ時間列指紋．
    private var partialSignatures: [UUID: [PerceptualHash]] = [:]
    private var buckets: [[VideoItem]] = []
    private var scanTask: Task<Void, Never>?
    private var partialMatchTask: Task<Void, Never>?
    private var lastScanInput: ScanInput?
    /// 最後まで探し終えた顔ぶれ。同じものを渡されたら結果をそのまま見せる。
    /// 途中で中止したときは埋めないので、次に開いたときに続きから進む。
    private var completedScanKeys: [SearchMode: [UUID]] = [:]
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
        switch scanPhase {
        case .idle:
            return 0
        case .extractingFrames:
            return totalCount == 0 ? 0 : Double(scannedCount) / Double(totalCount)
        case .comparingCandidates:
            return totalPairCount == 0
                ? 0
                : Double(comparedPairCount) / Double(totalPairCount)
        }
    }

    var totalGroupedCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    /// 探索の入口。すでに同じ顔ぶれを探し終えていれば何もしない。
    ///
    /// 再生に入るとライブラリ画面ごと差し替わり、戻ってきたときにこの画面は作り直される。
    /// そのたびに探し直すと、選び直した組み合わせまで消えてしまう。
    func scan(
        items: [VideoItem],
        dataManager: LibraryViewModel,
        initialSearchMode: SearchMode? = nil
    ) {
        if let initialSearchMode, initialSearchMode != searchMode {
            scanTask?.cancel()
            partialMatchTask?.cancel()
            scanTask = nil
            partialMatchTask = nil
            isScanning = false
            scanPhase = .idle
            searchMode = initialSearchMode
            groups = []
        }
        guard !isScanning else { return }

        let videos = items.filter { $0.mediaType == .video && !$0.isInTrash }
        if completedScanKeys[searchMode] == videos.map(\.id) {
            rebuildGroups()
            return
        }
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

    func setSearchMode(_ mode: SearchMode) {
        guard searchMode != mode else { return }
        scanTask?.cancel()
        partialMatchTask?.cancel()
        scanTask = nil
        partialMatchTask = nil
        isScanning = false
        scanPhase = .idle
        searchMode = mode
        groups = []
        guard let input = lastScanInput else { return }
        if completedScanKeys[mode] == input.items.map(\.id) {
            rebuildGroups()
        } else {
            runScan()
        }
    }

    private func rescanIfIdle() {
        guard !isScanning, lastScanInput != nil else { return }
        runScan()
    }

    private func runScan() {
        guard let input = lastScanInput else { return }
        scanTask?.cancel()
        partialMatchTask?.cancel()
        partialMatchTask = nil

        switch searchMode {
        case .normal:
            runNormalScan(input)
        case .partial:
            runPartialScan(input)
        }
    }

    private func resetProgress() {
        unreadableCount = 0
        reusedCount = 0
        scannedCount = 0
        totalCount = 0
        comparedPairCount = 0
        totalPairCount = 0
        scanPhase = .idle
    }

    private func runNormalScan(_ input: ScanInput) {
        let mode = SearchMode.normal

        // まず尺で束ねる。ここで大半が落ちるので、重いフレーム展開はごく一部で済む。
        buckets = VariantVideoDetector.durationBuckets(of: input.items, tolerance: durationTolerance)
        let bucketMembers = buckets.flatMap { $0 }

        // ここで groups を空にしない。指紋がキャッシュに残っていれば直後に組み直せるので、
        // 空にすると「進捗画面が一瞬出て、すぐ一覧に戻る」というちらつきになるだけ。
        resetProgress()

        isScanning = true
        scanPhase = .extractingFrames
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
            self.scanPhase = .idle
            self.rebuildGroups()
            self.completedScanKeys[mode] = input.items.map(\.id)
            await self.signatureStore?.save()
        }
    }

    private func runPartialScan(_ input: ScanInput) {
        let mode = SearchMode.partial
        buckets = []
        resetProgress()
        let missing = input.items.filter { partialSignatures[$0.id] == nil }
        reusedCount = input.items.count - missing.count
        totalCount = missing.count

        guard !missing.isEmpty else {
            completedScanKeys[mode] = input.items.map(\.id)
            rebuildGroups()
            return
        }

        isScanning = true
        scanPhase = .extractingFrames
        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.buildPartialSignatures(for: missing, input: input)
            guard !Task.isCancelled else { return }
            self.isScanning = false
            self.scanPhase = .idle
            self.completedScanKeys[mode] = input.items.map(\.id)
            self.rebuildGroups()
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

    private func buildPartialSignatures(for pending: [VideoItem], input: ScanInput) async {
        var index = 0
        while index < pending.count {
            if Task.isCancelled { return }
            let slice = pending[index..<min(index + Self.signatureConcurrency, pending.count)]
            index += slice.count

            let results = await withTaskGroup(of: (UUID, [PerceptualHash]?).self) { taskGroup in
                for item in slice {
                    let id = item.id
                    let duration = item.duration
                    let url = input.urls[id]
                    taskGroup.addTask(priority: .utility) {
                        guard let url else { return (id, nil) }
                        return (
                            id,
                            await VariantContentAligner.discoverySignature(
                                forVideoAt: url,
                                duration: duration
                            )
                        )
                    }
                }
                var collected: [(UUID, [PerceptualHash]?)] = []
                for await result in taskGroup { collected.append(result) }
                return collected
            }

            guard !Task.isCancelled else { return }
            for (id, signature) in results {
                if let signature {
                    partialSignatures[id] = signature
                } else {
                    unreadableCount += 1
                }
            }
            scannedCount = min(index, pending.count)
        }
    }

    /// 「探し直す」ボタン用。取り込み直したファイルを拾わせたいときに使う。
    func rescan() {
        guard !isScanning, lastScanInput != nil else { return }
        completedScanKeys[searchMode] = nil
        switch searchMode {
        case .normal:
            fingerprints.removeAll()
        case .partial:
            partialSignatures.removeAll()
        }
        runScan()
    }

    func cancelScan() {
        scanTask?.cancel()
        partialMatchTask?.cancel()
        scanTask = nil
        partialMatchTask = nil
        isScanning = false
        scanPhase = .idle
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

        switch searchMode {
        case .normal:
            partialMatchTask?.cancel()
            partialMatchTask = nil
            groups = normalGroups(previousSelections: previousSelections)
        case .partial:
            schedulePartialGroupRebuild(previousSelections: previousSelections)
        }
    }

    private func normalGroups(
        previousSelections: [Set<UUID>: Set<UUID>]
    ) -> [Group] {
        buckets.flatMap { bucket in
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

    private func schedulePartialGroupRebuild(
        previousSelections: [Set<UUID>: Set<UUID>]
    ) {
        partialMatchTask?.cancel()
        guard let items = lastScanInput?.items, items.count > 1 else {
            groups = []
            isScanning = false
            scanPhase = .idle
            return
        }

        let inputs = items.compactMap { item -> VariantPartialMatchInput? in
            guard let signature = partialSignatures[item.id] else { return nil }
            return VariantPartialMatchInput(
                id: item.id,
                duration: item.duration,
                signature: signature
            )
        }
        guard inputs.count > 1 else {
            groups = []
            isScanning = false
            scanPhase = .idle
            return
        }

        let minimumDurationDifference = minimumPartialDurationDifference
        let progressUpdates = AsyncStream.makeStream(
            of: Int.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let worker = Task.detached(priority: .utility) {
            defer { progressUpdates.continuation.finish() }
            return Self.partialMatchRecords(
                inputs: inputs,
                minimumDurationDifference: minimumDurationDifference,
                reportProgress: { completedCount in
                    progressUpdates.continuation.yield(completedCount)
                }
            )
        }
        comparedPairCount = 0
        totalPairCount = inputs.count * (inputs.count - 1) / 2
        isScanning = true
        scanPhase = .comparingCandidates
        partialMatchTask = Task { @MainActor [weak self] in
            let records: [VariantPartialMatchRecord] = await withTaskCancellationHandler {
                for await completedCount in progressUpdates.stream {
                    guard !Task.isCancelled else { break }
                    self?.comparedPairCount = completedCount
                }
                return await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  self.searchMode == .partial else { return }

            let itemsByID = Dictionary(
                items.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            self.groups = records.compactMap { record in
                guard let first = itemsByID[record.firstID],
                      let second = itemsByID[record.secondID] else { return nil }
                let ids = Set([first.id, second.id])
                return Group(
                    items: [first, second],
                    duration: min(first.duration, second.duration),
                    selectedIDs: previousSelections[ids] ?? ids,
                    stats: nil,
                    sharedDuration: record.sharedDuration,
                    partialMatchScore: record.score,
                    alignmentMode: .content
                )
            }
            self.isScanning = false
            self.scanPhase = .idle
            self.partialMatchTask = nil
        }
    }

    nonisolated private static func partialMatchRecords(
        inputs: [VariantPartialMatchInput],
        minimumDurationDifference: TimeInterval,
        reportProgress: @Sendable (Int) -> Void
    ) -> [VariantPartialMatchRecord] {
        guard inputs.count > 1 else { return [] }
        var matches: [VariantPartialMatchRecord] = []
        var completedCount = 0

        for firstIndex in 0..<(inputs.count - 1) {
            if Task.isCancelled { return [] }
            let first = inputs[firstIndex]
            for secondIndex in (firstIndex + 1)..<inputs.count {
                if Task.isCancelled { return [] }
                let second = inputs[secondIndex]
                let durationDifference = abs(first.duration - second.duration)
                if durationDifference >= minimumDurationDifference,
                   let match = VariantContentAligner.discoveryMatch(
                        reference: first.signature,
                        candidate: second.signature
                   ),
                   let firstAnchor = match.mapping.anchors.first,
                   let lastAnchor = match.mapping.anchors.last {
                    matches.append(
                        VariantPartialMatchRecord(
                            firstID: first.id,
                            secondID: second.id,
                            sharedDuration: lastAnchor.logicalTime - firstAnchor.logicalTime,
                            score: match.score
                        )
                    )
                }
                completedCount += 1
                reportProgress(completedCount)
            }
        }

        return matches.sorted {
            if $0.sharedDuration == $1.sharedDuration {
                return $0.score < $1.score
            }
            return $0.sharedDuration > $1.sharedDuration
        }
    }
}
