import Combine
import Foundation

@MainActor
final class SketchCleanupViewModel: ObservableObject {
    struct Candidate: Identifiable {
        let item: VideoItem
        let judgement: SketchJudgement
        var id: UUID { item.id }
    }

    @Published private(set) var isScanning = false
    @Published private(set) var scannedCount = 0
    @Published private(set) var totalCount = 0
    /// 走査できたものすべて（スコア順）。表示はここから閾値で絞る。
    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var unreadableCount = 0
    @Published var selectedIDs = Set<UUID>()

    /// 判定のきびしさ。これ以上のスコアだけを候補として見せる。
    /// 既定値は、白地の線画・鉛筆ラフ・トーン漫画が確実に入り、
    /// 単色（青ペン）の下描きも余裕を持って拾える位置に置いてある。
    @Published var threshold: Double = 0.55 {
        didSet { syncSelectionToThreshold() }
    }

    private var scanTask: Task<Void, Never>?

    var progress: Double {
        totalCount == 0 ? 0 : Double(scannedCount) / Double(totalCount)
    }

    /// 種類での絞り込み。ラフ画だけまとめて消したい、といった使い方のため。
    enum KindFilter: String, CaseIterable, Identifiable {
        case all, roughSketch, lineArt
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .all: return "すべて"
            case .roughSketch: return "ラフ画のみ"
            case .lineArt: return "線画のみ"
            }
        }
    }

    @Published var kindFilter: KindFilter = .all {
        didSet { syncSelectionToThreshold() }
    }

    /// いま画面に出す候補（閾値以上、かつ選んだ種類）。
    var visibleCandidates: [Candidate] {
        candidates.filter { candidate in
            guard candidate.judgement.score >= threshold else { return false }
            switch kindFilter {
            case .all: return true
            case .roughSketch: return candidate.judgement.kind == .roughSketch
            case .lineArt: return candidate.judgement.kind == .lineArt
            }
        }
    }

    var selectedItems: [VideoItem] {
        visibleCandidates.filter { selectedIDs.contains($0.id) }.map(\.item)
    }

    func scan(items: [VideoItem], dataManager: LibraryViewModel) {
        guard !isScanning else { return }
        let photos = items.filter { $0.mediaType == .photo }
        let targets: [(VideoItem, URL)] = photos.compactMap { item in
            guard let url = dataManager.fileURL(for: item) else { return nil }
            return (item, url)
        }

        isScanning = true
        scannedCount = 0
        totalCount = targets.count
        candidates = []
        selectedIDs = []
        unreadableCount = photos.count - targets.count

        scanTask = Task { @MainActor in
            var found: [Candidate] = []
            // UI を毎件更新すると走査より描画が重くなるので、進捗はまとめて反映する。
            let progressStride = max(1, targets.count / 100)

            for (offset, entry) in targets.enumerated() {
                if Task.isCancelled { break }
                let url = entry.1
                let profile = await Task.detached(priority: .utility) {
                    SketchDetector.profile(forImageAt: url)
                }.value

                if let profile {
                    found.append(Candidate(item: entry.0, judgement: SketchDetector.judge(profile)))
                } else {
                    unreadableCount += 1
                }

                if offset % progressStride == 0 {
                    scannedCount = offset + 1
                }
            }

            scannedCount = targets.count
            candidates = found.sorted { $0.judgement.score > $1.judgement.score }
            syncSelectionToThreshold()
            isScanning = false
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func toggle(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    func selectAllVisible() {
        selectedIDs = Set(visibleCandidates.map(\.id))
    }

    func deselectAll() {
        selectedIDs = []
    }

    /// 閾値を動かしたら、見えている候補は既定で選択済みにする。
    /// 見えなくなったものの選択は落とす（消すつもりのないものが混ざらないように）。
    private func syncSelectionToThreshold() {
        selectedIDs = Set(visibleCandidates.map(\.id))
    }
}
