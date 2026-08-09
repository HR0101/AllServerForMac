import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 共有グリッド設定バー（ソート/サムネ位置/タイトル/列数）
struct MediaGridControlBar: View {
    @EnvironmentObject private var appSettings: AppSettings
    /// 「サイズ」「最後に開いた日」等を選んだときにファイル属性キャッシュを最新化するためだけに参照する。
    /// 表示更新は監視しないので @ObservedObject ではなく素の参照にしている。
    let dataManager: LibraryViewModel

    private static let secondsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimum = 0
        f.maximum = 3600
        return f
    }()

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(SortOrder.allCases) { order in
                    Button(order.rawValue) {
                        // ファイル属性で並べる順を選び直したときは実ファイルを読み直して最新化する。
                        if order.needsFileMetadata { dataManager.refreshFileMetadataCache() }
                        appSettings.sortOrder = order
                    }
                }
            } label: {
                Label(appSettings.sortOrder.rawValue, systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()

            // 並び順の上下をワンクリックで反転する（既に並んだ結果を反転するだけなので再読み込み不要）。
            Button {
                appSettings.sortReversed.toggle()
            } label: {
                Image(systemName: appSettings.sortReversed ? "arrow.up" : "arrow.down")
            }
            .help(appSettings.sortReversed ? "並び順を元に戻す（逆順中）" : "並び順を上下逆にする")

            Menu {
                ForEach(ThumbnailOption.allCases) { option in
                    Button(option.rawValue) { appSettings.thumbnailOption = option }
                }
            } label: {
                Label("サムネ: \(appSettings.thumbnailOption.rawValue)", systemImage: "photo.on.rectangle.angled")
            }
            .fixedSize()

            if appSettings.thumbnailOption == .custom {
                HStack(spacing: 4) {
                    Stepper("", value: $appSettings.customThumbnailTime, in: 0...3600, step: 1)
                        .labelsHidden()
                    TextField("秒", value: $appSettings.customThumbnailTime, formatter: MediaGridControlBar.secondsFormatter)
                        .frame(width: 46)
                        .multilineTextAlignment(.trailing)
                    Text("秒").font(.caption)
                }
            }

            Spacer()

            Menu {
                Toggle("タイトルを表示", isOn: $appSettings.showTitles)
                Toggle("インポート日を表示", isOn: $appSettings.showImportDates)
            } label: {
                Image(systemName: appSettings.showTitles || appSettings.showImportDates ? "text.below.photo.fill" : "text.below.photo")
            }
            .help("サムネイル下の表示項目を設定")

            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                Slider(value: $appSettings.columnCount, in: 2...12, step: 1)
                    .frame(width: 140)
                Image(systemName: "square.grid.4x3.fill")
            }
            .help("表示列数: \(Int(appSettings.columnCount))列")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
}
