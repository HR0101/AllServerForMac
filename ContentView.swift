import SwiftUI
import CoreServices
import UniformTypeIdentifiers

// ===================================
//  ContentView.swift (最近の項目削除版)
// ===================================

enum NavigationSelection: Hashable {
    case home
    case album(UUID)
}

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
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 4).padding(4))
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
            .onDrop(of: [.fileURL], isTargeted: $isSidebarTargeted) { providers in
                handleSidebarDrop(providers: providers)
            }
            
        } detail: {
            switch selection {
            case .home:
                HomeView(dataManager: dataManager, webServerManager: webServerManager)
            case .album(let albumID):
                AlbumDetailView(albumID: albumID, dataManager: dataManager)
            case nil:
                Text("項目を選択してください").foregroundColor(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) { statusBar }
        .onAppear { webServerManager.startServer() }
        .onDisappear { webServerManager.stopServer() }
        .sheet(isPresented: $isShowingAddAlbumSheet) { addAlbumSheet }
        .alert("アルバムを削除", isPresented: .constant(albumToDelete != nil), presenting: albumToDelete) { (album: Album) in
            Button("削除", role: .destructive) {
                dataManager.deleteAlbum(albumID: album.id)
                if case .album(let id) = selection, id == album.id { selection = .home }
                albumToDelete = nil
            }
            Button("キャンセル", role: .cancel) { albumToDelete = nil }
        } message: { (album: Album) in Text("このアルバムを削除しますか？\nアルバム内のビデオは「ALL VIDEOS」に残ります。") }
        .alert("フォルダ内に動画と画像が混在しています", isPresented: $showSidebarMixedContentAlert) {
            Button("動画アルバムとして作成") { if let url = pendingSidebarFolderURL { Task { await dataManager.importFolder(folderURL: url, as: .video) } }; pendingSidebarFolderURL = nil }
            Button("画像アルバムとして作成") { if let url = pendingSidebarFolderURL { Task { await dataManager.importFolder(folderURL: url, as: .photo) } }; pendingSidebarFolderURL = nil }
            Button("キャンセル", role: .cancel) { pendingSidebarFolderURL = nil }
        } message: { Text(sidebarMixedContentInfo + "\n\nどちらのアルバムとしてインポートしますか？\n選ばなかった種類のファイルは除外されます。") }
    }
    
    private var sidebarList: some View {
        List(selection: $selection) {
            Section {
                NavigationLink(value: NavigationSelection.home) { Label("ホーム", systemImage: "house.fill") }
            }
            Section("ライブラリ") {
                let sortedAlbums = dataManager.albums.sorted { a, b in
                    if a.name == allVideosAlbumName { return true }
                    if b.name == allVideosAlbumName { return false }
                    return a.name < b.name
                }
                ForEach(sortedAlbums) { album in
                    NavigationLink(value: NavigationSelection.album(album.id)) {
                        HStack {
                            Image(systemName: album.type == .photo ? "photo.on.rectangle" : "folder")
                                .foregroundColor(album.type == .photo ? .orange : .blue)
                            Text(album.name)
                        }
                    }
                }
            }
        }
        .navigationTitle("ライブラリ")
        .toolbar {
            ToolbarItemGroup {
                Button(action: { isShowingAddAlbumSheet = true }) { Label("アルバムを追加", systemImage: "plus") }
                Button(role: .destructive, action: {
                    if case .album(let id) = selection, let album = dataManager.albums.first(where: { $0.id == id }) {
                        if !isDeleteAlbumDisabled(album: album) { albumToDelete = album }
                    }
                }) { Label("アルバムを削除", systemImage: "trash") }.disabled(isDeleteButtonDisabled)
            }
        }
    }
    
    private var isDeleteButtonDisabled: Bool {
        guard case .album(let id) = selection, let album = dataManager.albums.first(where: { $0.id == id }) else { return true }
        return isDeleteAlbumDisabled(album: album)
    }
    
    private func isDeleteAlbumDisabled(album: Album) -> Bool {
        if album.name == allVideosAlbumName || album.name == "ALL PHOTOS" { return true }
        return false
    }
    
    private var statusBar: some View {
        HStack {
            Text(webServerManager.statusMessage).font(.footnote).padding(.leading)
            Spacer()
        }
        .frame(height: 28).background(.bar)
    }
    
    private var addAlbumSheet: some View {
        VStack(spacing: 20) {
            Text("新しいアルバム").font(.headline)
            VStack(alignment: .leading) {
                Text("名前:")
                TextField("アルバム名", text: $newAlbumName).textFieldStyle(.roundedBorder)
                Text("種類:")
                Picker("種類", selection: $newAlbumType) {
                    Text("動画アルバム").tag(AlbumType.video)
                    Text("画像アルバム").tag(AlbumType.photo)
                }.pickerStyle(.segmented)
            }.padding(.horizontal)
            HStack {
                Button("キャンセル") { isShowingAddAlbumSheet = false; newAlbumName = "" }.keyboardShortcut(.cancelAction)
                Button("作成") { if !newAlbumName.isEmpty { dataManager.createAlbum(name: newAlbumName, type: newAlbumType); isShowingAddAlbumSheet = false; newAlbumName = ""; newAlbumType = .video } }.buttonStyle(.borderedProminent).disabled(newAlbumName.isEmpty).keyboardShortcut(.defaultAction)
            }.padding()
        }.frame(minWidth: 300).padding()
    }
    
    private func handleSidebarDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url else { return }
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        Task {
                            let counts = await dataManager.scanFolder(folderURL: url)
                            await MainActor.run {
                                if counts.videoCount > 0 && counts.photoCount > 0 {
                                    self.pendingSidebarFolderURL = url
                                    self.sidebarMixedContentInfo = "動画: \(counts.videoCount)本\n画像: \(counts.photoCount)枚"
                                    self.showSidebarMixedContentAlert = true
                                } else if counts.photoCount > 0 { Task { await dataManager.importFolder(folderURL: url, as: .photo) } }
                                else if counts.videoCount > 0 { Task { await dataManager.importFolder(folderURL: url, as: .video) } }
                                else { Task { await dataManager.importFolder(folderURL: url, as: .video) } }
                            }
                        }
                    }
                }
            }
        }
        return true
    }
}

// ===================================
//  HomeView (最近の項目削除・容量表示維持)
// ===================================

struct HomeView: View {
    @ObservedObject var dataManager: VideoDataManager
    @ObservedObject var webServerManager: WebServerManager
    @State private var showCacheClearedAlert = false
    @State private var totalSizeString: String = "計算中..."
    
    var videoCount: Int { dataManager.videos.filter { $0.mediaType == .video }.count }
    var photoCount: Int { dataManager.videos.filter { $0.mediaType == .photo }.count }
    var albumCount: Int { dataManager.albums.count }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                // ヘッダー
                VStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 60))
                        .foregroundColor(.accentColor)
                    Text("Video Server for Mac")
                        .font(.largeTitle.weight(.bold))
                    Text(webServerManager.statusMessage)
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        // コピー機能追加
                        .onTapGesture {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(webServerManager.statusMessage, forType: .string)
                        }
                }
                .padding(.top, 40)
                
                // 統計カード
                HStack(spacing: 20) {
                    StatCard(title: "動画", value: "\(videoCount)", icon: "film.fill", color: .cyan)
                    StatCard(title: "画像", value: "\(photoCount)", icon: "photo.fill", color: .orange)
                    StatCard(title: "アルバム", value: "\(albumCount)", icon: "folder.fill", color: .blue)
                    StatCard(title: "容量", value: totalSizeString, icon: "externaldrive.fill", color: .purple)
                }
                .padding(.horizontal)
                
                Divider()
                
                // メンテナンス機能
                VStack(alignment: .leading, spacing: 15) {
                    Text("メンテナンス").font(.title2.weight(.bold))
                    HStack {
                        Button(action: {
                            dataManager.clearThumbnailCache()
                            showCacheClearedAlert = true
                        }) {
                            HStack {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                Text("サムネイルキャッシュを削除")
                            }
                            .padding()
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        Spacer()
                    }
                    Text("iOS側で画像が表示されない場合や、サムネイルが黒くなる場合に実行してください。").font(.caption).foregroundColor(.secondary)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .cornerRadius(12)
                .padding(.horizontal)
                
                Spacer()
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("キャッシュを削除しました", isPresented: $showCacheClearedAlert) {
            Button("OK", role: .cancel) { }
        } message: { Text("次回iOSアプリで表示する際に、新しいサムネイルが再生成されます。") }
        .task {
            // 容量計算を実行
            totalSizeString = dataManager.calculateTotalStorageSize()
        }
        // データ変更時に容量を再計算
        .onChange(of: dataManager.videos) { _ in
            totalSizeString = dataManager.calculateTotalStorageSize()
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: icon).foregroundColor(color)
                Text(title).foregroundColor(.secondary)
            }.font(.headline)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .minimumScaleFactor(0.5) // 文字が長すぎる場合は小さくする
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

struct AlbumDetailView: View {
    let albumID: UUID
    @ObservedObject var dataManager: VideoDataManager
    
    @State private var viewMode: ViewMode = .grid
    @State private var searchText = ""
    @State private var selectedVideoIDs = Set<VideoItem.ID>()
    @State private var lastSelectedVideoID: VideoItem.ID?
    @State private var isDetailTargeted = false
    @State private var showDetailMixedContentAlert = false
    @State private var pendingDetailFolderURL: URL?
    @State private var detailMixedContentInfo = ""
    
    private enum ViewMode { case grid, list }
    private let columns = [GridItem(.adaptive(minimum: 160))]
    
    var body: some View {
        ZStack {
            if let album = dataManager.albums.first(where: { $0.id == albumID }) {
                content(album: album)
            } else {
                Text("アルバムが見つかりません")
            }
            if isDetailTargeted {
                Color.accentColor.opacity(0.1).edgesIgnoringSafeArea(.all)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.accentColor, lineWidth: 4).padding())
                VStack {
                    Image(systemName: "arrow.down.doc.fill").font(.system(size: 60)).foregroundColor(.accentColor)
                    Text("ここにドロップして追加").font(.title2).fontWeight(.bold).foregroundColor(.accentColor)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDetailTargeted) { providers in handleDetailDrop(providers: providers) }
        .alert("フォルダ内に動画と画像が混在しています", isPresented: $showDetailMixedContentAlert) {
            Button("インポートする") {
                if let url = pendingDetailFolderURL {
                    Task {
                        let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        for fileURL in contents ?? [] { await dataManager.importMedia(from: fileURL, to: albumID) }
                    }
                }
                pendingDetailFolderURL = nil
            }
            Button("キャンセル", role: .cancel) { pendingDetailFolderURL = nil }
        } message: { Text(detailMixedContentInfo + "\n\nこのアルバムの種類に合うファイルのみインポートしますか？") }
    }
    
    @ViewBuilder
    private func content(album: Album) -> some View {
        let videosInAlbum = dataManager.videos.filter { album.videoIDs.contains($0.id) }
        let filteredVideos = videosInAlbum.filter { video in
            searchText.isEmpty || video.originalFilename.localizedCaseInsensitiveContains(searchText)
        }
        
        VStack {
            if videosInAlbum.isEmpty && album.name != "ALL VIDEOS" && album.name != "ALL PHOTOS" {
                VStack(spacing: 20) {
                    Text("項目がありません").font(.headline)
                    Text("ツールバーのボタン、またはドラッグ＆ドロップで\nメディアを追加してください。").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button(action: openFileImporter) { Label("ファイルを選択", systemImage: "square.and.arrow.down").font(.headline).padding() }.buttonStyle(.borderedProminent)
                }
            } else {
                if filteredVideos.isEmpty && !videosInAlbum.isEmpty {
                    Text("一致する項目がありません").foregroundColor(.secondary); Spacer()
                } else if viewMode == .grid { videoGridView(videos: filteredVideos) } else { videoListView(videos: filteredVideos) }
            }
        }
        .navigationTitle(album.name)
        .searchable(text: $searchText, prompt: "名前で検索")
        .toolbar {
            ToolbarItem {
                Button(role: .destructive, action: deleteSelectedVideos) { Label("削除", systemImage: "trash") }.disabled(selectedVideoIDs.isEmpty)
            }
            ToolbarItem {
                Button(action: openFileImporter) { Label("インポート", systemImage: "square.and.arrow.down") }
            }
            ToolbarItem {
                Picker("表示形式", selection: $viewMode) {
                    Label("グリッド", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                    Label("リスト", systemImage: "list.bullet").tag(ViewMode.list)
                }.pickerStyle(.segmented)
            }
        }
    }
    
    private func videoGridView(videos: [VideoItem]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(videos) { video in
                    Button(action: { handleGridSelection(for: video, in: videos, flags: NSEvent.modifierFlags) }) {
                        MacVideoThumbnailView(videoItem: video, storageURL: dataManager.videoStorageURL)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 4).opacity(selectedVideoIDs.contains(video.id) ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { videoContextMenu(for: video) }
                }
            }
            .padding()
        }
    }
    
    private func videoListView(videos: [VideoItem]) -> some View {
        List(videos, selection: $selectedVideoIDs) { video in
            HStack(spacing: 15) {
                MacVideoThumbnailView(videoItem: video, storageURL: dataManager.videoStorageURL).frame(width: 80, height: 80)
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.originalFilename).fontWeight(.semibold).lineLimit(2)
                    if video.mediaType == .video { Text("長さ: \(formatDuration(video.duration))").font(.subheadline).foregroundColor(.secondary) }
                    else { Text("画像").font(.subheadline).foregroundColor(.secondary) }
                    Text("追加日: \(video.importDate, formatter: itemFormatter)").font(.caption).foregroundColor(.gray)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contextMenu { videoContextMenu(for: video) }
        }
    }
    
    @ViewBuilder
    private func videoContextMenu(for video: VideoItem) -> some View {
        Button(role: .destructive) {
            if selectedVideoIDs.contains(video.id) { deleteSelectedVideos() } else { dataManager.deleteVideos(videoIDs: [video.id]) }
        } label: {
            let count = selectedVideoIDs.contains(video.id) ? selectedVideoIDs.count : 1
            Label("\(count)項目を削除", systemImage: "trash")
        }
    }
    
    private func openFileImporter() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.movie, .image]
        if panel.runModal() == .OK {
            for url in panel.urls { Task { await dataManager.importMedia(from: url, to: albumID) } }
        }
    }
    
    private func handleDetailDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        Task {
                            var isDir: ObjCBool = false
                            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                                let counts = await dataManager.scanFolder(folderURL: url)
                                await MainActor.run {
                                    if counts.videoCount > 0 && counts.photoCount > 0 {
                                        self.pendingDetailFolderURL = url
                                        self.detailMixedContentInfo = "動画: \(counts.videoCount)本\n画像: \(counts.photoCount)枚"
                                        self.showDetailMixedContentAlert = true
                                    } else {
                                        Task {
                                            let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                                            for fileURL in contents ?? [] { await dataManager.importMedia(from: fileURL, to: albumID) }
                                        }
                                    }
                                }
                            } else { await dataManager.importMedia(from: url, to: albumID) }
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
        return String(format: "%d:%02d", secondsInt / 60, secondsInt % 60)
    }
}
