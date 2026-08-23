import AppKit
import Charts
import SwiftUI

// MARK: - HomeView（ダッシュボード）
struct HomeView: View {
    @ObservedObject var dataManager: LibraryViewModel
    @ObservedObject var webServerManager: ServerViewModel
    @ObservedObject private var duplicateCheckStatus: DuplicateCheckStatus
    @ObservedObject private var linkedFolderScanStatus: LinkedFolderScanStatus
    @StateObject private var systemMonitor = DashboardViewModel()
    @EnvironmentObject private var appSettings: AppSettings

    @State private var isShowingAccessLog = false
    @State private var isShowingStorageManager = false
    @State private var logFilter: Int = 0 // 0: 全て, 1: 動画本体, 2: サムネ, 3: その他
    /// ScrollView の実寸サイズ。段数の決定と「画面いっぱいまでカードを伸ばす」高さに使う。
    @State private var scrollSize: CGSize = CGSize(width: 1040, height: 800)

    init(dataManager: LibraryViewModel, webServerManager: ServerViewModel) {
        self.dataManager = dataManager
        self.webServerManager = webServerManager
        self.duplicateCheckStatus = dataManager.duplicateCheckStatus
        self.linkedFolderScanStatus = dataManager.linkedFolderScanStatus
    }

    var body: some View {
        ZStack {
            NeomorphicHomeBackground()
            ScrollView {
                let layout = DashboardLayout(scrollSize: scrollSize)
                VStack(spacing: DS.cardSpacing) {
                    ServerHeroCard(webServerManager: webServerManager, columnCount: layout.columnCount)
                        // ヒーローは自然な高さのまま。余った高さは下のカード側で吸わせる。
                        .fixedSize(horizontal: false, vertical: true)
                    cardColumns(layout)
                }
                .frame(
                    maxWidth: layout.contentWidth,
                    minHeight: layout.minContentHeight,
                    alignment: .top
                )
                .padding(.horizontal, DashboardLayout.horizontalPadding)
                .padding(.vertical, DashboardLayout.verticalPadding)
                .frame(maxWidth: .infinity)
                .animation(.spring(response: 0.42, dampingFraction: 0.86), value: layout.columnCount)
            }
            // GeometryReader はサイドバー側で表示が崩れる事例があるため、実寸は onGeometryChange で受け取る。
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                scrollSize = newSize
            }
        }
        .tint(NeomorphicTheme.accent)
        .foregroundStyle(NeomorphicTheme.ink)
        .preferredColorScheme(appSettings.neomorphicDarkBase ? .dark : .light)
        .sheet(isPresented: $isShowingAccessLog) {
            AccessLogView(webServerManager: webServerManager)
        }
        .sheet(isPresented: $isShowingStorageManager) {
            StorageManagerView(dataManager: dataManager)
        }
    }

    // MARK: カードの段組み

    /// カードごとに高さが大きく違うので、行の高さをそろえる LazyVGrid ではなく、
    /// 「今いちばん短い段に次のカードを積む」メーソンリー配置にする。
    /// 段数はウインドウ幅から決まるので、広げれば横に増え、狭めれば 1 列に畳まれる。
    ///
    /// 段の中身はすべて高さが可変（`dashboardCard()` が maxHeight: .infinity を持つ）なので、
    /// いちばん高い段に合わせて他の段が引き伸ばされ、余りは段内のカードで山分けされる。
    /// つまり段の下端がそろい、カード同士のあいだにも下にも空白が残らない。
    private func cardColumns(_ layout: DashboardLayout) -> some View {
        let columns = layout.distribute(visibleCards, height: estimatedHeight(of:))
        return HStack(alignment: .top, spacing: DS.cardSpacing) {
            ForEach(columns.indices, id: \.self) { index in
                VStack(spacing: DS.cardSpacing) {
                    ForEach(columns[index]) { card in
                        cardView(card)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    /// 表示するカードを重要度順に並べたもの。この順に短い段へ詰めていく。
    private var visibleCards: [DashboardCardID] {
        var cards: [DashboardCardID] = [.connection, .security, .schedule, .resources]
        if !dataManager.linkedFolderConflicts.isEmpty {
            cards.append(.linkedFolderConflict)
        }
        cards.append(contentsOf: [.linkedFolder, .storage, .duplicateCheck, .logs])
        return cards
    }

    @ViewBuilder
    private func cardView(_ card: DashboardCardID) -> some View {
        switch card {
        case .connection: connectionCard
        case .security: securityCard
        case .schedule: scheduleCard
        case .resources: resourcesCard
        case .linkedFolderConflict: linkedFolderConflictCard
        case .linkedFolder: linkedFolderCard
        case .storage: storageCard
        case .duplicateCheck: duplicateCheckCard
        case .logs: logsCard
        }
    }

    /// 段のバランス取りに使う概算の高さ。実測ではなく、開いている行数から見積もる。
    /// 多少ずれても見た目の左右差が少し出るだけなので、正確さより安定して同じ値が出ることを優先する。
    private func estimatedHeight(of card: DashboardCardID) -> CGFloat {
        switch card {
        case .connection:
            return 150 + (webServerManager.autoStopEnabled ? 38 : 0)
        case .security:
            return webServerManager.authEnabled ? 200 : 215
        case .schedule:
            return 100 + (webServerManager.scheduleEnabled ? 250 : 0)
        case .resources:
            return 257
        case .linkedFolderConflict:
            let candidates = dataManager.linkedFolderConflicts.reduce(0) { $0 + $1.candidates.count }
            return 60 + CGFloat(dataManager.linkedFolderConflicts.count) * 40 + CGFloat(candidates) * 56
        case .linkedFolder:
            return dataManager.linkedFolderCount > 0 ? 168 : 200
        case .storage:
            return 170
        case .duplicateCheck:
            let rows = min(duplicateCheckStatus.uncheckedAlbums.count, 6) + min(duplicateCheckStatus.checkedAlbums.count, 6)
            return 330 + CGFloat(rows) * 22
        case .logs:
            return filteredLogs.isEmpty ? 200 : 130 + CGFloat(min(filteredLogs.count, 12)) * 28
        }
    }

    // MARK: 重複チェックカード
    private var duplicateCheckCard: some View {
        let checkedAlbums = duplicateCheckStatus.checkedAlbums
        let uncheckedAlbums = duplicateCheckStatus.uncheckedAlbums
        let totalCount = checkedAlbums.count + uncheckedAlbums.count

        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "checkmark.seal.fill", tint: .mint, title: "重複チェック", subtitle: "同じ動画をまとめて検出")

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

            Spacer(minLength: 0)
        }
        .dashboardCard()
    }

    // MARK: フォルダ連携カード
    private var linkedFolderCard: some View {
        let count = dataManager.linkedFolderCount
        let status = linkedFolderScanStatus
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "folder.badge.gearshape", tint: .cyan, title: "フォルダ連携", subtitle: "Mac のフォルダから取り込み")

            Spacer(minLength: 0)

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

            Spacer(minLength: 0)

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
                subtitle: "同じ名前のフォルダが複数あります"
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

            Spacer(minLength: 0)
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

    // MARK: サーバー設定カード
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "network", tint: .blue, title: "サーバー設定", subtitle: "ポート番号 / 自動停止")

            Spacer(minLength: 0)

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

            Spacer(minLength: 0)

            Divider()

            Toggle(isOn: $webServerManager.autoStopEnabled) {
                Text("自動停止タイマー")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(webServerManager.isRunning)

            Spacer(minLength: 0)

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

            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.18), value: webServerManager.autoStopEnabled)
        .dashboardCard()
    }

    // MARK: 自動起動スケジュールカード
    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "calendar.badge.clock", tint: .purple, title: "自動起動スケジュール", subtitle: "毎日決まった時間に起動・停止")

            Spacer(minLength: 0)

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

            Spacer(minLength: 0)

            if !webServerManager.scheduleEnabled {
                Text("オンにすると、毎日決まった時刻にサーバーを起動し、指定した時刻にアプリごと終了します。Mac は電源につないだままにしてください。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: webServerManager.scheduleEnabled)
        .dashboardCard()
    }

    // MARK: セキュリティカード
    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "lock.shield.fill", tint: .green, title: "アクセス制御", subtitle: "PIN 認証 / アクセスログ")

            Spacer(minLength: 0)

            Toggle(isOn: $webServerManager.authEnabled) {
                Text("PIN認証を必須にする")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("オンにすると、Web・iOSアプリからのアクセスにPINが必要になります。")

            Spacer(minLength: 0)

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

            Spacer(minLength: 0)

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

    // MARK: Mac の負荷カード
    private var resourcesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "gauge.with.dots.needle.50percent", tint: .orange, title: "この Mac の負荷", subtitle: "CPU / メモリ使用率")

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
            .frame(minHeight: 90, maxHeight: .infinity)
        }
        .dashboardCard()
    }

    // MARK: ライブラリ容量カード
    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "internaldrive.fill", tint: .indigo, title: "ライブラリ容量", subtitle: "保存件数と使用容量")

            Spacer(minLength: 0)

            SettingRow(label: "総アイテム数") {
                Text("\(dataManager.videos.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            SettingRow(label: "使用容量") {
                Text(dataManager.totalStorageSizeText)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            Divider()

            Button(action: { isShowingStorageManager = true }) {
                Label("ストレージ管理を開く", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .dashboardCard()
    }

    /// 通信ログのフィルタ結果。カードの表示と段組みの高さ見積もりで共有する。
    private var filteredLogs: [AccessLogEntry] {
        webServerManager.accessLogs.filter { entry in
            switch logFilter {
            case 1: return entry.path.hasPrefix("/video/")
            case 2: return entry.path.hasPrefix("/thumbnail/")
            case 3: return !entry.path.hasPrefix("/video/") && !entry.path.hasPrefix("/thumbnail/")
            default: return true
            }
        }
    }

    // MARK: 通信ログカード
    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardHeader(icon: "network.badge.shield.half.filled", tint: .teal, title: "通信ログ", subtitle: "最近のアクセス")
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

            if filteredLogs.isEmpty {
                Text("まだアクセスがありません")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredLogs.prefix(40)) { entry in
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
                // カードに与えられた高さぶんだけ行が見える。はみ出したぶんは切り落とす。
                .frame(minHeight: 120, maxHeight: .infinity, alignment: .top)
                .clipped()
            }
        }
        .dashboardCard()
    }
}

// MARK: - 段組みレイアウト

/// ダッシュボードに並ぶカードの識別子。段組みの計算とビューの生成でこの並びを共有する。
private enum DashboardCardID: Identifiable, CaseIterable {
    case connection
    case security
    case schedule
    case resources
    case linkedFolderConflict
    case linkedFolder
    case storage
    case duplicateCheck
    case logs

    var id: Self { self }
}

/// ウインドウの実寸から段数・本文幅・「最低これだけは埋める高さ」を決める。
private struct DashboardLayout {
    static let horizontalPadding: CGFloat = 30
    static let verticalPadding: CGFloat = 30

    /// ScrollView の実寸（パディングを含む）。
    let scrollSize: CGSize

    /// 左右パディングを除いた、カードを並べられる幅。
    private var usableWidth: CGFloat {
        max(320, scrollSize.width - Self.horizontalPadding * 2)
    }

    /// 表示領域の高さぶんは埋めにいく。カードが少なくて下に空白が残るときは、
    /// この最低高さぶんだけ段が引き伸ばされ、カード自身が大きくなって空白を飲み込む。
    /// 中身のほうが高いときは効かないので、通常のスクロールを邪魔しない。
    var minContentHeight: CGFloat {
        max(0, scrollSize.height - Self.verticalPadding * 2)
    }

    /// 横に並べる段数。カード 1 枚あたり 350pt 前後を確保できるところで切り替える。
    var columnCount: Int {
        switch usableWidth {
        case ..<720: return 1
        case ..<1100: return 2
        case ..<1560: return 3
        default: return 4
        }
    }

    /// 段数ごとの上限幅。ウインドウを最大化してもカード 1 枚が間延びしないように抑える。
    var contentWidth: CGFloat {
        let cap: CGFloat
        switch columnCount {
        case 1: cap = 620
        case 2: cap = 1040
        case 3: cap = 1500
        default: cap = 1960
        }
        return min(usableWidth, cap)
    }

    /// 見積もり高さがいちばん小さい段へ順に詰め、そのあと段の高さがそろうまで詰め直す。
    ///
    /// 詰めるだけだと「カード 2 枚しかない段」が生まれ、そこが一番高い段に合わせて
    /// 引き伸ばされるとカードが間延びする。そこで、いちばん高い段からカードを 1 枚ずつ
    /// 別の段へ移し、最大の段が低くなる移動だけを採用する改善パスを回す。
    /// 見積もりだけで完結する決定的な計算なので、同じ状態なら毎回同じ並びになる。
    func distribute<Card>(_ cards: [Card], height: (Card) -> CGFloat) -> [[Card]] {
        guard columnCount > 1 else { return [cards] }

        var columns = [[Int]](repeating: [], count: columnCount)
        var filled = [CGFloat](repeating: 0, count: columnCount)
        let heights = cards.map(height)

        func add(_ index: Int, to column: Int) {
            columns[column].append(index)
            filled[column] += heights[index] + DS.cardSpacing
        }

        for index in cards.indices {
            add(index, to: filled.indices.min { filled[$0] < filled[$1] } ?? 0)
        }

        // 最大の段が下がらなくなるまで詰め直す。空回りしないよう回数は打ち切る。
        for _ in 0..<(cards.count * columnCount) {
            guard let tallest = filled.indices.max(by: { filled[$0] < filled[$1] }),
                  columns[tallest].count > 1 else { break }
            let currentMax = filled[tallest]

            var best: (card: Int, destination: Int, resultingMax: CGFloat)?
            for card in columns[tallest] {
                for destination in columns.indices where destination != tallest {
                    let moved = heights[card] + DS.cardSpacing
                    var next = filled
                    next[tallest] -= moved
                    next[destination] += moved
                    let resultingMax = next.max() ?? currentMax
                    if resultingMax < currentMax - 0.5,
                       resultingMax < (best?.resultingMax ?? .greatestFiniteMagnitude) {
                        best = (card, destination, resultingMax)
                    }
                }
            }

            guard let move = best else { break }
            columns[move.destination].append(move.card)
            columns[tallest].removeAll { $0 == move.card }
            let moved = heights[move.card] + DS.cardSpacing
            filled[tallest] -= moved
            filled[move.destination] += moved
        }

        // 段の中は元の並び順に戻して、読む順とレイアウトを大きくずらさない。
        return columns.map { $0.sorted().map { cards[$0] } }
    }
}
