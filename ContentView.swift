import SwiftUI
import CoreServices
import UniformTypeIdentifiers
import Charts
import Darwin
import Combine 


enum NavigationSelection: Hashable {
    case home
    case album(UUID)
}

// システムモニター
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
        // グラフの初期表示用（過去30秒分を0で埋める）
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

    private let allVideosAlbumName = "ALL VIDEOS"

    init() {
        let manager = VideoDataManager()
        _dataManager = StateObject(wrappedValue: manager)
        _webServerManager = StateObject(wrappedValue: WebServerManager(dataManager: manager))
    }
    
    var body: some View {
        NavigationSplitView {
            ZStack {
                sidebarList
                if isSidebarTargeted {
                    Color.accentColor.opacity(0.1)
                        .edgesIgnoringSafeArea(.all)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3))
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: { isShowingStorageManager = true }) {
                        Label("ストレージ管理", systemImage: "internaldrive")
                    }
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
                case .album(let albumID):
                    if let album = dataManager.albums.first(where: { $0.id == albumID }) {
                        AlbumDetailView(album: album, dataManager: dataManager)
                            .navigationTitle(album.name)
                    } else {
                        Text("アルバムが見つかりません").foregroundColor(.secondary)
                    }
                case .none:
                    Text("サイドバーから項目を選択してください").foregroundColor(.secondary)
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
                    Label("ホーム", systemImage: "house")
                }
            }
            
            Section(header: Text("ライブラリ")) {
                if let allVideos = dataManager.albums.first(where: { $0.name == "ALL VIDEOS" }) {
                    NavigationLink(value: NavigationSelection.album(allVideos.id)) {
                        Label("すべての動画", systemImage: "film")
                    }
                }
                if let allPhotos = dataManager.albums.first(where: { $0.name == "ALL PHOTOS" }) {
                    NavigationLink(value: NavigationSelection.album(allPhotos.id)) {
                        Label("すべての画像", systemImage: "photo.on.rectangle")
                    }
                }
            }
            
            Section(header:
                HStack {
                    Text("アルバム")
                    Spacer()
                    Button(action: { isShowingAddAlbumSheet = true }) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            ) {
                ForEach(dataManager.albums.filter { $0.name != "ALL VIDEOS" && $0.name != "ALL PHOTOS" }) { album in
                    NavigationLink(value: NavigationSelection.album(album.id)) {
                        Label(album.name, systemImage: album.type == .photo ? "photo.on.rectangle" : "folder")
                    }
                    .contextMenu {
                        Button("削除") {
                            albumToDelete = album
                        }
                    }
                }
            }
        }
        .listStyle(SidebarListStyle())
        .sheet(isPresented: $isShowingAddAlbumSheet) {
            VStack(spacing: 20) {
                Text("新規アルバム").font(.headline)
                TextField("アルバム名", text: $newAlbumName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Picker("タイプ", selection: $newAlbumType) {
                    Text("動画アルバム").tag(AlbumType.video)
                    Text("画像アルバム").tag(AlbumType.photo)
                }
                .pickerStyle(SegmentedPickerStyle())
                
                HStack {
                    Button("キャンセル") {
                        isShowingAddAlbumSheet = false
                        newAlbumName = ""
                        newAlbumType = .video
                    }
                    Spacer()
                    Button("作成") {
                        dataManager.createAlbum(name: newAlbumName, type: newAlbumType)
                        isShowingAddAlbumSheet = false
                        newAlbumName = ""
                        newAlbumType = .video
                    }
                    .disabled(newAlbumName.isEmpty || newAlbumName == "ALL VIDEOS" || newAlbumName == "ALL PHOTOS")
                }
            }
            .padding()
            .frame(width: 300)
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

// MARK: - HomeView
struct HomeView: View {
    @ObservedObject var dataManager: VideoDataManager
    @ObservedObject var webServerManager: WebServerManager
    @StateObject private var systemMonitor = SystemMonitor()

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                Image(systemName: "server.rack")
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)
                    .padding(.top, 20)
                
                Text("Mac Video Server")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                // サーバー設定・状態セクション
                VStack(spacing: 15) {
                    HStack {
                        Text("サーバー状態:")
                        Text(webServerManager.statusMessage)
                            .fontWeight(.bold)
                            .foregroundColor(webServerManager.statusMessage.contains("✅") ? .green : (webServerManager.statusMessage.contains("🛑") ? .secondary : .red))
                    }
                    
                    HStack {
                        Text("ポート番号:")
                        TextField("例: 8080", value: $webServerManager.targetPort, format: .number)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 80)
                            .multilineTextAlignment(.center)
                            .disabled(webServerManager.statusMessage.contains("✅"))
                        
                        Button(action: {
                            webServerManager.targetPort = 8080
                        }) {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(webServerManager.statusMessage.contains("✅"))
                        .help("デフォルト(8080)に戻す")
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("自動停止タイマー", isOn: $webServerManager.autoStopEnabled)
                            .disabled(webServerManager.statusMessage.contains("✅"))
                        
                        if webServerManager.autoStopEnabled {
                            HStack {
                                Text("停止までの時間:")
                                TextField("分", value: $webServerManager.autoStopIntervalMinutes, format: .number)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .frame(width: 60)
                                    .multilineTextAlignment(.trailing)
                                    .disabled(webServerManager.statusMessage.contains("✅"))
                                Text("分")
                            }
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    
                    HStack(spacing: 20) {
                        Button(action: {
                            webServerManager.startServer()
                        }) {
                            Label("開始", systemImage: "play.fill")
                        }
                        .disabled(webServerManager.statusMessage.contains("✅"))
                        
                        Button(action: {
                            webServerManager.stopServer()
                        }) {
                            Label("停止", systemImage: "stop.fill")
                        }
                        .disabled(!webServerManager.statusMessage.contains("✅"))
                    }
                    
                    if webServerManager.statusMessage.contains("✅") {
                        VStack(spacing: 4) {
                            HStack {
                                Text("稼働時間:")
                                Text(webServerManager.uptimeString)
                                    .monospacedDigit()
                            }
                            if webServerManager.autoStopEnabled {
                                HStack {
                                    Text("自動停止まで約:")
                                    let remaining = max(0, (webServerManager.autoStopIntervalMinutes * 60) - Int(Date().timeIntervalSince(webServerManager.serverStartTime ?? Date())))
                                    Text("\(remaining / 60)分 \(remaining % 60)秒")
                                        .monospacedDigit()
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                        .font(.footnote)
                        .padding(.top, 4)
                    }
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(12)
                .shadow(radius: 2)
                .frame(maxWidth: 350)
                
                // システムリソース＆グラフ表示セクション
                VStack(alignment: .leading, spacing: 10) {
                    Text("システムリソース")
                        .font(.headline)
                        .padding(.bottom, 4)
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("CPU使用率:")
                                Spacer()
                                Text(String(format: "%.1f %%", systemMonitor.cpuUsage))
                                    .monospacedDigit()
                                    .fontWeight(.bold)
                            }
                            HStack {
                                Text("メモリ使用率:")
                                Spacer()
                                Text(String(format: "%.1f %%", systemMonitor.memoryUsage))
                                    .monospacedDigit()
                                    .fontWeight(.bold)
                            }
                        }
                        .frame(width: 160)
                        
                        Spacer()
                    }
                    
                    // CPU使用率の折れ線（エリア）グラフ
                    Chart {
                        ForEach(systemMonitor.cpuHistory) { point in
                            LineMark(
                                x: .value("Time", point.time),
                                y: .value("CPU(%)", point.value)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Color.accentColor)
                            
                            AreaMark(
                                x: .value("Time", point.time),
                                y: .value("CPU(%)", point.value)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.accentColor.opacity(0.4), Color.accentColor.opacity(0.0)]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis(.hidden)
                    .frame(height: 100)
                    .padding(.top, 8)
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(12)
                .shadow(radius: 2)
                .frame(maxWidth: 350)
                
                // ストレージ情報セクション
                VStack(alignment: .leading, spacing: 10) {
                    Text("ストレージ情報").font(.headline)
                    HStack {
                        Text("総アイテム数:")
                        Spacer()
                        Text("\(dataManager.videos.count)")
                    }
                    HStack {
                        Text("使用容量:")
                        Spacer()
                        Text(dataManager.calculateTotalStorageSize())
                    }
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(12)
                .shadow(radius: 2)
                .frame(maxWidth: 350)
                
                Spacer()
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(NSColor.underPageBackgroundColor))
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

    private var columns: [GridItem] {
        Array(repeating: GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16), count: 3)
    }

    var body: some View {
        ZStack {
            let albumVideos = dataManager.videos.filter { album.videoIDs.contains($0.id) }
            
            if albumVideos.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                    Text("ここにファイルやフォルダをドロップして追加")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(albumVideos) { video in
                            VStack {
                                MacVideoThumbnailView(videoItem: video, storageURL: dataManager.videoStorageURL)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(selectedVideoIDs.contains(video.id) ? Color.accentColor : Color.clear, lineWidth: 3)
                                    )
                                    .onTapGesture(count: 2) {
                                        openFile(video)
                                    }
                                    .simultaneousGesture(
                                        TapGesture(count: 1).onEnded {
                                            if let event = NSApp.currentEvent {
                                                handleGridSelection(for: video, in: albumVideos, flags: event.modifierFlags)
                                            } else {
                                                handleGridSelection(for: video, in: albumVideos, flags: [])
                                            }
                                        }
                                    )
                                    .contextMenu {
                                        Button("開く") { openFile(video) }
                                        Button("Finderで表示") { revealInFinder(video) }
                                        Divider()
                                        if album.name != "ALL VIDEOS" && album.name != "ALL PHOTOS" {
                                            Button("アルバムから外す") {
                                                dataManager.removeVideosFromAlbum(videoIDs: [video.id], albumID: album.id)
                                            }
                                        }
                                        Button("完全に削除", role: .destructive) {
                                            dataManager.deleteVideos(videoIDs: [video.id])
                                        }
                                    }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(video.originalFilename)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    
                                    HStack {
                                        Text(itemFormatter.string(from: video.importDate))
                                        Spacer()
                                        if video.mediaType == .video {
                                            Text(formatDuration(video.duration))
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 4)
                            }
                        }
                    }
                    .padding()
                }
            }
            
            if isTargeted {
                Color.accentColor.opacity(0.2)
                    .edgesIgnoringSafeArea(.all)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.accentColor, lineWidth: 4)
                            .padding(2)
                    )
            }
        }
        .toolbar {
            if !selectedVideoIDs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: deleteSelectedVideos) {
                        Label("削除", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Text("\(selectedVideoIDs.count)項目を選択中")
                        .foregroundColor(.secondary)
                }
            }
        }
        .onTapGesture {
            selectedVideoIDs.removeAll()
            lastSelectedVideoID = nil
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
    }
    
    // MARK: - Actions
    
    private func openFile(_ video: VideoItem) {
        let url = dataManager.videoStorageURL.appendingPathComponent(video.internalFilename)
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
    
    private var itemFormatter: DateFormatter { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f }
    private func formatDuration(_ totalSeconds: TimeInterval) -> String {
        let secondsInt = Int(totalSeconds)
        return String(format: "%02d:%02d", secondsInt / 60, secondsInt % 60)
    }
}
