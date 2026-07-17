import AppKit
import Charts
import SwiftUI

// MARK: - HomeView（ダッシュボード）
struct HomeView: View {
    @ObservedObject var dataManager: VideoDataManager
    @ObservedObject var webServerManager: WebServerManager
    @ObservedObject private var duplicateCheckStatus: DuplicateCheckStatus
    @ObservedObject private var linkedFolderScanStatus: LinkedFolderScanStatus
    @StateObject private var systemMonitor = SystemMonitor()

    @State private var isShowingAccessLog = false
    @State private var isShowingStorageManager = false
    @State private var logFilter: Int = 0 // 0: 全て, 1: 動画本体, 2: サムネ, 3: その他

    init(dataManager: VideoDataManager, webServerManager: WebServerManager) {
        self.dataManager = dataManager
        self.webServerManager = webServerManager
        self.duplicateCheckStatus = dataManager.duplicateCheckStatus
        self.linkedFolderScanStatus = dataManager.linkedFolderScanStatus
    }

    var body: some View {
        ZStack {
            NeomorphicHomeBackground()
            ScrollView {
                VStack(spacing: DS.cardSpacing) {
                    ServerHeroCard(webServerManager: webServerManager)

                    // カードごとの高さが異なるため，行の高さを強制するLazyVGridは使わない。
                    // 左右のカラムを独立して積むことで，縦長カードの横に空白が残らない。
                    HStack(alignment: .top, spacing: DS.cardSpacing) {
                        VStack(spacing: DS.cardSpacing) {
                            connectionCard
                            scheduleCard
                            duplicateCheckCard
                            storageCard
                        }
                        .frame(maxWidth: .infinity, alignment: .top)

                        VStack(spacing: DS.cardSpacing) {
                            securityCard
                            resourcesCard
                            linkedFolderCard
                            if !dataManager.linkedFolderConflicts.isEmpty {
                                linkedFolderConflictCard
                            }
                            logsCard
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .frame(maxWidth: 1040)
                .padding(.horizontal, 30)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
            }
        }
        .tint(NeomorphicTheme.accent)
        .foregroundStyle(NeomorphicTheme.ink)
        .preferredColorScheme(.light)
        .sheet(isPresented: $isShowingAccessLog) {
            AccessLogView(webServerManager: webServerManager)
        }
        .sheet(isPresented: $isShowingStorageManager) {
            StorageManagerView(dataManager: dataManager)
        }
    }

    // MARK: 重複チェックカード
    private var duplicateCheckCard: some View {
        let checkedAlbums = duplicateCheckStatus.checkedAlbums
        let uncheckedAlbums = duplicateCheckStatus.uncheckedAlbums
        let totalCount = checkedAlbums.count + uncheckedAlbums.count

        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "checkmark.seal.fill", tint: .mint, title: "素材検品", subtitle: "DUPLICATE INSPECTION")

            Toggle(isOn: $dataManager.isAutoDuplicateCheckEnabled) {
                Text("バックグラウンドで自動チェック")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("オフにすると、インポート後などにバックグラウンドで自動実行される重複チェックを停止します。アルバム内の「重複チェック」ボタンによる手動実行には影響しません。")

            HStack(spacing: 10) {
                DuplicateCheckCountBadge(title: "チェック済み", count: checkedAlbums.count, tint: .green)
                DuplicateCheckCountBadge(title: "未チェック", count: uncheckedAlbums.count, tint: .orange)
            }

            if totalCount == 0 {
                Text("対象アルバムはありません。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else if duplicateCheckStatus.isAutoChecking {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: duplicateCheckStatus.progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(.mint)
                    Text(duplicateCheckStatus.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                Text(duplicateCheckStatus.statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await dataManager.checkAllAlbumsForDuplicatesNow() }
            } label: {
                Label("今すぐすべてチェック", systemImage: "checkmark.seal.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .disabled(duplicateCheckStatus.isAutoChecking || dataManager.isDuplicateCheckRunning || totalCount == 0)
            .help("自動チェックのオン/オフに関わらず、対象アルバムの重複をまとめて今すぐチェックします。")

            Divider()

            duplicateAlbumList(title: "未チェック", albums: uncheckedAlbums, emptyMessage: "未チェックのアルバムはありません。")
            duplicateAlbumList(title: "チェック済み", albums: checkedAlbums, emptyMessage: "チェック済みのアルバムはありません。")
        }
        .dashboardCard()
    }

    // MARK: リンクフォルダ更新カード
    private var linkedFolderCard: some View {
        let count = dataManager.linkedFolderCount
        let status = linkedFolderScanStatus
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "folder.badge.gearshape", tint: .cyan, title: "素材搬入", subtitle: "INGEST FOLDERS")

            SettingRow(label: "リンク中のフォルダ") {
                Text("\(count)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }

            if status.isScanning {
                linkedFolderScanProgress(status)
            } else {
                Text("紐づけたフォルダに追加・削除したメディアは、下のボタンを押したときに取り込まれます。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if count > 0 && !status.statusMessage.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                        Text(status.statusMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            Button {
                Task { await dataManager.rescanAllLinkedFolders() }
            } label: {
                Label(status.isScanning ? "更新中…" : "リンクフォルダを更新", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(status.isScanning || count == 0)

            if count == 0 {
                Text("フォルダを紐づけるには、アルバムを開いてツールバーの「フォルダ紐づけ」を使ってください。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dashboardCard()
    }

    /// リンクフォルダ更新中の進捗表示（スピナー・進捗バー・現在のフォルダ名・件数）。
    @ViewBuilder
    private func linkedFolderScanProgress(_ status: LinkedFolderScanStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("リンクフォルダを更新中…")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if status.totalCount > 0 {
                    Text("\(min(status.processedCount + 1, status.totalCount)) / \(status.totalCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: Double(status.processedCount), total: Double(max(status.totalCount, 1)))
                .progressViewStyle(.linear)
                .tint(.cyan)

            if let name = status.currentFolderName {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.cyan)
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if status.processedItemsInCurrentFolder > 0 {
                        Text("\(status.processedItemsInCurrentFolder)件取り込み")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.cyan.opacity(0.1))
        )
    }

    // MARK: フォルダ紐づけ候補カード
    private var linkedFolderConflictCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(
                icon: "folder.badge.questionmark",
                tint: .yellow,
                title: "フォルダ紐づけ候補",
                subtitle: "同名フォルダの選択"
            )

            ForEach(dataManager.linkedFolderConflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.stack.fill")
                            .foregroundStyle(.yellow)
                            .font(.system(size: 12))
                        Text(conflict.albumName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }

                    ForEach(conflict.candidates) { candidate in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.folderPath)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(candidate.folderPath)
                                Text("\(candidate.matchCount)件一致")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                dataManager.confirmLinkedFolderCandidate(candidate)
                            } label: {
                                Label("選択", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(NeomorphicTheme.surface)
                                .shadow(color: .white.opacity(0.86), radius: 4, x: -3, y: -3)
                                .shadow(color: NeomorphicTheme.shadow.opacity(0.22), radius: 7, x: 4, y: 4)
                        )
                    }
                }
                .padding(.vertical, 2)

                if conflict.id != dataManager.linkedFolderConflicts.last?.id {
                    Divider()
                }
            }
        }
        .dashboardCard()
    }

    private func duplicateAlbumList(title: String, albums: [Album], emptyMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if albums.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(albums.prefix(5)) { album in
                    HStack(spacing: 8) {
                        Text(album.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(album.videoIDs.count)件")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if albums.count > 5 {
                    Text("ほか\(albums.count - 5)件")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: 接続設定カード
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "network", tint: .blue, title: "送出設定", subtitle: "PORT / AUTO STOP")

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
            CardHeader(icon: "calendar.badge.clock", tint: .purple, title: "放送予定", subtitle: "DAILY SCHEDULE")

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
            CardHeader(icon: "lock.shield.fill", tint: .green, title: "アクセス制御", subtitle: "PIN / ACCESS LOG")

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
            CardHeader(icon: "gauge.with.dots.needle.50percent", tint: .orange, title: "送出機器", subtitle: "CPU / MEMORY LEVEL")

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
            CardHeader(icon: "internaldrive.fill", tint: .indigo, title: "素材庫", subtitle: "MEDIA INVENTORY")

            SettingRow(label: "総アイテム数") {
                Text("\(dataManager.videos.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
            SettingRow(label: "使用容量") {
                Text(dataManager.totalStorageSizeText)
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
                CardHeader(icon: "network.badge.shield.half.filled", tint: .teal, title: "回線ログ", subtitle: "LIVE ACCESS LOG")
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
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(NeomorphicTheme.surface)
                                .shadow(color: .white.opacity(0.72), radius: 2, x: -1, y: -1)
                                .shadow(color: NeomorphicTheme.shadow.opacity(0.16), radius: 4, x: 2, y: 2)
                        )
                    }
                }
                .frame(maxHeight: 240, alignment: .top)
                .clipped()
            }
        }
        .dashboardCard()
    }
}

// MARK: - Neomorphism Theme

private struct NeomorphicHomeBackground: View {
    var body: some View {
        CommandDeckBackground()
    }
}

private struct NeomorphicTile<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(NeomorphicTheme.surface)
                    .shadow(color: .white.opacity(0.92), radius: 8, x: -7, y: -7)
                    .shadow(color: NeomorphicTheme.shadow.opacity(0.32), radius: 16, x: 9, y: 9)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.65), lineWidth: 1)
            )
    }
}

// MARK: - サーバー状態ヒーローカード
struct ServerHeroCard: View {
    @ObservedObject var webServerManager: WebServerManager

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 22) {
                leftColumn
                    .frame(width: 470)
                rightColumn
                    .frame(maxWidth: .infinity)
            }

            VStack(spacing: 18) {
                leftColumn
                rightColumn
            }
        }
        .animation(.easeInOut(duration: 0.25), value: webServerManager.isRunning)
    }

    private var leftColumn: some View {
        VStack(spacing: 18) {
            serverControlTile

            HStack(spacing: 18) {
                NeomorphicSceneTile(
                    icon: "timer",
                    title: "Auto Stop",
                    value: webServerManager.autoStopEnabled ? "\(webServerManager.autoStopIntervalMinutes) min" : "Off",
                    tint: .orange
                )
                NeomorphicSceneTile(
                    icon: "lock.shield",
                    title: "PIN Scene",
                    value: webServerManager.authEnabled ? "Protected" : "Open LAN",
                    tint: .green
                )
            }
        }
    }

    private var rightColumn: some View {
        VStack(spacing: 18) {
            welcomePill
            analyticsTile
        }
    }

    private var serverControlTile: some View {
        NeomorphicTile(padding: 24) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Mac Media Server")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(NeomorphicTheme.ink)
                            Text(webServerManager.isRunning ? "Local Streaming" : "Standby Cooling")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(NeomorphicTheme.muted)
                        }
                    } icon: {
                        Image(systemName: "snowflake")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(NeomorphicTheme.ink)
                    }

                    Spacer()

                    Button(action: toggleServer) {
                        HStack(spacing: 8) {
                            Text(webServerManager.isRunning ? "On." : "Off.")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                            Image(systemName: "power")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(webServerManager.isRunning ? .white : NeomorphicTheme.muted)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(webServerManager.isRunning ? NeomorphicTheme.accent : NeomorphicTheme.surface)
                                .shadow(color: .white.opacity(0.9), radius: 4, x: -3, y: -3)
                                .shadow(color: NeomorphicTheme.shadow.opacity(0.28), radius: 6, x: 4, y: 4)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(webServerManager.isRunning ? "サーバーを停止" : "サーバーを開始")
                    .accessibilityLabel(webServerManager.isRunning ? "サーバーを停止" : "サーバーを開始")
                }

                HStack(spacing: 8) {
                    Image(systemName: "clock")
                    Text(webServerManager.isRunning ? webServerManager.uptimeString : "LAN内の視聴を待機")
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(NeomorphicTheme.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(NeomorphicTheme.surface)
                        .shadow(color: .white.opacity(0.9), radius: 3, x: -2, y: -2)
                        .shadow(color: NeomorphicTheme.shadow.opacity(0.22), radius: 5, x: 3, y: 3)
                )

                ServerArcGauge(isRunning: webServerManager.isRunning)
                    .frame(maxWidth: .infinity)

                statusDetail
            }
        }
    }

    @ViewBuilder
    private var statusDetail: some View {
        if webServerManager.isRunning, let url = webServerManager.serverURL {
            CopyableText(text: url, font: .system(size: 12, design: .monospaced), tint: NeomorphicTheme.accent)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if webServerManager.statusMessage.contains("❌") {
            Text(webServerManager.statusMessage.replacingOccurrences(of: "❌ ", with: ""))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            Text("「開始」を押すと、同じWi-Fi内のiPhoneやブラウザから視聴できます")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(NeomorphicTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var welcomePill: some View {
        NeomorphicTile(padding: 15) {
            HStack(spacing: 14) {
                Circle()
                    .fill(NeomorphicTheme.accent)
                    .frame(width: 46, height: 46)
                    .overlay(
                        Image(systemName: "play.rectangle.stack.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: .white.opacity(0.9), radius: 4, x: -3, y: -3)
                    .shadow(color: NeomorphicTheme.shadow.opacity(0.28), radius: 6, x: 4, y: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Hi, Local Server")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(NeomorphicTheme.ink)
                    Text(webServerManager.isRunning ? "1 server active" : "Server ready")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(NeomorphicTheme.muted)
                }

                Spacer()

                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(NeomorphicTheme.muted)
            }
        }
    }

    private var analyticsTile: some View {
        NeomorphicTile(padding: 22) {
            VStack(alignment: .leading, spacing: 17) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(NeomorphicTheme.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Power Analytics")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(NeomorphicTheme.ink)
                        Text("Daily Usage")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(NeomorphicTheme.muted)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(NeomorphicTheme.muted)
                        .padding(9)
                        .background(
                            Circle()
                                .fill(NeomorphicTheme.surface)
                                .shadow(color: .white.opacity(0.95), radius: 3, x: -2, y: -2)
                                .shadow(color: NeomorphicTheme.shadow.opacity(0.24), radius: 5, x: 3, y: 3)
                        )
                }

                VStack(spacing: 12) {
                    NeomorphicAnalyticsRow(icon: "antenna.radiowaves.left.and.right", title: "Local Relay", value: webServerManager.isRunning ? "Running | \(webServerManager.targetPort)" : "Idle | \(webServerManager.targetPort)")
                    NeomorphicAnalyticsRow(icon: "lock.shield", title: "PIN Security", value: webServerManager.authEnabled ? "Protected" : "Open LAN")
                    NeomorphicAnalyticsRow(icon: "list.bullet.rectangle", title: "Access Log", value: "\(webServerManager.accessLogs.count) entries")
                    NeomorphicAnalyticsRow(icon: "timer", title: "Auto Stop", value: webServerManager.autoStopEnabled ? "\(webServerManager.autoStopIntervalMinutes) minutes" : "Disabled")
                }
            }
        }
    }

    private var remainingTimeString: String {
        let remaining = max(0, (webServerManager.autoStopIntervalMinutes * 60) - Int(Date().timeIntervalSince(webServerManager.serverStartTime ?? Date())))
        return String(format: "%d分 %02d秒", remaining / 60, remaining % 60)
    }
    private func toggleServer() {
        if webServerManager.isRunning {
            webServerManager.stopServer()
        } else {
            webServerManager.startServer()
        }
    }
}

private struct ServerArcGauge: View {
    let isRunning: Bool

    private let tickCount = 42
    private let startAngle = -112.0
    private let endAngle = 112.0

    var body: some View {
        ZStack {
            ForEach(0..<tickCount, id: \.self) { index in
                let ratio = Double(index) / Double(tickCount - 1)
                Capsule()
                    .fill(tickColor(for: ratio))
                    .frame(width: 3, height: ratio > 0.74 ? 28 : 22)
                    .offset(y: -82)
                    .rotationEffect(.degrees(startAngle + (endAngle - startAngle) * ratio))
            }

            VStack(spacing: 2) {
                Text(isRunning ? "24°" : "18°")
                    .font(.system(size: 45, weight: .bold, design: .rounded))
                    .foregroundStyle(NeomorphicTheme.ink)
                    .monospacedDigit()
                Text(isRunning ? "Streaming" : "Standby")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(NeomorphicTheme.muted)
            }
            .offset(y: 28)
        }
        .frame(height: 190)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRunning ? "サーバー稼働中" : "サーバー待機中")
    }

    private func tickColor(for ratio: Double) -> Color {
        let activeLimit = isRunning ? 0.82 : 0.28
        if ratio > activeLimit {
            return NeomorphicTheme.shadow.opacity(0.18)
        }
        return ratio > 0.72 ? NeomorphicTheme.accent : NeomorphicTheme.ink.opacity(0.84)
    }
}

private struct NeomorphicSceneTile: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        NeomorphicTile(padding: 16) {
            VStack(alignment: .leading, spacing: 36) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(9)
                        .background(
                            Circle()
                                .fill(NeomorphicTheme.surface)
                                .shadow(color: .white.opacity(0.9), radius: 3, x: -2, y: -2)
                                .shadow(color: NeomorphicTheme.shadow.opacity(0.24), radius: 5, x: 3, y: 3)
                        )
                    Spacer()
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(NeomorphicTheme.muted)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(NeomorphicTheme.ink)
                        .lineLimit(1)
                    Text(value)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(NeomorphicTheme.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        }
    }
}

private struct NeomorphicAnalyticsRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NeomorphicTheme.muted)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(NeomorphicTheme.surface)
                        .shadow(color: .white.opacity(0.92), radius: 3, x: -2, y: -2)
                        .shadow(color: NeomorphicTheme.shadow.opacity(0.24), radius: 5, x: 3, y: 3)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(NeomorphicTheme.ink)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(NeomorphicTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(NeomorphicTheme.muted)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(NeomorphicTheme.surface)
                .shadow(color: .white.opacity(0.92), radius: 5, x: -4, y: -4)
                .shadow(color: NeomorphicTheme.shadow.opacity(0.25), radius: 8, x: 5, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.58), lineWidth: 1)
        )
    }
}

/// ライブ配信機器のレベルメーターを模した表示。ネットワークの稼働状態だけを表すため，
/// 実測値のように見せるランダムなアニメーションは使いません。
private struct BroadcastLevelMeter: View {
    let isRunning: Bool
    let port: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NETWORK LEVEL")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("TX / RX")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            levelRow(label: "TX", activeCount: isRunning ? 13 : 0)
            levelRow(label: "RX", activeCount: isRunning ? 10 : 0)

            HStack(spacing: 12) {
                BroadcastStatusLabel(label: "LAN", value: isRunning ? "LINK" : "IDLE", active: isRunning)
                BroadcastStatusLabel(label: "PORT", value: "\(port)", active: true)
                BroadcastStatusLabel(label: "PIN", value: "READY", active: true)
            }
        }
    }

    private func levelRow(label: String, activeCount: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)
            ForEach(0..<16, id: \.self) { index in
                Rectangle()
                    .fill(index < activeCount ? meterColor(for: index) : Color.white.opacity(0.1))
                    .frame(width: 7, height: index.isMultiple(of: 4) ? 13 : 9)
            }
        }
    }

    private func meterColor(for index: Int) -> Color {
        index >= 12 ? DS.signalAmber : DS.tallyGreen
    }
}

private struct BroadcastStatusLabel: View {
    let label: String
    let value: String
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? DS.tallyGreen : Color.secondary)
                .frame(width: 5, height: 5)
            Text("\(label) \(value)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 重複チェック件数バッジ
struct DuplicateCheckCountBadge: View {
    let title: String
    let count: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12))
        )
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
