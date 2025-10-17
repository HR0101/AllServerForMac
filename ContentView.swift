import SwiftUI
import CoreServices

// ===================================
//  ContentView.swift (UI改善・ALL VIDEOS対応版)
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
    @State private var albumToDelete: Album?
    @State private var viewMode: ViewMode = .grid
    @State private var searchText = ""
    @State private var selectedVideoIDs = Set<VideoItem.ID>()
    @State private var lastSelectedVideoID: VideoItem.ID?

    // ★ 追加: 特別なアルバムの名前を定義
    private let allVideosAlbumName = "ALL VIDEOS"
    private let columns = [GridItem(.adaptive(minimum: 160))]

    init() {
        let manager = VideoDataManager()
        _dataManager = StateObject(wrappedValue: manager)
        _webServerManager = StateObject(wrappedValue: WebServerManager(dataManager: manager))
    }
    
    var body: some View {
        NavigationSplitView {
            albumList
                .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        } detail: {
            detailView
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
    }
    
    // MARK: - Subviews
    private var albumList: some View {
        // ★ 修正: ALL VIDEOSを常に先頭に表示する
        let sortedAlbums = dataManager.albums.sorted { a, b in
            if a.name == allVideosAlbumName { return true }
            if b.name == allVideosAlbumName { return false }
            return a.name < b.name
        }
        
        // ★ 修正: 複数の文があるため、明示的にreturnを追加
        return List(selection: $selectedAlbumID) {
            ForEach(sortedAlbums) { album in
                Label(album.name, systemImage: "folder")
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
                // ★ 修正: 削除ボタンの無効化ロジックを呼び出す
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
                placeholderView(message: "ツールバーのインポートボタンからビデオを追加してください。")
                    .navigationTitle(album.name)
                    .toolbar {
                        ToolbarItem {
                           importButton
                        }
                    }
            } else {
                VStack {
                    if filteredVideos.isEmpty {
                        Text(searchText.isEmpty ? "ビデオがありません" : "「\(searchText)」に一致するビデオはありません。")
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
                .searchable(text: $searchText, prompt: "ビデオを名前で検索")
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
                        .animation(.default, value: viewMode)  // ★ 修正: アニメーションをここに移動
                    }
                }
            }
        } else {
            placeholderView(message: "アルバムを選択してください。")
        }
    }
    
    private var importButton: some View {
        Button(action: openFileImporter) {
            Label("ビデオをインポート", systemImage: "square.and.arrow.down")
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
                    Text("長さ: \(formatDuration(video.duration))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
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
            Text("ビデオがありません").font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
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
        VStack {
            Text("新しいアルバム").font(.headline).padding()
            TextField("アルバム名", text: $newAlbumName)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            HStack {
                Button("キャンセル") {
                    isShowingAddAlbumSheet = false
                    newAlbumName = ""
                }
                Button("作成") {
                    if !newAlbumName.isEmpty {
                        dataManager.createAlbum(name: newAlbumName)
                        isShowingAddAlbumSheet = false
                        newAlbumName = ""
                    }
                }.disabled(newAlbumName.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 300, minHeight: 150)
    }

    // MARK: - Functions
    
    // ★ 新規: アルバム削除ボタンの無効化ロジック
    private func isDeleteAlbumDisabled() -> Bool {
        guard let selectedID = selectedAlbumID,
              let selected = dataManager.albums.first(where: { $0.id == selectedID }) else {
            return true
        }
        
        if selected.name == allVideosAlbumName {
            return true
        }
        
        let userAlbumsCount = dataManager.albums.filter { $0.name != allVideosAlbumName }.count
        if userAlbumsCount <= 1 {
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
        
        // ★ 追加: もし "ALL VIDEOS" が選択されていたら、最初のユーザーアルバムをインポート先にする
        if let selectedID = selectedAlbumID,
           let selectedAlbum = dataManager.albums.first(where: { $0.id == selectedID }),
           selectedAlbum.name == allVideosAlbumName {
            targetAlbumID = dataManager.albums.first(where: { $0.name != allVideosAlbumName })?.id
        }
        
        guard let finalTargetAlbumID = targetAlbumID else { return }
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["mp4", "mov", "m4v"]
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                Task {
                    await dataManager.importVideo(from: url, to: finalTargetAlbumID)
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
