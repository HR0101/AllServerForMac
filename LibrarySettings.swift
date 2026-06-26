import Foundation
import SwiftUI
import Combine

// MARK: - Library view settings (ported from VideoPlayer for Mac)

/// 並べ替えの順序
enum SortOrder: String, CaseIterable, Identifiable {
    case byImport = "インポート順"
    case byDate = "日付 (新しい順)"
    case byDateOldest = "日付 (古い順)"
    case byDurationAscending = "短い順"
    case byDurationDescending = "長い順"
    var id: String { rawValue }
}

/// サムネイルを抽出する位置
enum ThumbnailOption: String, CaseIterable, Identifiable {
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

/// グリッド表示・サムネイルに関するアプリ全体の設定（UserDefaults永続化）
@MainActor
final class AppSettings: ObservableObject {
    @Published var thumbnailOption: ThumbnailOption {
        didSet { defaults.set(thumbnailOption.rawValue, forKey: Keys.thumbnailOption) }
    }
    @Published var customThumbnailTime: TimeInterval {
        didSet { defaults.set(customThumbnailTime, forKey: Keys.customThumbnailTime) }
    }
    @Published var sortOrder: SortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: Keys.sortOrder) }
    }
    @Published var columnCount: Double {
        didSet { defaults.set(columnCount, forKey: Keys.columnCount) }
    }
    @Published var showTitles: Bool {
        didSet { defaults.set(showTitles, forKey: Keys.showTitles) }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let thumbnailOption = "library.thumbnailOption"
        static let customThumbnailTime = "library.customThumbnailTime"
        static let sortOrder = "library.sortOrder"
        static let columnCount = "library.columnCount"
        static let showTitles = "library.showTitles"
    }

    init() {
        let d = UserDefaults.standard
        self.thumbnailOption = (d.string(forKey: Keys.thumbnailOption).flatMap(ThumbnailOption.init)) ?? .initial
        self.customThumbnailTime = d.object(forKey: Keys.customThumbnailTime) as? TimeInterval ?? 60
        self.sortOrder = (d.string(forKey: Keys.sortOrder).flatMap(SortOrder.init)) ?? .byImport
        self.columnCount = d.object(forKey: Keys.columnCount) as? Double ?? 5
        self.showTitles = d.object(forKey: Keys.showTitles) as? Bool ?? true
    }
}

// MARK: - Sorting / searching helpers

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

    /// 指定の並び順でソート
    func sorted(by order: SortOrder) -> [VideoItem] {
        switch order {
        case .byImport:
            return Array(self)
        case .byDate:
            return sorted { ($0.creationDate ?? $0.importDate) > ($1.creationDate ?? $1.importDate) }
        case .byDateOldest:
            return sorted { ($0.creationDate ?? $0.importDate) < ($1.creationDate ?? $1.importDate) }
        case .byDurationAscending:
            return sorted { $0.duration < $1.duration }
        case .byDurationDescending:
            return sorted { $0.duration > $1.duration }
        }
    }
}
