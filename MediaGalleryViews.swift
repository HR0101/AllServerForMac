import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
