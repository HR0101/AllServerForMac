import Combine
import Foundation

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
    /// 並び順の上下を逆にするか（各 SortOrder の既定の向きを全体で反転する）。
    @Published var sortReversed: Bool {
        didSet { defaults.set(sortReversed, forKey: Keys.sortReversed) }
    }
    @Published var columnCount: Double {
        didSet { defaults.set(columnCount, forKey: Keys.columnCount) }
    }
    @Published var showTitles: Bool {
        didSet { defaults.set(showTitles, forKey: Keys.showTitles) }
    }
    @Published var showImportDates: Bool {
        didSet { defaults.set(showImportDates, forKey: Keys.showImportDates) }
    }
    /// ネオモーフィズムのベースカラーを黒基調にするか（false=既定の白基調）。
    /// 実際の色解決は NeomorphicTheme が同じ UserDefaults キーを直接読む。
    @Published var neomorphicDarkBase: Bool {
        didSet { defaults.set(neomorphicDarkBase, forKey: Keys.neomorphicDarkBase) }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let thumbnailOption = "library.thumbnailOption"
        static let customThumbnailTime = "library.customThumbnailTime"
        static let sortOrder = "library.sortOrder"
        static let sortReversed = "library.sortReversed"
        static let columnCount = "library.columnCount"
        static let showTitles = "library.showTitles"
        static let showImportDates = "library.showImportDates"
        static let neomorphicDarkBase = NeomorphicTheme.darkBaseDefaultsKey
    }

    init() {
        let d = UserDefaults.standard
        self.thumbnailOption = (d.string(forKey: Keys.thumbnailOption).flatMap(ThumbnailOption.init)) ?? .initial
        self.customThumbnailTime = d.object(forKey: Keys.customThumbnailTime) as? TimeInterval ?? 60
        self.sortOrder = (d.string(forKey: Keys.sortOrder).flatMap(SortOrder.init)) ?? .byImport
        self.sortReversed = d.bool(forKey: Keys.sortReversed)
        self.columnCount = d.object(forKey: Keys.columnCount) as? Double ?? 5
        let savedShowTitles = d.object(forKey: Keys.showTitles) as? Bool ?? true
        self.showTitles = savedShowTitles
        // 既存の「タイトルを表示」がオフなら，従来は日付も非表示だったため，
        // 新しい日付設定がまだ保存されていない場合は同じ状態を引き継ぐ。
        self.showImportDates = d.object(forKey: Keys.showImportDates) as? Bool ?? savedShowTitles
        self.neomorphicDarkBase = d.bool(forKey: Keys.neomorphicDarkBase)
    }
}
