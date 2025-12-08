import SwiftUI
import CoreServices
import UniformTypeIdentifiers

// ===================================
//  ContentView.swift (フォルダインポート・混在対応版)
// ===================================

struct ContentView: View {
    private enum ViewMode {
        case grid, list
    }
    
    @StateObject private var dataManager: VideoDataManager
    @StateObject private var webServerManager: WebServerManager
    
    @State private var selectedAlbumID: UUID?
    @State private var isShowingAddAlbumSheet = false
    @State private var newAlbumName = ""
    @State private var newAlbumType: AlbumType = .video
    
    @State private var albumToDelete: Album?
    @State private var viewMode: ViewMode = .grid
    @State private var searchText = ""
    @State private var selectedVideoIDs = Set<VideoItem.ID>()
    @State private var lastSelectedVideoID: VideoItem.ID?
    
    // ドロップターゲットの強調表示用
    @State private var isDetailTargeted = false
    @State private var isSidebarTargeted = false
    
    // ★ 追加: 混在コンテンツアラート用
    @State private var showMixedContentAlert = false
    @State private var pendingFolderURL: URL?
    @State private var mixedContentInfo = ""

    private let allVideosAlbumName = "ALL VIDEOS"
    private let columns = [GridItem(.adaptive(minimum: 160))]

    init() {
        let manager = VideoDataManager()
        _dataManager = StateObject(wrappedValue: manager)
        _webServerManager = StateObject(wrappedValue: WebServerManager(dataManager: manager))
    }
    
    var body: some View {
        NavigationSplitView {
            ZStack {
                albumList
                
                if isSidebarTargeted {
                    Color.accentColor.opacity(0.1)
                        .edgesIgnoringSafeArea(.all)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.accentColor, lineWidth: 4)
                                .padding(4)
                        )
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
            .onDrop(of: [.fileURL], isTargeted: $isSidebarTargeted) { providers in
                handleSidebarDrop(providers: providers)
            }
            
        } detail: {
            ZStack {
                detailView
                
                if isDetailTargeted {
                    Color.accentColor.opacity(0.1)
                        .edgesIgnoringSafeArea(.all)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.accentColor, lineWidth: 4)
                                .padding()
                        )
                    VStack {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.accentColor)
                        Text("ここにドロップして追加")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDetailTargeted) { providers in
                handleDetailDrop(providers: providers)
            }
        }
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .onAppear {
            webServerManager.startServer()
            if selectedAlbumID == nil {
                selectedAlbumID = dataManager.albums.first?.id
            }
        }
        .onDisappear { webServerManager.stopServer() }
        .sheet(isPresented: $isShowingAddAlbumSheet) { addAlbumSheet }
        .alert("アルバムを削除", isPresented: .constant(albumToDelete != nil), presenting: albumToDelete) { (album: Album) in
            Button("削除", role: .destructive) {
                dataManager.deleteAlbum(albumID: album.id)
                albumToDelete = nil
            }
            Button("キャンセル", role: .cancel) { albumToDelete = nil }
        } message: { (album: Album) in
            Text("このアルバムを削除しますか？\nアルバム内のビデオは「ALL VIDEOS」に残ります。")
        }
        // ★ 追加: 混在コンテンツ確認アラート
        .alert("フォルダ内に動画と画像が混在しています", isPresented: $showMixedContentAlert) {
            Button("動画アルバムとして作成") {
                if let url = pendingFolderURL {
                    Task { await dataManager.importFolder(folderURL: url, as: .video) }
                }
                pendingFolderURL = nil
            }
            Button("画像アルバムとして作成") {
                if let url = pendingFolderURL {
                    Task { await dataManager.importFolder(folderURL: url, as: .photo) }
                }
                pendingFolderURL = nil
            }
            Button("キャンセル", role: .cancel) {
                pendingFolderURL = nil
            }
        } message: {
            Text(mixedContentInfo + "\n\nどちらのアルバムとしてインポートしますか？\n選ばなかった種類のファイルは除外されます。")
        }
    }
    
    // MARK: - Subviews
    private var albumList: some View {
        let sortedAlbums = dataManager.albums.sorted { a, b in
            if a.name == allVideosAlbumName { return true }
            if b.name == allVideosAlbumName { return false }
            return a.name < b.name
        }
        
        return List(selection: $selectedAlbumID) {
            ForEach(sortedAlbums) { album in
                HStack {
                    Image(systemName: album.type == .photo ? "photo.on.rectangle" : "folder")
                        .foregroundColor(album.type == .photo ? .orange : .blue)
                    Text(album.name)
                }
                .tag(album.id)
            }
        }
        .navigationTitle("アルバム")
        .toolbar {
            ToolbarItemGroup {
                Button(action: { isShowingAddAlbumSheet = true }) {
                    Label("アルバムを追加", systemImage: "plus")
                }

                Button(role: .destructive, action: {
                    if let albumID = selectedAlbumID {
                        albumToDelete = dataManager.albums.first { $0.id == albumID }
                    }
                }) {
                    Label("選択中のアルバムを削除", systemImage: "trash")
                }
                .disabled(isDeleteAlbumDisabled())
            }
        }
    }
    
    @ViewBuilder
    private var detailView: some View {
        if let albumID = selectedAlbumID, let album = dataManager.albums.first(where: { $0.id == albumID }) {
            let videosInAlbum = dataManager.videos.filter { album.videoIDs.contains($0.id) }
            let filteredVideos = videosInAlbum.filter { video in
                searchText.isEmpty || video.originalFilename.localizedCaseInsensitiveContains(searchText)
            }
            
            if videosInAlbum.isEmpty && album.name != allVideosAlbumName {
                VStack(spacing: 20) {
                    placeholderView(message: "ツールバーのボタン、またはドラッグ＆ドロップで\nメディアを追加してください。")
                    
                    Button(action: openFileImporter) {
                        Label("ファイルを選択", systemImage: "square.and.arrow.down")
                            .font(.headline)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .navigationTitle(album.name)
            } else {
                VStack {
                    if filteredVideos.isEmpty {
                        Text(searchText.isEmpty ? "メディアがありません" : "「\(searchText)」に一致するメディアはありません。")
                            .foregroundColor(.secondary)
                            .padding()
                        Spacer()
                    } else if viewMode == .grid {
                        videoGridView(videos: filteredVideos)
                    } else {
                        videoListView(videos: filteredVideos)
                    }
                }
                .navigationTitle(album.name)
                .searchable(text: $searchText, prompt: "名前で検索")
                .toolbar {
                    ToolbarItem {
                        Button(role: .destructive, action: deleteSelectedVideos) {
                            Label("選択した項目を削除", systemImage: "trash")
                        }
                        .disabled(selectedVideoIDs.isEmpty)
                    }
                    ToolbarItem {
                        importButton
                    }
                    ToolbarItem {
                        Picker("表示形式", selection: $viewMode) {
                            Label("グリッド", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                            Label("リスト", systemImage: "list.bullet").tag(ViewMode.list)
                        }
                        .pickerStyle(.segmented)
                        .animation(.default, value: viewMode)
                    }
                }
            }
        } else {
            placeholderView(message: "アルバムを選択してください。")
        }
    }
    
    private var importButton: some View {
        Button(action: openFileImporter) {
            Label("インポート", systemImage: "square.and.arrow.down")
        }
        .disabled(selectedAlbumID == nil)
    }
    
    private func videoGridView(videos: [VideoItem]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(videos) { video in
                    Button(action: {
                        handleGridSelection(for: video, in: videos, flags: NSEvent.modifierFlags)
                    }) {
                        MacVideoThumbnailView(videoItem: video, storageURL: dataManager.videoStorageURL)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.accentColor, lineWidth: 4)
                                    .opacity(selectedVideoIDs.contains(video.id) ? 1 : 0)
                            )
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
                MacVideoThumbnailView(videoItem: video, storageURL: dataManager.videoStorageURL)
                    .frame(width: 80, height: 80)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.originalFilename)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                    if video.mediaType == .video {
                        Text("長さ: \(formatDuration(video.duration))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Text("画像")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Text("追加日: \(video.importDate, formatter: itemFormatter)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contextMenu { videoContextMenu(for: video) }
        }
    }

    private func placeholderView(message: String) -> some View {
        VStack {
            Text("項目がありません").font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    @ViewBuilder
    private func videoContextMenu(for video: VideoItem) -> some View {
        Button(role: .destructive) {
            if selectedVideoIDs.contains(video.id) {
                deleteSelectedVideos()
            } else {
                dataManager.deleteVideos(videoIDs: [video.id])
            }
        } label: {
            let count = selectedVideoIDs.contains(video.id) ? selectedVideoIDs.count : 1
            Label("\(count)項目を削除", systemImage: "trash")
        }
    }

    private var statusBar: some View {
        HStack {
            Text(webServerManager.statusMessage).font(.footnote).padding(.leading)
            Spacer()
            if !selectedVideoIDs.isEmpty {
                Text("\(selectedVideoIDs.count)項目を選択中")
                    .font(.footnote)
                    .padding(.trailing)
            }
        }
        .frame(height: 28)
        .background(.bar)
    }

    private var addAlbumSheet: some View {
        VStack(spacing: 20) {
            Text("新しいアルバム").font(.headline)
            
            VStack(alignment: .leading) {
                Text("名前:")
                TextField("アルバム名", text: $newAlbumName)
                    .textFieldStyle(.roundedBorder)
                
                Text("種類:")
                Picker("種類", selection: $newAlbumType) {
                    Text("動画アルバム").tag(AlbumType.video)
                    Text("画像アルバム").tag(AlbumType.photo)
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)
            
            HStack {
                Button("キャンセル") {
                    isShowingAddAlbumSheet = false
                    newAlbumName = ""
                }
                .keyboardShortcut(.cancelAction)
                
                Button("作成") {
                    if !newAlbumName.isEmpty {
                        dataManager.createAlbum(name: newAlbumName, type: newAlbumType)
                        isShowingAddAlbumSheet = false
                        newAlbumName = ""
                        newAlbumType = .video
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newAlbumName.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 300)
        .padding()
    }

    // MARK: - Functions
    
    // ★ 修正: サイドバーへのフォルダドロップ（スキャンして分岐）
    private func handleSidebarDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url else { return }
                    
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        // フォルダの中身をスキャン
                        Task {
                            let counts = await dataManager.scanFolder(folderURL: url)
                            
                            await MainActor.run {
                                if counts.videoCount > 0 && counts.photoCount > 0 {
                                    // 混在 -> アラートを表示して選択させる
                                    self.pendingFolderURL = url
                                    self.mixedContentInfo = "動画: \(counts.videoCount)本\n画像: \(counts.photoCount)枚"
                                    self.showMixedContentAlert = true
                                } else if counts.photoCount > 0 {
                                    // 画像のみ
                                    Task { await dataManager.importFolder(folderURL: url, as: .photo) }
                                } else if counts.videoCount > 0 {
                                    // 動画のみ
                                    Task { await dataManager.importFolder(folderURL: url, as: .video) }
                                } else {
                                    // 空フォルダ等は動画アルバムとして作成（または何もしない）
                                    Task { await dataManager.importFolder(folderURL: url, as: .video) }
                                }
                            }
                        }
                    }
                }
            }
        }
        return true
    }
    
    // 詳細ビューへのファイルドロップ（既存アルバムへの追加）
    private func handleDetailDrop(providers: [NSItemProvider]) -> Bool {
        var targetAlbumID = selectedAlbumID
        
        if let selectedID = selectedAlbumID,
           let selectedAlbum = dataManager.albums.first(where: { $0.id == selectedID }),
           (selectedAlbum.name == allVideosAlbumName || selectedAlbum.name == "ALL PHOTOS") {
            targetAlbumID = dataManager.albums.first(where: { $0.name != allVideosAlbumName && $0.name != "ALL PHOTOS" })?.id
        }
        
        guard let finalTargetID = targetAlbumID else { return false }
        
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        Task {
                            var isDir: ObjCBool = false
                            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                                // 既存アルバムへのフォルダ追加の場合は、そのアルバムのタイプに従ってインポート
                                if let album = dataManager.albums.first(where: { $0.id == finalTargetID }) {
                                    // importFolderだと新規アルバムになるので、中身を走査して個別インポート
                                    let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                                    for fileURL in contents ?? [] {
                                        await dataManager.importMedia(from: fileURL, to: finalTargetID)
                                    }
                                }
                            } else {
                                // 単一ファイルインポート（ここでVideoDataManager側で選別される）
                                await dataManager.importMedia(from: url, to: finalTargetID)
                            }
                        }
                    }
                }
            }
        }
        return true
    }
    
    private func isDeleteAlbumDisabled() -> Bool {
        guard let selectedID = selectedAlbumID,
              let selected = dataManager.albums.first(where: { $0.id == selectedID }) else {
            return true
        }
        
        if selected.name == allVideosAlbumName || selected.name == "ALL PHOTOS" {
            return true
        }
        return false
    }
    
    private func handleGridSelection(for video: VideoItem, in videos: [VideoItem], flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift), let lastID = lastSelectedVideoID {
            guard let lastIndex = videos.firstIndex(where: { $0.id == lastID }),
                  let currentIndex = videos.firstIndex(where: { $0.id == video.id }) else {
                return
            }
            let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
            let idsToSelect = videos[range].map { $0.id }
            for id in idsToSelect {
                selectedVideoIDs.insert(id)
            }
        } else if flags.contains(.command) {
            if selectedVideoIDs.contains(video.id) {
                selectedVideoIDs.remove(video.id)
            } else {
                selectedVideoIDs.insert(video.id)
                lastSelectedVideoID = video.id
            }
        } else {
            selectedVideoIDs.removeAll()
            selectedVideoIDs.insert(video.id)
            lastSelectedVideoID = video.id
        }
    }
    
    private func deleteSelectedVideos() {
        dataManager.deleteVideos(videoIDs: Array(selectedVideoIDs))
        selectedVideoIDs.removeAll()
        lastSelectedVideoID = nil
    }

    private func openFileImporter() {
        var targetAlbumID = selectedAlbumID
        
        if let selectedID = selectedAlbumID,
           let selectedAlbum = dataManager.albums.first(where: { $0.id == selectedID }),
           (selectedAlbum.name == allVideosAlbumName || selectedAlbum.name == "ALL PHOTOS") {
            targetAlbumID = dataManager.albums.first(where: { $0.name != allVideosAlbumName && $0.name != "ALL PHOTOS" })?.id
        }
        
        guard let finalTargetAlbumID = targetAlbumID else { return }
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .image]
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                Task {
                    await dataManager.importMedia(from: url, to: finalTargetAlbumID)
                }
            }
        }
    }
    
    private var itemFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }
    
    private func formatDuration(_ totalSeconds: TimeInterval) -> String {
        let secondsInt = Int(totalSeconds)
        let minutes = secondsInt / 60
        let seconds = secondsInt % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
