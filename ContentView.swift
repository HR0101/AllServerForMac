import SwiftUI
import CoreServices
import UniformTypeIdentifiers
import Charts
import Darwin
import Combine


enum NavigationSelection: Hashable {
    case home
    case favorites
    case trash
    case album(UUID)
    case year(Int)
    case month(Int, Int)
}

struct CPUDataPoint: Identifiable {
    let id = UUID()
    let time: Int
    let value: Double
}

class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0.0
    @Published var memoryUsage: Double = 0.0
    @Published var cpuHistory: [CPUDataPoint] = []

    private var timer: Timer?
    private var previousInfo: host_cpu_load_info?
    private var counter = 0

    init() {
        for i in 0..<30 {
            cpuHistory.append(CPUDataPoint(time: i - 30, value: 0))
        }
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func updateStats() {
        let cpu = getCPUUsage()
        let mem = getMemoryUsage()

        DispatchQueue.main.async {
            self.cpuUsage = cpu
            self.memoryUsage = mem
            self.counter += 1
            self.cpuHistory.append(CPUDataPoint(time: self.counter, value: cpu))
            if self.cpuHistory.count > 30 {
                self.cpuHistory.removeFirst()
            }
        }
    }

    private func getCPUUsage() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var cpuLoadInfo = host_cpu_load_info()

        let result = withUnsafeMutablePointer(to: &cpuLoadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }

        if result == KERN_SUCCESS {
            if let prev = previousInfo {
                let userDiff = Double(cpuLoadInfo.cpu_ticks.0 - prev.cpu_ticks.0)
                let sysDiff = Double(cpuLoadInfo.cpu_ticks.1 - prev.cpu_ticks.1)
                let idleDiff = Double(cpuLoadInfo.cpu_ticks.2 - prev.cpu_ticks.2)
                let niceDiff = Double(cpuLoadInfo.cpu_ticks.3 - prev.cpu_ticks.3)

                let totalTicks = userDiff + sysDiff + idleDiff + niceDiff
                let activeTicks = userDiff + sysDiff + niceDiff

                previousInfo = cpuLoadInfo
                return totalTicks > 0 ? (activeTicks / totalTicks) * 100.0 : 0.0
            } else {
                previousInfo = cpuLoadInfo
                return 0.0
            }
        }
        return 0.0
    }

    private func getMemoryUsage() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let active = Double(stats.active_count) * Double(vm_page_size)
            let wire = Double(stats.wire_count) * Double(vm_page_size)
            let compressed = Double(stats.compressor_page_count) * Double(vm_page_size)

            let usedMemory = active + wire + compressed
            let physicalMemory = Double(ProcessInfo.processInfo.physicalMemory)

            return physicalMemory > 0 ? (usedMemory / physicalMemory) * 100.0 : 0.0
        }
        return 0.0
    }
}

// MARK: - メインビュー
struct ContentView: View {
    @StateObject private var dataManager: VideoDataManager
    @StateObject private var webServerManager: WebServerManager

    @State private var selection: NavigationSelection? = .home

    @State private var isShowingAddAlbumSheet = false
    @State private var newAlbumName = ""
    @State private var newAlbumType: AlbumType = .video
    @State private var albumToDelete: Album?

    @State private var isSidebarTargeted = false
    @State private var showSidebarMixedContentAlert = false
    @State private var pendingSidebarFolderURL: URL?
    @State private var sidebarMixedContentInfo = ""

    @State private var isShowingStorageManager = false

    @StateObject private var coordinator = PlaybackCoordinator()
    @StateObject private var appSettings = AppSettings()

    init() {
        let manager = VideoDataManager()
        _dataManager = StateObject(wrappedValue: manager)
        _webServerManager = StateObject(wrappedValue: WebServerManager(dataManager: manager))
    }

    var body: some View {
        Group {
            // 再生中はライブラリ画面（サイドバー/ツールバー含む）ごとプレイヤーに差し替え、
            // 他のUIが前面に残らない完全な全画面にする（元アプリと同じ方式）。
            if let mode = coordinator.mode {
                playerOverlay(for: mode)
                    .ignoresSafeArea()
            } else {
                libraryView
            }
        }
        .environmentObject(coordinator)
        .environmentObject(appSettings)
    }

    /// 再生中はウィンドウ全体を占有するプレイヤー
    @ViewBuilder
    private func playerOverlay(for mode: PlaybackCoordinator.Mode) -> some View {
        switch mode {
        case .single(let playlist, let current):
            VideoPlayerView(videos: playlist, currentVideo: current, dataManager: dataManager)
        case .multi(let videos):
            MultiVideoPlayerView(videos: videos, dataManager: dataManager)
        case .slideshow(let videos):
            SlideshowPlayerView(videos: videos, dataManager: dataManager)
        case .splitPlay(let video, let splitCount):
            SplitVideoPlayerView(video: video, splitCount: splitCount, dataManager: dataManager)
        }
    }

    private var libraryView: some View {
        NavigationSplitView {
            ZStack {
                sidebarList
                if isSidebarTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        )
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: { isShowingStorageManager = true }) {
                        Label("ストレージ管理", systemImage: "internaldrive")
                    }
                    .help("ストレージの内訳とクリーンアップ")
                }
            }
            .sheet(isPresented: $isShowingStorageManager) {
                StorageManagerView(dataManager: dataManager)
            }
        } detail: {
            NavigationStack {
                switch selection {
                case .home:
                    HomeView(dataManager: dataManager, webServerManager: webServerManager)
                        .navigationTitle("ホーム")
                case .favorites:
                    LibraryCategoryView(kind: .favorites, dataManager: dataManager)
                        .navigationTitle("お気に入り")
                case .trash:
                    LibraryCategoryView(kind: .trash, dataManager: dataManager)
                        .navigationTitle("ゴミ箱")
                case .year(let year):
                    LibraryCategoryView(kind: .year(year), dataManager: dataManager)
                        .navigationTitle("\(String(year))年")
                case .month(let year, let month):
                    LibraryCategoryView(kind: .month(year, month), dataManager: dataManager)
                        .navigationTitle("\(String(year))年\(month)月")
                case .album(let albumID):
                    if let album = dataManager.albums.first(where: { $0.id == albumID }) {
                        AlbumDetailView(album: album, dataManager: dataManager)
                            .navigationTitle(album.name)
                    } else {
                        ContentUnavailableView("アルバムが見つかりません", systemImage: "questionmark.folder")
                    }
                case .none:
                    ContentUnavailableView("サイドバーから項目を選択してください", systemImage: "sidebar.left")
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isSidebarTargeted) { providers in
            return handleDropOnSidebar(providers: providers)
        }
        .alert("異なるメディアタイプの混在", isPresented: $showSidebarMixedContentAlert) {
            Button("動画アルバムとして作成") {
                if let url = pendingSidebarFolderURL {
                    Task { await dataManager.importFolder(folderURL: url, as: .video); pendingSidebarFolderURL = nil }
                }
            }
            Button("画像アルバムとして作成") {
                if let url = pendingSidebarFolderURL {
                    Task { await dataManager.importFolder(folderURL: url, as: .photo); pendingSidebarFolderURL = nil }
                }
            }
            Button("キャンセル", role: .cancel) { pendingSidebarFolderURL = nil }
        } message: {
            Text("\(sidebarMixedContentInfo)\nどちらのタイプのアルバムとして作成しますか？指定したタイプ以外のファイルは無視されます。")
        }
    }

    private var sidebarList: some View {
        List(selection: $selection) {
            Section {
                NavigationLink(value: NavigationSelection.home) {
                    Label("ホーム", systemImage: "house.fill")
                }
            }

            Section(header: Text("ライブラリ")) {
                if let allVideos = dataManager.albums.first(where: { $0.name == VideoDataManager.allVideosAlbumName }) {
                    NavigationLink(value: NavigationSelection.album(allVideos.id)) {
                        sidebarRowLabel("すべての動画", systemImage: "film.stack", count: nonTrashedCount(in: allVideos))
                    }
                }
                if let allPhotos = dataManager.albums.first(where: { $0.name == VideoDataManager.allPhotosAlbumName }) {
                    NavigationLink(value: NavigationSelection.album(allPhotos.id)) {
                        sidebarRowLabel("すべての画像", systemImage: "photo.stack", count: nonTrashedCount(in: allPhotos))
                    }
                }
                NavigationLink(value: NavigationSelection.favorites) {
                    sidebarRowLabel("お気に入り", systemImage: "heart.fill", count: dataManager.favoriteVideos.count)
                }
                NavigationLink(value: NavigationSelection.trash) {
                    sidebarRowLabel("ゴミ箱", systemImage: "trash.fill", count: dataManager.trashedVideos.count)
                }
            }

            Section(header:
                HStack {
                    Text("アルバム")
                    Spacer()
                    Button(action: { isShowingAddAlbumSheet = true }) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("新規アルバムを作成")
                }
            ) {
                ForEach(dataManager.albums.filter { $0.name != VideoDataManager.allVideosAlbumName && $0.name != VideoDataManager.allPhotosAlbumName }) { album in
                    NavigationLink(value: NavigationSelection.album(album.id)) {
                        sidebarRowLabel(album.name, systemImage: album.type == .photo ? "photo.on.rectangle.angled" : "folder.fill", count: nonTrashedCount(in: album))
                    }
                    .contextMenu {
                        Button("削除", role: .destructive) {
                            albumToDelete = album
                        }
                    }
                }
            }

            if !dateSections.isEmpty {
                Section(header: Text("日付")) {
                    ForEach(dateSections, id: \.year) { section in
                        DisclosureGroup {
                            ForEach(section.months, id: \.self) { month in
                                NavigationLink(value: NavigationSelection.month(section.year, month)) {
                                    Label("\(month)月", systemImage: "calendar")
                                }
                            }
                        } label: {
                            NavigationLink(value: NavigationSelection.year(section.year)) {
                                Label("\(String(section.year))年", systemImage: "calendar")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(SidebarListStyle())
        .sheet(isPresented: $isShowingAddAlbumSheet) {
            addAlbumSheet
        }
        .alert(item: $albumToDelete) { album in
            Alert(
                title: Text("アルバムの削除"),
                message: Text("「\(album.name)」を削除しますか？アルバム内のファイルは「ALL VIDEOS」または「ALL PHOTOS」に残ります。"),
                primaryButton: .destructive(Text("削除")) {
                    dataManager.deleteAlbum(albumID: album.id)
                    if selection == .album(album.id) {
                        selection = .home
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    // 注意: List(selection:) + NavigationLink(value:) の行に .badge を付けると
    // macOS では選択が機能しなくなるため、件数はラベル内のテキストで表示する
    private func sidebarRowLabel(_ title: String, systemImage: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// ゴミ箱を除いたアルバム内アイテム数
    private func nonTrashedCount(in album: Album) -> Int {
        let trashed = Set(dataManager.trashedVideos.map { $0.id })
        return album.videoIDs.filter { !trashed.contains($0) }.count
    }

    /// 作成日（なければ取込日）から年>月の階層を作る（ゴミ箱を除く・新しい順）
    private var dateSections: [(year: Int, months: [Int])] {
        let cal = Calendar.current
        let active = dataManager.videos.filter { !$0.isInTrash }
        let byYear = Dictionary(grouping: active) { cal.component(.year, from: $0.creationDate ?? $0.importDate) }
        return byYear.keys.sorted(by: >).map { year in
            let months = Set((byYear[year] ?? []).map { cal.component(.month, from: $0.creationDate ?? $0.importDate) })
            return (year, months.sorted(by: >))
        }
    }

    private var addAlbumSheet: some View {
        VStack(spacing: 18) {
            IconTile(icon: "rectangle.stack.badge.plus", tint: .accentColor, size: 44)
                .padding(.top, 6)

            VStack(spacing: 4) {
                Text("新規アルバム")
                    .font(.headline)
                Text("名前とタイプを選んで作成します")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("アルバム名", text: $newAlbumName)
                .textFieldStyle(.roundedBorder)

            Picker("タイプ", selection: $newAlbumType) {
                Label("動画", systemImage: "film").tag(AlbumType.video)
                Label("画像", systemImage: "photo").tag(AlbumType.photo)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Button("キャンセル") {
                    isShowingAddAlbumSheet = false
                    newAlbumName = ""
                    newAlbumType = .video
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("作成") {
                    dataManager.createAlbum(name: newAlbumName, type: newAlbumType)
                    isShowingAddAlbumSheet = false
                    newAlbumName = ""
                    newAlbumType = .video
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(newAlbumName.isEmpty || newAlbumName == VideoDataManager.allVideosAlbumName || newAlbumName == VideoDataManager.allPhotosAlbumName)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 320)
    }

    private func handleDropOnSidebar(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                DispatchQueue.main.async {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                        let counts = dataManager.scanFolder(folderURL: url)
                        if counts.videoCount > 0 && counts.photoCount > 0 {
                            self.sidebarMixedContentInfo = "動画: \(counts.videoCount)件, 画像: \(counts.photoCount)件"
                            self.pendingSidebarFolderURL = url
                            self.showSidebarMixedContentAlert = true
                        } else if counts.photoCount > 0 {
                            Task { await dataManager.importFolder(folderURL: url, as: .photo) }
                        } else {
                            Task { await dataManager.importFolder(folderURL: url, as: .video) }
                        }
                    }
                }
            }
        }
        return true
    }
}

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

// MARK: - AlbumDetailView
struct AlbumDetailView: View {
    let album: Album
    @ObservedObject var dataManager: VideoDataManager

    @State private var isTargeted = false
    @State private var selectedVideoIDs = Set<UUID>()
    @State private var showMixedContentAlert = false
    @State private var pendingFolderURL: URL?
    @State private var mixedContentInfo = ""
    @State private var lastSelectedVideoID: UUID?
    @State private var previewItem: VideoItem?
    @State private var searchText = ""
    @State private var showMoveToNewAlbumAlert = false
    @State private var newAlbumNameForMove = ""
    @State private var pendingMoveVideoIDs: [UUID] = []
    @FocusState private var focusedVideoID: UUID?

    // 分割再生用
    @State private var showSplitSheet = false
    @State private var splitCount: Int = 4
    @State private var splitTargetVideo: VideoItem?

    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var appSettings: AppSettings

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: max(2, Int(appSettings.columnCount)))
    }

    /// 検索・並べ替えを適用した表示アイテム（動画＋画像、ゴミ箱を除く）
    private var displayedItems: [VideoItem] {
        dataManager.videos
            .filter { album.videoIDs.contains($0.id) && !$0.isInTrash }
            .filtered(bySearch: searchText)
            .sorted(by: appSettings.sortOrder)
    }

    /// このアルバムの動画のみ（表示順）
    private var albumVideoItems: [VideoItem] {
        displayedItems.filter { $0.mediaType == .video }
    }

    /// 現在の選択のうち動画のみ（表示順）
    private var selectedVideoItems: [VideoItem] {
        displayedItems.filter { selectedVideoIDs.contains($0.id) && $0.mediaType == .video }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                let items = displayedItems

                // 背景タップで選択解除（カードタップ時は内側のジェスチャーが優先される）
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedVideoIDs.removeAll()
                        lastSelectedVideoID = nil
                    }

                if items.isEmpty {
                    if searchText.isEmpty { emptyState } else { noResultsState }
                } else {
                    grid(items)
                }

                if isTargeted {
                    dropOverlay
                }
            }

            Divider()
            MediaGridControlBar()
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "タイトルを検索")
        .toolbar {
            // ランダム再生（選択不要・このアルバムの動画をシャッフルして連続再生）
            ToolbarItem(placement: .primaryAction) {
                if !albumVideoItems.isEmpty {
                    Button {
                        coordinator.playRandom(from: albumVideoItems)
                    } label: {
                        Label("ランダム再生", systemImage: "shuffle")
                    }
                    .help("このアルバムの動画をシャッフルして再生")
                }
            }

            if !selectedVideoIDs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Text("\(selectedVideoIDs.count)項目を選択中")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    if selectedVideoItems.count >= 2 {
                        Button {
                            coordinator.playMulti(selectedVideoItems)
                        } label: {
                            Label("同時再生", systemImage: "square.grid.2x2.fill")
                        }
                        .help("選択した動画を同期再生（最大9本）")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if selectedVideoItems.count >= 2 {
                        Button {
                            coordinator.startSlideshow(selectedVideoItems)
                        } label: {
                            Label("スライドショー", systemImage: "play.square.stack")
                        }
                        .help("選択した動画をスライドショー再生")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if selectedVideoItems.count == 1, let video = selectedVideoItems.first {
                        Button {
                            splitTargetVideo = video
                            showSplitSheet = true
                        } label: {
                            Label("分割再生", systemImage: "rectangle.split.2x2")
                        }
                        .help("選択した動画を指定数で分割して同時再生")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive, action: deleteSelectedVideos) {
                        Label("削除", systemImage: "trash")
                    }
                    .help("選択した項目を完全に削除")
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            return handleDrop(providers: providers)
        }
        .alert("異なるメディアタイプの混在", isPresented: $showMixedContentAlert) {
            Button("現在のアルバムのタイプ (\(album.type.displayName)) としてインポート") {
                if let url = pendingFolderURL {
                    Task { await dataManager.importFolder(folderURL: url, as: album.type); pendingFolderURL = nil }
                }
            }
            Button("キャンセル", role: .cancel) { pendingFolderURL = nil }
        } message: {
            Text("\(mixedContentInfo)\n指定したタイプ (\(album.type.displayName)) 以外のファイルは無視されます。")
        }
        .sheet(item: $previewItem) { item in
            MediaPreviewView(item: item, dataManager: dataManager)
        }
        .alert("新規アルバムに移動", isPresented: $showMoveToNewAlbumAlert) {
            TextField("アルバム名", text: $newAlbumNameForMove)
            Button("作成して移動") {
                let name = newAlbumNameForMove.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !pendingMoveVideoIDs.isEmpty,
                      let newID = dataManager.createAlbum(name: name, type: album.type) else { return }
                dataManager.moveVideos(videoIDs: pendingMoveVideoIDs, from: album.id, to: newID)
                pendingMoveVideoIDs = []
                selectedVideoIDs.removeAll()
                lastSelectedVideoID = nil
            }
            Button("キャンセル", role: .cancel) { pendingMoveVideoIDs = [] }
        } message: {
            Text("移動先の新しいアルバム名を入力してください。")
        }
        .sheet(isPresented: $showSplitSheet) {
            VStack(spacing: 20) {
                Text("分割再生")
                    .font(.headline)
                if let video = splitTargetVideo {
                    Text(video.originalFilename)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Stepper("分割数: \(splitCount)", value: $splitCount, in: 2...9)
                    .frame(width: 200)
                Text("動画を\(splitCount)等分して\(splitCount)画面で同時再生します")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button("キャンセル") { showSplitSheet = false }
                        .keyboardShortcut(.cancelAction)
                    Button("再生") {
                        showSplitSheet = false
                        if let video = splitTargetVideo {
                            coordinator.playSplit(video: video, splitCount: splitCount)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(30)
            .frame(minWidth: 320)
        }
    }

    // MARK: - Grid + keyboard navigation

    private func grid(_ items: [VideoItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(items) { video in
                        MediaGridItem(
                            video: video,
                            dataManager: dataManager,
                            isSelected: selectedVideoIDs.contains(video.id),
                            showTitle: appSettings.showTitles,
                            showRemoveFromAlbum: album.name != VideoDataManager.allVideosAlbumName && album.name != VideoDataManager.allPhotosAlbumName,
                            onSingleTap: { flags in
                                handleGridSelection(for: video, in: items, flags: flags)
                                focusedVideoID = video.id
                            },
                            onDoubleTap: { openFile(video) },
                            onOpen: { openFile(video) },
                            onOpenExternal: { openFileExternal(video) },
                            onReveal: { revealInFinder(video) },
                            onRemoveFromAlbum: {
                                dataManager.removeVideosFromAlbum(videoIDs: [video.id], albumID: album.id)
                            },
                            onDelete: {
                                dataManager.deleteVideos(videoIDs: [video.id])
                            },
                            onToggleFavorite: {
                                dataManager.toggleFavorite(videoIDs: effectiveTargetIDs(for: video))
                            },
                            onMoveToTrash: {
                                dataManager.moveToTrash(videoIDs: effectiveTargetIDs(for: video))
                                selectedVideoIDs.removeAll()
                                lastSelectedVideoID = nil
                            },
                            currentAlbumID: album.id,
                            onMoveToAlbum: { targetID in
                                dataManager.moveVideos(videoIDs: effectiveTargetIDs(for: video), from: album.id, to: targetID)
                                selectedVideoIDs.removeAll()
                                lastSelectedVideoID = nil
                            },
                            onMoveToNewAlbum: {
                                pendingMoveVideoIDs = effectiveTargetIDs(for: video)
                                newAlbumNameForMove = ""
                                showMoveToNewAlbumAlert = true
                            }
                        )
                        .id(video.id)
                        .focusable()
                        .focusEffectDisabled()
                        .focused($focusedVideoID, equals: video.id)
                    }
                }
                .padding(16)
            }
            .onKeyPress(phases: .down) { press in
                handleGridKey(press, items: items, proxy: proxy)
            }
            .onAppear {
                // グリッドにフォーカスを持たせて onKeyPress を有効化する
                if focusedVideoID == nil, let first = items.first { focusedVideoID = first.id }
            }
        }
    }

    /// 矢印キーでフォーカス移動、Enter/Option+Spaceで再生
    private func handleGridKey(_ press: KeyPress, items: [VideoItem], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }

        // 再生キー（Enter / Option+Space）はフォーカス未確定でも動作させる
        switch press.key {
        case .return:
            playFromGrid(items: items); return .handled
        case .space where press.modifiers.contains(.option):
            playFromGrid(items: items); return .handled
        default:
            break
        }

        let cols = max(2, Int(appSettings.columnCount))
        guard let focused = focusedVideoID, let index = items.firstIndex(where: { $0.id == focused }) else {
            let first = items[0].id
            focusedVideoID = first
            selectedVideoIDs = [first]
            lastSelectedVideoID = first
            return .handled
        }

        var nextIndex: Int?
        switch press.key {
        case .upArrow: if index - cols >= 0 { nextIndex = index - cols }
        case .downArrow: if index + cols < items.count { nextIndex = index + cols }
        case .leftArrow: if index > 0 { nextIndex = index - 1 }
        case .rightArrow: if index < items.count - 1 { nextIndex = index + 1 }
        default: return .ignored
        }

        if let nextIndex, items.indices.contains(nextIndex) {
            let id = items[nextIndex].id
            focusedVideoID = id
            selectedVideoIDs = [id]
            lastSelectedVideoID = id
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            return .handled
        }
        return .ignored
    }

    /// 選択が複数なら同時再生、単一/フォーカス対象を通常再生
    private func playFromGrid(items: [VideoItem]) {
        let selectedVideos = selectedVideoItems
        if selectedVideos.count > 1 {
            coordinator.playMulti(selectedVideos)
        } else if let focused = focusedVideoID, let item = items.first(where: { $0.id == focused }) {
            openFile(item)
        } else if let first = items.first {
            openFile(first)
        }
    }

    private var noResultsState: some View {
        ContentUnavailableView(
            "該当する項目がありません",
            systemImage: "magnifyingglass",
            description: Text("「\(searchText)」に一致するタイトルは見つかりませんでした")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("メディアがありません")
                .font(.title3.weight(.semibold))
            Text("ファイルやフォルダをここにドロップして追加")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(48)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7]))
                .foregroundStyle(.quaternary)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                Text("ドロップして追加")
                    .font(.title3.weight(.semibold))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8]))
                .padding(10)
        )
        .allowsHitTesting(false)
    }

    // MARK: - Actions

    // アプリ内プレイヤーで開く（動画は全画面プレイヤー、画像はプレビュー）
    private func openFile(_ video: VideoItem) {
        if video.mediaType == .video {
            coordinator.playSingle(playlist: albumVideoItems, current: video)
        } else {
            previewItem = video
        }
    }

    // QuickTime Player など外部のデフォルトアプリで開く
    private func openFileExternal(_ video: VideoItem) {
        guard let url = dataManager.fileURL(for: video) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder(_ video: VideoItem) {
        let url = dataManager.videoStorageURL.appendingPathComponent(video.internalFilename)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                DispatchQueue.main.async {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                        if isDirectory.boolValue {
                            let counts = dataManager.scanFolder(folderURL: url)

                            if (album.type == .video && counts.photoCount > 0) || (album.type == .photo && counts.videoCount > 0) {
                                self.mixedContentInfo = "動画: \(counts.videoCount)件, 画像: \(counts.photoCount)件"
                                self.pendingFolderURL = url
                                self.showMixedContentAlert = true
                            } else {
                                Task { await dataManager.importFolder(folderURL: url, as: album.type) }
                            }
                        } else {
                            Task { await dataManager.importMedia(from: url, to: album.id) }
                        }
                    }
                }
            }
        }
        return true
    }

    private func deleteSelectedVideos() {
        dataManager.deleteVideos(videoIDs: Array(selectedVideoIDs))
        selectedVideoIDs.removeAll()
        lastSelectedVideoID = nil
    }

    /// コンテキストメニュー操作の対象（右クリック対象が複数選択に含まれていれば選択全体）
    private func effectiveTargetIDs(for video: VideoItem) -> [UUID] {
        if selectedVideoIDs.contains(video.id) && selectedVideoIDs.count > 1 {
            return Array(selectedVideoIDs)
        }
        return [video.id]
    }

    private func handleGridSelection(for video: VideoItem, in videos: [VideoItem], flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift), let lastID = lastSelectedVideoID {
            guard let lastIndex = videos.firstIndex(where: { $0.id == lastID }), let currentIndex = videos.firstIndex(where: { $0.id == video.id }) else { return }
            let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
            let idsToSelect = videos[range].map { $0.id }
            for id in idsToSelect { selectedVideoIDs.insert(id) }
        } else if flags.contains(.command) {
            if selectedVideoIDs.contains(video.id) { selectedVideoIDs.remove(video.id) } else { selectedVideoIDs.insert(video.id); lastSelectedVideoID = video.id }
        } else {
            selectedVideoIDs.removeAll(); selectedVideoIDs.insert(video.id); lastSelectedVideoID = video.id
        }
    }
}

// MARK: - メディアグリッドアイテム（ホバー/選択ハイライト付き）
struct MediaGridItem: View {
    let video: VideoItem
    let dataManager: VideoDataManager
    let isSelected: Bool
    var showTitle: Bool = true
    let showRemoveFromAlbum: Bool
    let onSingleTap: (NSEvent.ModifierFlags) -> Void
    let onDoubleTap: () -> Void
    let onOpen: () -> Void
    let onOpenExternal: () -> Void
    let onReveal: () -> Void
    let onRemoveFromAlbum: () -> Void
    let onDelete: () -> Void
    var isTrashView: Bool = false
    var onToggleFavorite: () -> Void = {}
    var onMoveToTrash: () -> Void = {}
    var onRestore: () -> Void = {}
    var currentAlbumID: UUID? = nil
    var onMoveToAlbum: (UUID) -> Void = { _ in }
    var onMoveToNewAlbum: () -> Void = {}

    @State private var isHovering = false

    /// 移動先候補（システムアルバム・現在のアルバムを除き、メディアタイプが互換のもの）
    private var moveTargetAlbums: [Album] {
        dataManager.albums.filter { album in
            album.name != VideoDataManager.allVideosAlbumName &&
            album.name != VideoDataManager.allPhotosAlbumName &&
            album.id != currentAlbumID &&
            (album.type == .mixed
             || (video.mediaType == .video && album.type == .video)
             || (video.mediaType == .photo && album.type == .photo))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MacVideoThumbnailView(videoItem: video, dataManager: dataManager)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(color: .black.opacity(0.3), radius: 2)
                            .padding(7)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if video.mediaType == .video, video.duration > 0 {
                        Text(formatDuration(video.duration))
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.65)))
                            .padding(7)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if video.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .shadow(color: .black.opacity(0.35), radius: 2)
                            .padding(7)
                    }
                }

            if showTitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.originalFilename)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(MediaGridItem.itemFormatter.string(from: video.importDate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.12)
                      : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture(count: 1) {
            onSingleTap(NSApp.currentEvent?.modifierFlags ?? [])
        }
        .contextMenu {
            Button("開く") { onOpen() }
            Button("外部プレイヤーで開く") { onOpenExternal() }
            Button("Finderで表示") { onReveal() }
            Divider()
            if isTrashView {
                Button("元に戻す") { onRestore() }
                Button("完全に削除", role: .destructive) { onDelete() }
            } else {
                Button(video.isFavorite ? "お気に入りから外す" : "お気に入りに追加") { onToggleFavorite() }
                Menu("アルバムに移動") {
                    ForEach(moveTargetAlbums) { album in
                        Button(album.name) { onMoveToAlbum(album.id) }
                    }
                    if !moveTargetAlbums.isEmpty { Divider() }
                    Button("新規アルバム…") { onMoveToNewAlbum() }
                }
                if showRemoveFromAlbum {
                    Button("アルバムから外す") { onRemoveFromAlbum() }
                }
                Divider()
                Button("ゴミ箱に入れる", role: .destructive) { onMoveToTrash() }
            }
        }
    }

    private static let itemFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private func formatDuration(_ totalSeconds: TimeInterval) -> String {
        let secondsInt = Int(totalSeconds)
        return String(format: "%02d:%02d", secondsInt / 60, secondsInt % 60)
    }
}

// MARK: - 共有グリッド設定バー（ソート/サムネ位置/タイトル/列数）
struct MediaGridControlBar: View {
    @EnvironmentObject private var appSettings: AppSettings

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
                    Button(order.rawValue) { appSettings.sortOrder = order }
                }
            } label: {
                Label(appSettings.sortOrder.rawValue, systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()

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

            Button { appSettings.showTitles.toggle() } label: {
                Image(systemName: appSettings.showTitles ? "text.below.photo.fill" : "text.below.photo")
            }
            .help(appSettings.showTitles ? "タイトルを非表示" : "タイトルを表示")

            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                Slider(value: $appSettings.columnCount, in: 2...12, step: 1)
                    .frame(width: 140)
                Image(systemName: "square.grid.4x3.fill")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
}

// MARK: - お気に入り / ゴミ箱 カテゴリビュー
struct LibraryCategoryView: View {
    enum Kind: Hashable {
        case favorites
        case trash
        case year(Int)
        case month(Int, Int)
    }
    let kind: Kind
    @ObservedObject var dataManager: VideoDataManager

    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var appSettings: AppSettings

    @State private var selectedVideoIDs = Set<UUID>()
    @State private var lastSelectedVideoID: UUID?
    @State private var searchText = ""
    @State private var previewItem: VideoItem?
    @State private var showEmptyTrashAlert = false
    @State private var showMoveToNewAlbumAlert = false
    @State private var newAlbumNameForMove = ""
    @State private var pendingMoveVideoIDs: [UUID] = []
    @FocusState private var focusedVideoID: UUID?

    // 分割再生用
    @State private var showSplitSheet = false
    @State private var splitCount: Int = 4
    @State private var splitTargetVideo: VideoItem?

    private var isTrash: Bool { kind == .trash }

    private var sourceItems: [VideoItem] {
        let cal = Calendar.current
        switch kind {
        case .favorites:
            return dataManager.favoriteVideos
        case .trash:
            return dataManager.trashedVideos
        case .year(let y):
            return dataManager.videos.filter { !$0.isInTrash && cal.component(.year, from: $0.creationDate ?? $0.importDate) == y }
        case .month(let y, let m):
            return dataManager.videos.filter {
                guard !$0.isInTrash else { return false }
                let d = $0.creationDate ?? $0.importDate
                return cal.component(.year, from: d) == y && cal.component(.month, from: d) == m
            }
        }
    }
    private var displayedItems: [VideoItem] {
        sourceItems.filtered(bySearch: searchText).sorted(by: appSettings.sortOrder)
    }
    private var selectedVideoItems: [VideoItem] {
        displayedItems.filter { selectedVideoIDs.contains($0.id) && $0.mediaType == .video }
    }
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: max(2, Int(appSettings.columnCount)))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                let items = displayedItems
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selectedVideoIDs.removeAll(); lastSelectedVideoID = nil }

                if items.isEmpty {
                    emptyState
                } else {
                    grid(items)
                }
            }
            Divider()
            MediaGridControlBar()
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "タイトルを検索")
        .toolbar {
            if isTrash {
                ToolbarItem(placement: .primaryAction) {
                    if !dataManager.trashedVideos.isEmpty {
                        Button(role: .destructive) { showEmptyTrashAlert = true } label: {
                            Label("ゴミ箱を空にする", systemImage: "trash.slash")
                        }
                    }
                }
                if !selectedVideoIDs.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { dataManager.restoreFromTrash(videoIDs: Array(selectedVideoIDs)); selectedVideoIDs.removeAll() } label: {
                            Label("元に戻す", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    if !displayedItems.filter({ $0.mediaType == .video }).isEmpty {
                        Button { coordinator.playRandom(from: displayedItems.filter { $0.mediaType == .video }) } label: {
                            Label("ランダム再生", systemImage: "shuffle")
                        }
                    }
                }
                if selectedVideoItems.count >= 2 {
                    ToolbarItem(placement: .primaryAction) {
                        Button { coordinator.playMulti(selectedVideoItems) } label: {
                            Label("同時再生", systemImage: "square.grid.2x2.fill")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { coordinator.startSlideshow(selectedVideoItems) } label: {
                            Label("スライドショー", systemImage: "play.square.stack")
                        }
                    }
                }
                if selectedVideoItems.count == 1, let video = selectedVideoItems.first {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            splitTargetVideo = video
                            showSplitSheet = true
                        } label: {
                            Label("分割再生", systemImage: "rectangle.split.2x2")
                        }
                        .help("選択した動画を指定数で分割して同時再生")
                    }
                }
            }
        }
        .sheet(item: $previewItem) { MediaPreviewView(item: $0, dataManager: dataManager) }
        .alert("ゴミ箱を空にしますか？", isPresented: $showEmptyTrashAlert) {
            Button("空にする", role: .destructive) { dataManager.emptyTrash() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は取り消せません。ファイルが完全に削除されます。")
        }
        .alert("新規アルバムに移動", isPresented: $showMoveToNewAlbumAlert) {
            TextField("アルバム名", text: $newAlbumNameForMove)
            Button("作成して追加") {
                let name = newAlbumNameForMove.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !pendingMoveVideoIDs.isEmpty,
                      let newID = dataManager.createAlbum(name: name, type: .mixed) else { return }
                dataManager.addVideosToAlbum(videoIDs: pendingMoveVideoIDs, albumID: newID)
                pendingMoveVideoIDs = []
                selectedVideoIDs.removeAll()
            }
            Button("キャンセル", role: .cancel) { pendingMoveVideoIDs = [] }
        } message: {
            Text("作成する新しいアルバム名を入力してください。")
        }
        .sheet(isPresented: $showSplitSheet) {
            VStack(spacing: 20) {
                Text("分割再生")
                    .font(.headline)
                if let video = splitTargetVideo {
                    Text(video.originalFilename)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Stepper("分割数: \(splitCount)", value: $splitCount, in: 2...9)
                    .frame(width: 200)
                Text("動画を\(splitCount)等分して\(splitCount)画面で同時再生します")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button("キャンセル") { showSplitSheet = false }
                        .keyboardShortcut(.cancelAction)
                    Button("再生") {
                        showSplitSheet = false
                        if let video = splitTargetVideo {
                            coordinator.playSplit(video: video, splitCount: splitCount)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(30)
            .frame(minWidth: 320)
        }
    }

    private func grid(_ items: [VideoItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(items) { video in
                        MediaGridItem(
                            video: video,
                            dataManager: dataManager,
                            isSelected: selectedVideoIDs.contains(video.id),
                            showTitle: appSettings.showTitles,
                            showRemoveFromAlbum: false,
                            onSingleTap: { flags in handleSelection(for: video, in: items, flags: flags); focusedVideoID = video.id },
                            onDoubleTap: { open(video) },
                            onOpen: { open(video) },
                            onOpenExternal: { if let url = dataManager.fileURL(for: video) { NSWorkspace.shared.open(url) } },
                            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([dataManager.videoStorageURL.appendingPathComponent(video.internalFilename)]) },
                            onRemoveFromAlbum: {},
                            onDelete: { dataManager.deleteVideos(videoIDs: targetIDs(for: video)) },
                            isTrashView: isTrash,
                            onToggleFavorite: { dataManager.toggleFavorite(videoIDs: targetIDs(for: video)) },
                            onMoveToTrash: { dataManager.moveToTrash(videoIDs: targetIDs(for: video)); selectedVideoIDs.removeAll() },
                            onRestore: { dataManager.restoreFromTrash(videoIDs: targetIDs(for: video)); selectedVideoIDs.removeAll() },
                            currentAlbumID: nil,
                            onMoveToAlbum: { targetID in
                                dataManager.addVideosToAlbum(videoIDs: targetIDs(for: video), albumID: targetID)
                                selectedVideoIDs.removeAll()
                            },
                            onMoveToNewAlbum: {
                                pendingMoveVideoIDs = targetIDs(for: video)
                                newAlbumNameForMove = ""
                                showMoveToNewAlbumAlert = true
                            }
                        )
                        .id(video.id)
                        .focusable()
                        .focusEffectDisabled()
                        .focused($focusedVideoID, equals: video.id)
                    }
                }
                .padding(16)
            }
            .onKeyPress(phases: .down) { press in handleKey(press, items: items, proxy: proxy) }
            .onAppear {
                if focusedVideoID == nil, let first = items.first { focusedVideoID = first.id }
            }
        }
    }

    private func open(_ video: VideoItem) {
        if video.mediaType == .video {
            coordinator.playSingle(playlist: displayedItems.filter { $0.mediaType == .video }, current: video)
        } else {
            previewItem = video
        }
    }

    private func targetIDs(for video: VideoItem) -> [UUID] {
        if selectedVideoIDs.contains(video.id) && selectedVideoIDs.count > 1 { return Array(selectedVideoIDs) }
        return [video.id]
    }

    private func handleSelection(for video: VideoItem, in videos: [VideoItem], flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift), let lastID = lastSelectedVideoID,
           let lastIndex = videos.firstIndex(where: { $0.id == lastID }),
           let currentIndex = videos.firstIndex(where: { $0.id == video.id }) {
            let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
            for id in videos[range].map({ $0.id }) { selectedVideoIDs.insert(id) }
        } else if flags.contains(.command) {
            if selectedVideoIDs.contains(video.id) { selectedVideoIDs.remove(video.id) } else { selectedVideoIDs.insert(video.id); lastSelectedVideoID = video.id }
        } else {
            selectedVideoIDs = [video.id]; lastSelectedVideoID = video.id
        }
    }

    private func handleKey(_ press: KeyPress, items: [VideoItem], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }

        // 再生キー（Enter / Option+Space）はフォーカス未確定でも動作させる
        switch press.key {
        case .return:
            playFocused(items: items); return .handled
        case .space where press.modifiers.contains(.option):
            playFocused(items: items); return .handled
        default:
            break
        }

        let cols = max(2, Int(appSettings.columnCount))
        guard let focused = focusedVideoID, let index = items.firstIndex(where: { $0.id == focused }) else {
            let first = items[0].id
            focusedVideoID = first; selectedVideoIDs = [first]; lastSelectedVideoID = first
            return .handled
        }
        var nextIndex: Int?
        switch press.key {
        case .upArrow: if index - cols >= 0 { nextIndex = index - cols }
        case .downArrow: if index + cols < items.count { nextIndex = index + cols }
        case .leftArrow: if index > 0 { nextIndex = index - 1 }
        case .rightArrow: if index < items.count - 1 { nextIndex = index + 1 }
        default: return .ignored
        }
        if let nextIndex, items.indices.contains(nextIndex) {
            let id = items[nextIndex].id
            focusedVideoID = id; selectedVideoIDs = [id]; lastSelectedVideoID = id
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            return .handled
        }
        return .ignored
    }

    private func playFocused(items: [VideoItem]) {
        let selected = selectedVideoItems
        if selected.count > 1 {
            coordinator.playMulti(selected)
        } else if let focused = focusedVideoID, let item = items.first(where: { $0.id == focused }) {
            open(item)
        } else if let first = items.first {
            open(first)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            isTrash ? "ゴミ箱は空です" : "お気に入りはありません",
            systemImage: isTrash ? "trash" : "heart",
            description: Text(isTrash ? "削除した項目はここに移動します" : "グリッドの右クリックメニューからお気に入りに追加できます")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - AccessLogView
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
