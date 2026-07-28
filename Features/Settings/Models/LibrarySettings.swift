import Foundation

// MARK: - Library view settings (ported from VideoPlayer for Mac)

/// 並べ替えの順序
enum SortOrder: String, CaseIterable, Identifiable {
    case byImport = "インポート順"
    case byDate = "日付 (新しい順)"
    case byDateOldest = "日付 (古い順)"
    case byDurationAscending = "短い順"
    case byDurationDescending = "長い順"
    case byName = "名前"
    case byLastOpened = "最後に開いた日"
    case byDateAdded = "追加日"
    case byDateModified = "変更日"
    case byDateCreated = "作成日"
    case bySize = "サイズ"
    var id: String { rawValue }

    /// サイズ・変更日・最後に開いた日は VideoItem に持たせておらず、
    /// 実ファイルの属性（VideoFileMetadata）を読まないと並べ替えられない。
    var needsFileMetadata: Bool {
        switch self {
        case .byLastOpened, .byDateModified, .bySize: return true
        default: return false
        }
    }
}

/// サムネイルを抽出する位置
nonisolated enum ThumbnailOption: String, CaseIterable, Identifiable, Sendable {
    case initial = "1秒時点"
    case threeSeconds = "3秒時点"
    case tenSeconds = "10秒時点"
    case thirtySeconds = "30秒時点"
    case midpoint = "中間地点"
    case random = "ランダム"
    case custom = "カスタム"
    var id: String { rawValue }

    /// 動画の長さから実際の抽出秒数を求める（randomは生成のたびに変わる）
    func seconds(forDuration duration: TimeInterval, customTime: TimeInterval) -> Double {
        switch self {
        case .initial: return 1
        case .threeSeconds: return 3
        case .tenSeconds: return 10
        case .thirtySeconds: return 30
        case .midpoint: return duration > 0 ? duration / 2 : 0
        case .random: return duration > 1 ? Double.random(in: 0...(duration - 1)) : 0
        case .custom: return customTime
        }
    }
}


extension Sequence where Element == VideoItem {
    /// タイトル（originalFilename）でのインクリメンタル検索（スペース区切りのAND）
    func filtered(bySearch searchText: String) -> [VideoItem] {
        let keywords = searchText
            .replacingOccurrences(of: "　", with: " ")
            .split(separator: " ")
            .map(String.init)
        guard !keywords.isEmpty else { return Array(self) }
        return filter { item in
            let title = item.originalFilename
            return keywords.allSatisfy { title.range(of: $0, options: .caseInsensitive) != nil }
        }
    }

    /// 指定の並び順でソート。
    /// サイズ・変更日・最後に開いた日は実ファイルの属性が必要なため、
    /// `metadata` で item ごとの `VideoFileMetadata` を解決する（未指定なら空扱い）。
    /// `reversed` が true のときは各順の既定の向きを反転した並びを返す（上下逆）。
    func sorted(by order: SortOrder, reversed: Bool = false, metadata: (VideoItem) -> VideoFileMetadata = { _ in VideoFileMetadata() }) -> [VideoItem] {
        let result: [VideoItem]
        switch order {
        case .byImport:
            result = Array(self)
        case .byDate:
            result = sorted { ($0.creationDate ?? $0.importDate) > ($1.creationDate ?? $1.importDate) }
        case .byDateOldest:
            result = sorted { ($0.creationDate ?? $0.importDate) < ($1.creationDate ?? $1.importDate) }
        case .byDurationAscending:
            result = sorted { $0.duration < $1.duration }
        case .byDurationDescending:
            result = sorted { $0.duration > $1.duration }
        case .byName:
            result = sorted { $0.originalFilename.localizedStandardCompare($1.originalFilename) == .orderedAscending }
        case .byDateAdded:
            result = sorted { $0.importDate > $1.importDate }
        case .byDateCreated:
            result = sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .byLastOpened:
            // 実ファイルへの stat を比較のたびに繰り返さないよう、先に id→属性を作ってから比較する。
            let items = Array(self)
            let dates = Dictionary(items.map { ($0.id, metadata($0).accessDate ?? .distantPast) },
                                   uniquingKeysWith: { first, _ in first })
            result = items.sorted { (dates[$0.id] ?? .distantPast) > (dates[$1.id] ?? .distantPast) }
        case .byDateModified:
            let items = Array(self)
            let dates = Dictionary(items.map { ($0.id, metadata($0).modificationDate ?? .distantPast) },
                                   uniquingKeysWith: { first, _ in first })
            result = items.sorted { (dates[$0.id] ?? .distantPast) > (dates[$1.id] ?? .distantPast) }
        case .bySize:
            let items = Array(self)
            let sizes = Dictionary(items.map { ($0.id, metadata($0).size) },
                                   uniquingKeysWith: { first, _ in first })
            result = items.sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
        }
        return reversed ? result.reversed() : result
    }
}
