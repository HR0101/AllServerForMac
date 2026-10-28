import AppKit
import SwiftUI

/// 詳細設定シート。データ安全・サーバー保護・パフォーマンス・エクスポートの
/// 各設定をまとめる（値の実体は LibraryViewModel / ServerViewModel / UserDefaults）。
struct PreferencesView: View {
    @ObservedObject var dataManager: LibraryViewModel
    @ObservedObject var webServerManager: ServerViewModel
    @ObservedObject var appSettings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @AppStorage("thumbnailMemoryCacheLimit") private var thumbnailMemoryCacheLimit = 600

    /// 上部の見出しボタンから飛べる区分。設定が縦に長いので，目的の場所へすぐ移れるようにする。
    private enum SettingsSection: String, CaseIterable, Identifiable {
        // シートの最小幅（560）に1行で収まるよう，見出しより短い名前にしている。
        case connection = "接続"
        case appearance = "外観"
        case data = "データ"
        case server = "保護"
        case performance = "性能"
        case export = "書き出し"
        case shortcuts = "ショートカット"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(icon: "gearshape", tint: NeomorphicTheme.muted, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac Media Serverの設定")
                        .font(.title3.bold())
                    Text("接続・データの安全性・サーバー保護・パフォーマンスの設定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)

            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    sectionJumpBar(proxy: proxy)

                    Form {
                        // ポート・PIN・自動停止はホームのカードでも変えられるが，設定を探すときに
                        // ここだけ見れば全部そろっているようにする（値の実体は同じ ServerViewModel）。
                        Section("接続・認証") {
                            LabeledContent("ポート番号") {
                                HStack(spacing: 6) {
                                    TextField("ポート番号", value: $webServerManager.targetPort, format: .number.grouping(.never))
                                        .labelsHidden()
                                        .frame(width: 70)
                                        .multilineTextAlignment(.center)
                                    Button {
                                        webServerManager.targetPort = 8080
                                    } label: {
                                        Image(systemName: "arrow.counterclockwise")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("デフォルト(8080)に戻す")
                                }
                            }
                            .disabled(webServerManager.isRunning)

                            Toggle("自動停止タイマー", isOn: $webServerManager.autoStopEnabled)
                                .disabled(webServerManager.isRunning)
                            if webServerManager.autoStopEnabled {
                                LabeledContent("サーバー開始から終了まで") {
                                    HStack(spacing: 5) {
                                        TextField("分", value: $webServerManager.autoStopIntervalMinutes, format: .number)
                                            .labelsHidden()
                                            .frame(width: 54)
                                            .multilineTextAlignment(.trailing)
                                        Text("分").foregroundStyle(.secondary)
                                    }
                                }
                                .disabled(webServerManager.isRunning)
                            }
                            if webServerManager.isRunning {
                                Text("ポート番号と自動停止は，サーバーを停止すると変更できます．")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Toggle("PIN認証を必須にする", isOn: $webServerManager.authEnabled)
                            if webServerManager.authEnabled {
                                LabeledContent("接続PIN") {
                                    HStack(spacing: 8) {
                                        Text(webServerManager.authPIN)
                                            .font(.system(.body, design: .monospaced).weight(.bold))
                                            .textSelection(.enabled)
                                        Button {
                                            webServerManager.regeneratePIN()
                                        } label: {
                                            Image(systemName: "arrow.triangle.2.circlepath")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("PINを再生成する")
                                    }
                                }
                            } else {
                                Text("認証が無効です．同じWi-Fi内の誰でもアクセスできます．")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .id(SettingsSection.connection)

                        Section("外観") {
                            Toggle("ダークな外観にする", isOn: $appSettings.neomorphicDarkBase)
                            Text("ブルーを基調に，控えめなガラスと読みやすい文字で統一しています．明るい外観と暗い外観を切り替えられます．")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Toggle("サイドバーのアルバムに表紙と詳細を表示", isOn: $appSettings.sidebarShowsAlbumDetails)
                            Text("オフにすると，従来の名前と件数だけの行に戻ります．アルバムが非常に多いときに行を詰めたい場合に使います．")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .id(SettingsSection.appearance)

                        Section("データの安全") {
                            Toggle("インポート時にファイルをアプリ内へコピー", isOn: $dataManager.importCopiesFiles)
                            Text("オンにすると，元のフォルダを消してもサーバー内に実体が残ります（ディスク容量を消費）．オフ（既定）は元の場所を参照するだけで，元ファイルを消すと再生できなくなります．")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Picker("ゴミ箱の自動削除", selection: $dataManager.trashAutoDeleteDays) {
                                Text("しない").tag(0)
                                Text("30日後").tag(30)
                                Text("90日後").tag(90)
                            }
                            Text("ゴミ箱に入れてから指定日数が経過した項目を，起動時に完全削除します．")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Toggle("起動時にリンク切れメディアを自動整理", isOn: $dataManager.autoCleanupMissingFilesEnabled)
                            Text("元ファイルが見つからない項目を起動時に自動削除します．外付けドライブのメディアを参照している場合はオフのままにしてください（未接続時に誤って消えます）．")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .id(SettingsSection.data)

                        Section("サーバー保護") {
                            Toggle("認証オフでも削除操作にはPINを要求", isOn: $webServerManager.requirePINForDeletion)
                            Text("PIN認証をオフにしていても，完全削除・アルバム削除・サーバー停止のAPIにはPINを要求します．")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextField("サーバー表示名（空欄でコンピュータ名）", text: $webServerManager.serverDisplayName)
                            Text("iOSアプリやブラウザに表示される名前です．変更はサーバーの再起動後に反映されます．")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Picker("アップロード上限", selection: $webServerManager.maxUploadGB) {
                                ForEach(ServerViewModel.uploadLimitOptionsGB, id: \.self) { gb in
                                    Text("\(gb) GB").tag(gb)
                                }
                            }
                            Text("受信中のファイルは丸ごとメモリに読み込まれるため，搭載メモリ（\(Self.physicalMemoryGB) GB）の半分までしか選べません．")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .id(SettingsSection.server)

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
                        .id(SettingsSection.performance)

                        Section("エクスポート") {
                            Toggle("アルバムの階層構造を再現して書き出す", isOn: $dataManager.exportPreservesAlbumStructure)
                            Text("オフにすると，すべてのファイルを選んだフォルダ直下にフラットに書き出します．")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .id(SettingsSection.export)

                        MediaShortcutSettingsSection()
                            .id(SettingsSection.shortcuts)
                    }
                    .formStyle(.grouped)
                }
            }

            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        // 項目が多いので固定サイズにせず，ウィンドウの端をドラッグして広げられるようにする。
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 900, minHeight: 520, idealHeight: 760, maxHeight: .infinity)
        // シートを開くと AppKit が先頭の入力欄（ポート番号）を自動で選択し，うっかり打鍵しただけで
        // 値が書き換わる。SwiftUI の FocusState では止められないので，開いた直後に選択を外す。
        .background(InitialFirstResponderClearer())
        // 半透明にするとデスクトップの色が透けて緑や青に濁るので、アプリ本体と同じ単色の下地にする。
        .background(NeomorphicTheme.canvas)
        .tint(NeomorphicTheme.accent)
        .foregroundStyle(NeomorphicTheme.ink)
    }

    private static let physicalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

    private func sectionJumpBar(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(section, anchor: .top)
                        }
                    } label: {
                        Text(section.rawValue)
                            .font(.system(size: 12))
                            .foregroundStyle(NeomorphicTheme.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(NeomorphicTheme.control))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 8)
    }
}
