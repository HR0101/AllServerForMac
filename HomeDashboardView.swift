import AppKit
import Charts
import SwiftUI

// MARK: - HomeView（ダッシュボード）
struct HomeView: View {
    @ObservedObject var dataManager: VideoDataManager
    @ObservedObject var webServerManager: WebServerManager
    @StateObject private var systemMonitor = SystemMonitor()

    @State private var isShowingAccessLog = false
    @State private var isShowingStorageManager = false
    @State private var logFilter: Int = 0 // 0: 全て, 1: 動画本体, 2: サムネ, 3: その他

    private let cardColumns = [GridItem(.adaptive(minimum: 320, maximum: 600), spacing: DS.cardSpacing, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(spacing: DS.cardSpacing) {
                ServerHeroCard(webServerManager: webServerManager)

                LazyVGrid(columns: cardColumns, spacing: DS.cardSpacing) {
                    connectionCard
                    securityCard
                    scheduleCard
                    resourcesCard
                    storageCard
                    logsCard
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(NSColor.underPageBackgroundColor))
        .sheet(isPresented: $isShowingAccessLog) {
            AccessLogView(webServerManager: webServerManager)
        }
        .sheet(isPresented: $isShowingStorageManager) {
            StorageManagerView(dataManager: dataManager)
        }
    }

    // MARK: 接続設定カード
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "network", tint: .blue, title: "接続設定", subtitle: "ポートと自動停止")

            SettingRow(label: "ポート番号") {
                HStack(spacing: 6) {
                    TextField("8080", value: $webServerManager.targetPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.center)
                        .disabled(webServerManager.isRunning)

                    Button(action: { webServerManager.targetPort = 8080 }) {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(webServerManager.isRunning)
                    .help("デフォルト(8080)に戻す")
                }
            }

            Divider()

            Toggle(isOn: $webServerManager.autoStopEnabled) {
                Text("自動停止タイマー")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(webServerManager.isRunning)

            if webServerManager.autoStopEnabled {
                SettingRow(label: "停止までの時間") {
                    HStack(spacing: 5) {
                        TextField("分", value: $webServerManager.autoStopIntervalMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 54)
                            .multilineTextAlignment(.trailing)
                            .disabled(webServerManager.isRunning)
                        Text("分")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: webServerManager.autoStopEnabled)
        .dashboardCard()
    }

    // MARK: スケジュールカード
    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "calendar.badge.clock", tint: .purple, title: "スケジュール", subtitle: "毎日の自動起動・停止")

            Toggle(isOn: $webServerManager.scheduleEnabled) {
                Text("毎日決まった時間に起動/停止")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if webServerManager.scheduleEnabled {
                Divider()

                DatePicker("起動時刻", selection: $webServerManager.scheduleStartTime, displayedComponents: .hourAndMinute)
                    .font(.system(size: 12))
                DatePicker("停止時刻", selection: $webServerManager.scheduleStopTime, displayedComponents: .hourAndMinute)
                    .font(.system(size: 12))

                Button(action: { webServerManager.applySchedule() }) {
                    Label("このスケジュールを適用", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                Text("適用時に管理者パスワードの入力を求められます（スリープからの自動起床設定のため）。停止時刻になるとアプリは完全終了します。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !webServerManager.scheduleStatusMessage.isEmpty {
                    Text(webServerManager.scheduleStatusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: webServerManager.scheduleEnabled)
        .dashboardCard()
    }

    // MARK: セキュリティカード
    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "lock.shield.fill", tint: .green, title: "セキュリティ", subtitle: "PIN認証とアクセスログ")

            Toggle(isOn: $webServerManager.authEnabled) {
                Text("PIN認証を必須にする")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("オンにすると、Web・iOSアプリからのアクセスにPINが必要になります。")

            if webServerManager.authEnabled {
                SettingRow(label: "接続PIN") {
                    HStack(spacing: 8) {
                        CopyableText(
                            text: webServerManager.authPIN,
                            font: .system(size: 17, weight: .bold, design: .monospaced),
                            tint: .green
                        )
                        Button(action: { webServerManager.regeneratePIN() }) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderless)
                        .help("PINを再生成する")
                    }
                }
                Text("このPINをiPhoneアプリ・ブラウザで入力してください。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("認証が無効です。同じWi-Fi内の誰でもアクセスできます。")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
            }

            Divider()

            Button(action: { isShowingAccessLog = true }) {
                HStack {
                    Label("アクセスログ", systemImage: "list.bullet.rectangle")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(webServerManager.accessLogs.count)件")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .animation(.easeInOut(duration: 0.18), value: webServerManager.authEnabled)
        .dashboardCard()
    }

    // MARK: システムリソースカード
    private var resourcesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "gauge.with.dots.needle.50percent", tint: .orange, title: "システムリソース", subtitle: "CPUとメモリの使用状況")

            HStack(spacing: 24) {
                ResourceGauge(label: "CPU", value: systemMonitor.cpuUsage, tint: .orange)
                ResourceGauge(label: "メモリ", value: systemMonitor.memoryUsage, tint: .blue)
                Spacer()
            }

            Chart {
                ForEach(systemMonitor.cpuHistory) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("CPU(%)", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))

                    AreaMark(
                        x: .value("Time", point.time),
                        y: .value("CPU(%)", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.orange.opacity(0.35), Color.orange.opacity(0.0)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                    AxisValueLabel()
                        .font(.system(size: 8))
                }
            }
            .frame(height: 90)
        }
        .dashboardCard()
    }

    // MARK: ストレージカード
    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "internaldrive.fill", tint: .indigo, title: "ストレージ", subtitle: "ライブラリの使用状況")

            SettingRow(label: "総アイテム数") {
                Text("\(dataManager.videos.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
            SettingRow(label: "使用容量") {
                Text(dataManager.calculateTotalStorageSize())
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }

            Divider()

            Button(action: { isShowingStorageManager = true }) {
                Label("ストレージ管理を開く", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .dashboardCard()
    }

    // MARK: リアルタイム通信ログカード
    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardHeader(icon: "network.badge.shield.half.filled", tint: .teal, title: "リアルタイム通信ログ", subtitle: "直近のアクセス状況")
                Spacer()
                Button("すべて見る") { isShowingAccessLog = true }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
            }
            
            Picker("", selection: $logFilter) {
                Text("すべて").tag(0)
                Text("動画本体").tag(1)
                Text("サムネ").tag(2)
                Text("その他").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.bottom, 4)
            
            let filteredLogs = webServerManager.accessLogs.filter { entry in
                switch logFilter {
                case 1: return entry.path.hasPrefix("/video/")
                case 2: return entry.path.hasPrefix("/thumbnail/")
                case 3: return !entry.path.hasPrefix("/video/") && !entry.path.hasPrefix("/thumbnail/")
                default: return true
                }
            }
            
            if filteredLogs.isEmpty {
                Text("まだアクセスがありません")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredLogs.prefix(15)) { entry in
                        HStack(spacing: 8) {
                            Text(entry.date.formatted(.dateTime.hour().minute().second()))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .leading)
                            
                            Image(systemName: entry.authorized ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(entry.authorized ? .green : .red)
                                .font(.system(size: 10))
                            
                            Text(entry.method)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(entry.method == "GET" ? .blue : .purple)
                                .frame(width: 36, alignment: .leading)
                            
                            Text(entry.path)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(entry.path)
                            
                            Spacer(minLength: 5)
                            
                            Text(entry.ip)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(maxHeight: 240, alignment: .top)
                .clipped()
            }
        }
        .dashboardCard()
    }
}

// MARK: - サーバー状態ヒーローカード
struct ServerHeroCard: View {
    @ObservedObject var webServerManager: WebServerManager

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                IconTile(icon: "server.rack", tint: webServerManager.isRunning ? .green : .gray, size: 46)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StatusDot(active: webServerManager.isRunning)
                        Text(webServerManager.isRunning ? "サーバー実行中" : "サーバー停止中")
                            .font(.system(size: 17, weight: .bold))
                    }
                    statusDetail
                }

                Spacer()

                if webServerManager.isRunning {
                    Button(action: { webServerManager.stopServer() }) {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .buttonStyle(ProminentActionButtonStyle(tint: .red))
                } else {
                    Button(action: { webServerManager.startServer() }) {
                        Label("開始", systemImage: "play.fill")
                    }
                    .buttonStyle(ProminentActionButtonStyle(tint: .green))
                }
            }

            if webServerManager.isRunning {
                Divider()
                HStack(spacing: 10) {
                    StatPill(icon: "clock", label: "稼働時間", value: webServerManager.uptimeString)
                    StatPill(icon: "number", label: "ポート", value: "\(webServerManager.targetPort)")
                    if webServerManager.autoStopEnabled {
                        StatPill(icon: "timer", label: "自動停止まで", value: remainingTimeString, valueColor: .orange)
                    }
                    Spacer()
                }
            }
        }
        .dashboardCard()
        .animation(.easeInOut(duration: 0.25), value: webServerManager.isRunning)
    }

    @ViewBuilder
    private var statusDetail: some View {
        if webServerManager.isRunning, let url = webServerManager.serverURL {
            CopyableText(text: url, font: .system(size: 12, design: .monospaced))
        } else if webServerManager.statusMessage.contains("❌") {
            Text(webServerManager.statusMessage.replacingOccurrences(of: "❌ ", with: ""))
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("「開始」を押すと、同じWi-Fi内のiPhoneやブラウザから視聴できます")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var remainingTimeString: String {
        let remaining = max(0, (webServerManager.autoStopIntervalMinutes * 60) - Int(Date().timeIntervalSince(webServerManager.serverStartTime ?? Date())))
        return String(format: "%d分 %02d秒", remaining / 60, remaining % 60)
    }
}

// MARK: - リソースゲージ
struct ResourceGauge: View {
    let label: String
    let value: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            Gauge(value: min(max(value, 0), 100), in: 0...100) {
                Text(label)
            } currentValueLabel: {
                Text("\(Int(value))")
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .scaleEffect(0.85)
            .frame(width: 52, height: 52)

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
