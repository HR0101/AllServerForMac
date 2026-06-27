import SwiftUI

struct AccessLogView: View {
    @ObservedObject var webServerManager: WebServerManager
    @Environment(\.dismiss) var dismiss
    @State private var logFilter: Int = 0 // 0: 全て, 1: 動画本体, 2: サムネ, 3: その他

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconTile(icon: "list.bullet.rectangle.fill", tint: .teal, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("アクセスログ").font(.headline)
                    Text("直近 \(webServerManager.accessLogs.count) 件のリクエスト")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $logFilter) {
                    Text("すべて").tag(0)
                    Text("動画本体").tag(1)
                    Text("サムネ").tag(2)
                    Text("その他").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
                
                Button("クリア") { webServerManager.accessLogs.removeAll() }
                    .disabled(webServerManager.accessLogs.isEmpty)
                Button("閉じる") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            let filteredLogs = webServerManager.accessLogs.filter { entry in
                switch logFilter {
                case 1: return entry.path.hasPrefix("/video/")
                case 2: return entry.path.hasPrefix("/thumbnail/")
                case 3: return !entry.path.hasPrefix("/video/") && !entry.path.hasPrefix("/thumbnail/")
                default: return true
                }
            }

            if filteredLogs.isEmpty {
                ContentUnavailableView(
                    "まだアクセスがありません",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("選択した条件に一致するリクエストはありません")
                )
            } else {
                Table(filteredLogs) {
                    TableColumn("時刻") { entry in
                        Text(AccessLogView.timeFormatter.string(from: entry.date))
                            .font(.system(.caption, design: .monospaced))
                    }
                    .width(110)
                    TableColumn("IP") { entry in
                        Text(entry.ip).font(.system(.caption, design: .monospaced))
                    }
                    .width(110)
                    TableColumn("メソッド") { entry in
                        Text(entry.method)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                            .foregroundStyle(.blue)
                    }
                    .width(64)
                    TableColumn("パス") { entry in
                        Text(entry.path).font(.caption).lineLimit(1).truncationMode(.middle)
                    }
                    TableColumn("認証") { entry in
                        Text(entry.authorized ? "許可" : "拒否")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill((entry.authorized ? Color.green : Color.red).opacity(0.15)))
                            .foregroundStyle(entry.authorized ? .green : .red)
                    }
                    .width(48)
                }
            }
        }
        .frame(width: 680, height: 480)
    }
}
