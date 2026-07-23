import SwiftUI

/// 詳細設定シート。データ安全・サーバー保護・パフォーマンス・エクスポートの
/// 各設定をまとめる（値の実体は VideoDataManager / WebServerManager / UserDefaults）。
struct PreferencesView: View {
    @ObservedObject var dataManager: VideoDataManager
    @ObservedObject var webServerManager: WebServerManager
    @ObservedObject var appSettings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @AppStorage("thumbnailMemoryCacheLimit") private var thumbnailMemoryCacheLimit = 600

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(icon: "gearshape.fill", tint: .gray, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("詳細設定")
                        .font(.title3.bold())
                    Text("データの安全性・サーバー保護・パフォーマンスの設定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Form {
                Section("外観") {
                    Toggle("ベースカラーをブラックにする", isOn: $appSettings.neomorphicDarkBase)
                    Text("ネオモーフィズムの基調色を白から黒へ切り替えます。レイアウトは変わりません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("データの安全") {
                    Toggle("インポート時にファイルをアプリ内へコピー", isOn: $dataManager.importCopiesFiles)
                    Text("オンにすると、元のフォルダを消してもサーバー内に実体が残ります（ディスク容量を消費）。オフ（既定）は元の場所を参照するだけで、元ファイルを消すと再生できなくなります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("ゴミ箱の自動削除", selection: $dataManager.trashAutoDeleteDays) {
                        Text("しない").tag(0)
                        Text("30日後").tag(30)
                        Text("90日後").tag(90)
                    }
                    Text("ゴミ箱に入れてから指定日数が経過した項目を、起動時に完全削除します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("起動時にリンク切れメディアを自動整理", isOn: $dataManager.autoCleanupMissingFilesEnabled)
                    Text("元ファイルが見つからない項目を起動時に自動削除します。外付けドライブのメディアを参照している場合はオフのままにしてください（未接続時に誤って消えます）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("サーバー保護") {
                    Toggle("認証オフでも削除操作にはPINを要求", isOn: $webServerManager.requirePINForDeletion)
                    Text("PIN認証をオフにしていても、完全削除・アルバム削除・サーバー停止のAPIにはPINを要求します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("サーバー表示名（空欄でコンピュータ名）", text: $webServerManager.serverDisplayName)
                    Text("iOSアプリやブラウザに表示される名前です。変更はサーバーの再起動後に反映されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("アップロード上限", selection: $webServerManager.maxUploadGB) {
                        Text("1 GB").tag(1)
                        Text("5 GB").tag(5)
                        Text("20 GB").tag(20)
                        Text("50 GB").tag(50)
                    }
                }

                Section("パフォーマンス") {
                    Picker("自動重複チェックの間隔", selection: $dataManager.duplicateCheckIntervalSeconds) {
                        Text("30秒").tag(30)
                        Text("1分").tag(60)
                        Text("5分").tag(300)
                        Text("15分").tag(900)
                    }

                    Picker("インポートの並列数", selection: $dataManager.importConcurrency) {
                        Text("2（省電力）").tag(2)
                        Text("4（標準）").tag(4)
                        Text("8（高速）").tag(8)
                    }

                    Picker("サムネイルのメモリキャッシュ上限", selection: $thumbnailMemoryCacheLimit) {
                        Text("200枚（省メモリ）").tag(200)
                        Text("600枚（標準）").tag(600)
                        Text("1200枚（大量表示向け）").tag(1200)
                    }
                    .onChange(of: thumbnailMemoryCacheLimit) { _, newValue in
                        MacVideoThumbnailView.updateMemoryCacheLimit(newValue)
                    }
                }

                Section("エクスポート") {
                    Toggle("アルバムの階層構造を再現して書き出す", isOn: $dataManager.exportPreservesAlbumStructure)
                    Text("オフにすると、すべてのファイルを選んだフォルダ直下にフラットに書き出します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                MediaShortcutSettingsSection()
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 640)
    }
}
