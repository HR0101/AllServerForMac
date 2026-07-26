import Combine
import SwiftUI

// MARK: - ラフ画・線画の抽出と一括削除
//
// アルバムの画像を走査して「ラフ画・線画らしい」ものを集め、
// 目で確かめてから消せるようにする。自動判定に外れはあるので、
// 見つけたものを黙って消すことはせず、必ずこの画面を挟む。

@MainActor
final class SketchCleanupModel: ObservableObject {
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

    func scan(items: [VideoItem], dataManager: VideoDataManager) {
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

struct SketchCleanupView: View {
    let items: [VideoItem]
    @ObservedObject var dataManager: VideoDataManager
    /// 消したあとに一覧側の選択を片付けてもらうための通知。
    var onFinish: () -> Void = {}

    @StateObject private var model = SketchCleanupModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false

    private let thumbnailSide: CGFloat = 132

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 780, idealWidth: 980, minHeight: 520, idealHeight: 680)
        .onAppear { model.scan(items: items, dataManager: dataManager) }
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
            Label("ラフ画・線画の抽出", systemImage: "scribble.variable")
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
                Text("判定中… \(model.scannedCount) / \(model.totalCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("中止") { model.cancelScan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleCandidates.isEmpty {
            ContentUnavailableView(
                "該当する画像はありません",
                systemImage: "checkmark.circle",
                description: Text(model.candidates.isEmpty
                    ? "このアルバムには判定できる画像がありませんでした。"
                    : "「きびしさ」を下げると候補が増えます。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: thumbnailSide), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(model.visibleCandidates) { candidate in
                        candidateCell(candidate)
                    }
                }
                .padding(14)
            }
        }
    }

    private func candidateCell(_ candidate: SketchCleanupModel.Candidate) -> some View {
        let isSelected = model.selectedIDs.contains(candidate.id)
        return VStack(spacing: 5) {
            MacVideoThumbnailView(videoItem: candidate.item, dataManager: dataManager)
                .frame(width: thumbnailSide, height: thumbnailSide)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                                      lineWidth: isSelected ? 3 : 1)
                )
                .overlay(alignment: .topLeading) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.35))
                        .padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(candidate.judgement.kind.displayName) \(Int(candidate.judgement.score * 100))%")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(6)
                }
                .opacity(isSelected ? 1 : 0.55)

            Text(candidate.item.originalFilename)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: thumbnailSide)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(candidate.id) }
        .help(candidate.item.originalFilename)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("きびしさ")
                    .font(.caption)
                Slider(value: $model.threshold, in: 0.3...0.95)
                    .frame(width: 200)
                Text("\(Int(model.threshold * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .leading)
                Picker("", selection: $model.kindFilter) {
                    ForEach(SketchCleanupModel.KindFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Spacer()
            }

            HStack(spacing: 10) {
                Text("\(model.visibleCandidates.count)件が該当 / \(model.selectedIDs.count)件を選択中")
                    .font(.subheadline)
                if model.unreadableCount > 0 {
                    Text("読み取れなかった画像: \(model.unreadableCount)件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("すべて選択") { model.selectAllVisible() }
                    .disabled(model.visibleCandidates.isEmpty)
                Button("選択を解除") { model.deselectAll() }
                    .disabled(model.selectedIDs.isEmpty)
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
