import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// サムネイル一覧の余白。密度を高めつつ，選択枠とホバー状態を見分けられる最小限の間隔を保つ。
private enum MediaGridLayout {
    static let spacing: CGFloat = 3
    static let itemInset: CGFloat = 1
    static let contentInset: CGFloat = 5
}

/// 一覧グリッドの矢印キー移動。アルバム詳細とお気に入り/ゴミ箱の両方、
/// さらにクイックルック表示中の送りも同じ計算を使う。
enum MediaGridNavigation {
    static func direction(for press: KeyPress) -> QuickLookPreviewController.NavigationDirection? {
        if MediaShortcutSettings.matches(.libraryMoveUp, press: press) { return .up }
        if MediaShortcutSettings.matches(.libraryMoveDown, press: press) { return .down }
        if MediaShortcutSettings.matches(.libraryMoveLeft, press: press) { return .left }
        if MediaShortcutSettings.matches(.libraryMoveRight, press: press) { return .right }
        return nil
    }

    /// 移動先の添字。端で動けないときは nil。
    static func nextIndex(
        from index: Int,
        direction: QuickLookPreviewController.NavigationDirection,
        columnCount: Int,
        itemCount: Int
    ) -> Int? {
        let next: Int
        switch direction {
        case .up: next = index - columnCount
        case .down: next = index + columnCount
        case .left: next = index - 1
        case .right: next = index + 1
        }
        return (0..<itemCount).contains(next) ? next : nil
    }
}

/// 削除の確認などで「どれを選んだのか」を小さく添えるための一覧文。
///
/// 件数だけだと、選んだつもりのものと実際の選択がずれていても気づけない。
/// かといって全部並べるとダイアログが画面を埋めるので、先頭数件だけ出して残りは件数でまとめる。
enum SelectionSummary {
    /// 名前を並べる上限。これを超えたぶんは「ほか◯件」に畳む。
    private static let maxListedNames = 8
    /// 1行の長さの上限。超えたら真ん中を省略する。
    private static let maxNameLength = 44

    /// `items` は表示順で渡すこと（画面で見えている並びと一致していないと確認の役に立たない）。
    static func text(for items: [VideoItem]) -> String {
        guard !items.isEmpty else { return "" }
        var lines = items.prefix(maxListedNames).map { "・" + shortened($0.originalFilename) }
        let remainder = items.count - lines.count
        if remainder > 0 {
            lines.append("・ほか\(remainder)件")
        }
        return lines.joined(separator: "\n")
    }

    /// 長い名前は真ん中を省略する。末尾には連番や拡張子が来ることが多く、
    /// 先頭だけ残すより見分けがつきやすい。
    private static func shortened(_ name: String) -> String {
        guard name.count > maxNameLength else { return name }
        let sideLength = maxNameLength / 2 - 1
        return "\(name.prefix(sideLength))…\(name.suffix(sideLength))"
    }
}

/// インポート進捗の @State 更新を間引くカウンタ。
/// 1件ごとに @State を更新すると、その回数だけビュー全体（displayedItems の全件
/// フィルタ+ソート含む）が再評価され、せっかくの一括反映最適化を打ち消してしまう。
/// 表示は25件刻みで十分なので、まとめて反映する。
@MainActor
final class ImportProgressThrottle {
    private(set) var count = 0
    private let onUpdate: (Int) -> Void

    init(onUpdate: @escaping (Int) -> Void) {
        self.onUpdate = onUpdate
    }

    func tick() {
        count += 1
        if count % 25 == 0 { onUpdate(count) }
    }

    func finish() {
        onUpdate(count)
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
    @State private var searchText = ""
    @State private var showMoveToNewAlbumAlert = false
    @State private var newAlbumNameForMove = ""
    @State private var pendingMoveVideoIDs: [UUID] = []
    /// キーボードで今どのセルを指しているか。セル側の @FocusState ではなくただの状態として持つ
    /// （SwiftUI 標準のフォーカス送りと矢印キーを取り合わないようにするため）。
    @State private var focusedVideoID: UUID?
    /// グリッドがキー入力を受け取れる状態か。フォーカスはグリッド全体で1つ。
    @FocusState private var isGridFocused: Bool

    // ラフ画・線画の抽出
    @State private var showSketchCleanup = false
    // 似ているメディアの整理
    @State private var showSimilarMedia = false

    // 分割再生用
    @State private var showSplitSheet = false
    @State private var splitCount: Int = 4
    @State private var splitTargetVideo: VideoItem?

    @State private var isCheckingDuplicates = false
    @State private var duplicateCheckProgress: Double = 0
    @State private var duplicateCheckCurrent = 0
    @State private var duplicateCheckTotal = 0
    @State private var duplicateCheckResultMessage = ""
    @State private var showDuplicateCheckResultAlert = false

    @State private var isImporting = false
    @State private var importedCount = 0

    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportCurrent = 0
    @State private var exportTotal = 0
    @State private var exportResultMessage = ""
    @State private var showExportResultAlert = false

    @State private var showBulkDeleteConfirmation = false

    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var appSettings: AppSettings

    /// 実際に並べる列数。グリッドの組み立てと矢印キーの上下移動が必ず同じ値を見るように、
    /// ここだけで決める（ズレると下キーが斜めに飛ぶ）。
    private var columnCount: Int {
        max(2, Int(appSettings.columnCount))
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: MediaGridLayout.spacing), count: columnCount)
    }

    private var currentAlbum: Album {
        dataManager.albums.first(where: { $0.id == album.id }) ?? album
    }

    private var isLinkedToFolder: Bool {
        currentAlbum.linkedFolderPath != nil || currentAlbum.linkedFolderBookmarkData != nil
    }

    /// 検索・並べ替えを適用した表示アイテム（動画＋画像、ゴミ箱を除く）
    private var displayedItems: [VideoItem] {
        let memberIDs = Set(album.videoIDs)
        return dataManager.videos
            .filter { memberIDs.contains($0.id) && !$0.isInTrash }
            .filtered(bySearch: searchText)
            .sorted(by: appSettings.sortOrder, reversed: appSettings.sortReversed) { dataManager.fileMetadata(for: $0) }
    }

    /// このアルバムの動画のみ（表示順）
    private var albumVideoItems: [VideoItem] {
        displayedItems.filter { $0.mediaType == .video }
    }

    /// 現在の選択のうち動画のみ（表示順）
    private var selectedVideoItems: [VideoItem] {
        displayedItems.filter { selectedVideoIDs.contains($0.id) && $0.mediaType == .video }
    }

    /// 現在の選択すべて（表示順、画像も含む）。削除の確認で何を消すのか見せるために使う。
    private var selectedItems: [VideoItem] {
        displayedItems.filter { selectedVideoIDs.contains($0.id) }
    }

    private var canRemoveItemsFromCurrentAlbum: Bool {
        album.name != VideoDataManager.allVideosAlbumName && album.name != VideoDataManager.allPhotosAlbumName
    }

    var body: some View {
        // displayedItems（フィルタ＋ソート）は件数が多いと軽くないため、1回の描画につき1回だけ計算し、
        // toolbar/sheet も含めて使い回す（以前は同じ描画の中で何度も呼ばれ、そのたびに再計算されていた）。
        let items = displayedItems
        let videoItems = items.filter { $0.mediaType == .video }
        let selectedItems = items.filter { selectedVideoIDs.contains($0.id) && $0.mediaType == .video }

        return VStack(spacing: 0) {
            ZStack {
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
                
                if isCheckingDuplicates {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView("重複チェック中...", value: duplicateCheckProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 220)
                            .tint(.accentColor)
                            .foregroundColor(.white)
                        Text("\(duplicateCheckCurrent) / \(duplicateCheckTotal) (\(Int(duplicateCheckProgress * 100))%)")
                            .foregroundColor(.white)
                            .font(.subheadline)
                    }
                    .padding()
                    .background(.thickMaterial)
                    .cornerRadius(12)
                }

                // フォルダの中身が多いと動画の尺・撮影日時の読み込みに時間がかかるため、
                // 「固まっているように見える」ことがないよう進捗（処理件数）を表示する。
                if isImporting {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.accentColor)
                        Text("インポート中...（\(importedCount)件処理済み）")
                            .foregroundColor(.white)
                            .font(.subheadline)
                    }
                    .padding()
                    .background(.thickMaterial)
                    .cornerRadius(12)
                }

                if isExporting {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView("エクスポート中...", value: exportProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 220)
                            .tint(.accentColor)
                            .foregroundColor(.white)
                        Text("\(exportCurrent) / \(exportTotal)")
                            .foregroundColor(.white)
                            .font(.subheadline)
                    }
                    .padding()
                    .background(.thickMaterial)
                    .cornerRadius(12)
                }
            }

            Divider()
            MediaGridControlBar(dataManager: dataManager)
        }
        .background(CommandDeckBackground())
        .searchable(text: $searchText, placement: .toolbar, prompt: "タイトルを検索")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: importFilesViaDialog) {
                    Label("インポート", systemImage: "plus.circle")
                }
                .help("ファイルまたはフォルダをインポート")
            }

            if canRemoveItemsFromCurrentAlbum {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: isLinkedToFolder ? rescanLinkedFolder : linkFolderViaDialog) {
                        Label(isLinkedToFolder ? "フォルダ更新" : "フォルダ紐づけ", systemImage: isLinkedToFolder ? "arrow.triangle.2.circlepath" : "folder.badge.plus")
                    }
                    .help(isLinkedToFolder ? "紐づけフォルダを再スキャンして新規メディアを取り込みます" : "このアルバムにFinder上のフォルダを紐づけます")
                    .disabled(isImporting)
                }
            }

            // 重複チェックはアルバム単位でのみ意味を持つ（すべての動画/画像には全アルバムのメディアが
            // 集まっているため、ここで実行すると別アルバム同士のメディアまで重複扱いになってしまう）。
            if canRemoveItemsFromCurrentAlbum {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: runDuplicateCheck) {
                        Label("重複チェック", systemImage: "checkmark.seal")
                    }
                    .help("このアルバム内の重複メディアを検出してゴミ箱へ移動")
                    .disabled(isCheckingDuplicates || dataManager.isDuplicateCheckRunning || items.isEmpty)
                }
            }

            // ラフ画・線画の抽出（画像がある場合のみ）
            ToolbarItem(placement: .primaryAction) {
                if items.contains(where: { $0.mediaType == .photo }) {
                    Button {
                        showSketchCleanup = true
                    } label: {
                        Label("ラフ画・線画", systemImage: "scribble.variable")
                    }
                    .help("このアルバムの画像からラフ画・線画を自動で拾い出して、確認してから削除します")
                }
            }

            // 似ているメディアの整理（重複チェックと違い、完全一致でなくても拾う）
            ToolbarItem(placement: .primaryAction) {
                if items.count >= 2 {
                    Button {
                        showSimilarMedia = true
                    } label: {
                        Label("似ているものを探す", systemImage: "square.on.square.dashed")
                    }
                    .help("見た目が似ているメディアをまとめて表示し、残す1件を選んで残りを削除します")
                }
            }

            // ランダム同時再生（本数を選ぶと、このアルバムからその数だけ無作為に選んで並べる）
            ToolbarItem(placement: .primaryAction) {
                if videoItems.count >= 2 {
                    Menu {
                        ForEach(2...min(9, videoItems.count), id: \.self) { count in
                            Button("\(count)本") {
                                coordinator.playMulti(Array(videoItems.shuffled().prefix(count)))
                            }
                        }
                    } label: {
                        Label("ランダム同時再生", systemImage: "square.grid.2x2")
                    }
                    .help("このアルバムの動画から、選んだ本数だけ無作為に選んで同時再生します")
                }
            }

            // ランダム再生（選択不要・このアルバムの動画をシャッフルして連続再生）
            ToolbarItem(placement: .primaryAction) {
                if !videoItems.isEmpty {
                    Button {
                        coordinator.playRandom(from: videoItems)
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
                    if selectedItems.count >= 2 {
                        Button {
                            coordinator.playMulti(selectedItems)
                        } label: {
                            Label("同時再生", systemImage: "square.grid.2x2.fill")
                        }
                        .help("選択した動画を同期再生（最大9本）")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if selectedItems.count >= 2 {
                        Button {
                            coordinator.startSlideshow(selectedItems)
                        } label: {
                            Label("スライドショー", systemImage: "play.square.stack")
                        }
                        .help("選択した動画をスライドショー再生")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if selectedItems.count == 1, let video = selectedItems.first {
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
                    Button(action: exportSelectedItems) {
                        Label("エクスポート", systemImage: "square.and.arrow.up")
                    }
                    .help("選択した項目のコピーを指定フォルダへ書き出す（元ファイルが失われた場合の安全弁）")
                }
                if canRemoveItemsFromCurrentAlbum {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: removeSelectedFromAlbum) {
                            Label("アルバムから外す", systemImage: "minus.circle")
                        }
                        .help("選択した項目をこのアルバムから外す（メディア自体は削除されません）")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) { showBulkDeleteConfirmation = true } label: {
                        Label("削除", systemImage: "trash")
                    }
                    .help("選択した項目をゴミ箱に入れるか完全に削除します")
                }
            }
        }
        // 削除は必ず「ゴミ箱に入れる」か「完全に削除」かを確認してから実行する。
        .confirmationDialog("削除方法を選んでください", isPresented: $showBulkDeleteConfirmation, titleVisibility: .visible) {
            Button("ゴミ箱に入れる", action: moveSelectedToTrash)
            Button("完全に削除", role: .destructive, action: deleteSelectedVideos)
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("選択した\(selectedVideoIDs.count)件をゴミ箱に入れますか？それとも完全に削除しますか？この操作は元に戻せません（完全に削除の場合）。\n\n\(SelectionSummary.text(for: selectedItems))")
        }
        .sheet(isPresented: $showSketchCleanup) {
            SketchCleanupView(items: displayedItems, dataManager: dataManager) {
                selectedVideoIDs.removeAll()
                lastSelectedVideoID = nil
            }
        }
        .sheet(isPresented: $showSimilarMedia) {
            SimilarMediaView(items: displayedItems, dataManager: dataManager) {
                selectedVideoIDs.removeAll()
                lastSelectedVideoID = nil
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            return handleDrop(providers: providers)
        }
        .alert("異なるメディアタイプの混在", isPresented: $showMixedContentAlert) {
            Button("現在のアルバムのタイプ (\(album.type.displayName)) としてインポート") {
                if let url = pendingFolderURL {
                    Task {
                        isImporting = true
                        importedCount = 0
                        let progress = ImportProgressThrottle { importedCount = $0 }
                        await dataManager.importAndLinkFolder(folderURL: url, as: album.type) { progress.tick() }
                        progress.finish()
                        isImporting = false
                        pendingFolderURL = nil
                    }
                }
            }
            Button("キャンセル", role: .cancel) { pendingFolderURL = nil }
        } message: {
            Text("\(mixedContentInfo)\n指定したタイプ (\(album.type.displayName)) 以外のファイルは無視されます。")
        }
        .alert("重複チェック完了", isPresented: $showDuplicateCheckResultAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(duplicateCheckResultMessage)
        }
        .alert("エクスポート完了", isPresented: $showExportResultAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportResultMessage)
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
        // 他のアルバムに移動したら、このアルバムのデコード済みサムネイルはメモリから解放する。
        // ディスクキャッシュは消さないので、戻ってきたときの再表示は速いまま。
        .onDisappear {
            MacVideoThumbnailView.evictFromMemoryCache(videoIDs: items.map { $0.id })
        }
    }

    // MARK: - Grid + keyboard navigation

    private func grid(_ items: [VideoItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: MediaGridLayout.spacing) {
                    ForEach(items) { video in
                        MediaGridItem(
                            video: video,
                            dataManager: dataManager,
                            isSelected: selectedVideoIDs.contains(video.id),
                            showTitle: appSettings.showTitles,
                            showImportDate: appSettings.showImportDates,
                            showRemoveFromAlbum: album.name != VideoDataManager.allVideosAlbumName && album.name != VideoDataManager.allPhotosAlbumName,
                            onSingleTap: { flags in
                                handleGridSelection(for: video, in: items, flags: flags)
                                focusedVideoID = video.id
                                // クリック後もそのまま矢印キーで送れるようにフォーカスを戻す。
                                isGridFocused = true
                            },
                            onDoubleTap: { openFile(video) },
                            onOpen: { openFile(video) },
                            onOpenExternal: { openFileExternal(video) },
                            onReveal: { revealInFinder(video) },
                            onRemoveFromAlbum: {
                                dataManager.removeVideosFromAlbum(videoIDs: [video.id], albumID: album.id)
                            },
                            onDelete: {
                                // 「ゴミ箱に入れる」と対象範囲を揃える。複数選択中に右クリックしたとき、
                                // ゴミ箱行きは選択全体なのに完全削除だけ1件、では取り違えのもとになる。
                                dataManager.deleteVideos(videoIDs: effectiveTargetIDs(for: video))
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
                            },
                            affectedItems: menuTargets(for: video, in: items)
                        )
                        .id(video.id)
                    }
                }
                .padding(MediaGridLayout.contentInset)
            }
            // フォーカスはグリッド全体で1つだけ持つ。セルごとに .focusable() を付けると、
            // SwiftUI 標準の矢印キーによるフォーカス送りが自前の「index ± 列数」移動と同時に走り、
            // 1回の入力で二重に動いたり斜めに飛んだりする（列数によって挙動が変わって見える原因）。
            // どのセルを指しているかは focusedVideoID（ただの @State）で持つ。
            .focusable()
            .focusEffectDisabled()
            .focused($isGridFocused)
            .task(id: coordinator.returnToMediaID) {
                await restoreReturnTarget(items: items, proxy: proxy)
            }
            .onKeyPress(phases: .down) { press in
                handleGridKey(press, items: items, proxy: proxy)
            }
            .onAppear {
                // グリッドにフォーカスを持たせて onKeyPress を有効化する
                isGridFocused = true
                if focusedVideoID == nil, let first = items.first { focusedVideoID = first.id }
                if coordinator.returnToMediaID != nil {
                    Task { await restoreReturnTarget(items: items, proxy: proxy) }
                }
            }
        }
    }

    /// 矢印キーでフォーカス移動、Enter/Option+Spaceで再生
    private func handleGridKey(_ press: KeyPress, items: [VideoItem], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }

        if handleLibraryShortcut(press, items: items, proxy: proxy) == .handled {
            return .handled
        }

        // Option+Space は既存互換の固定ショートカットとして残す。
        if press.key == .space, press.modifiers.contains(.option) {
            playFromGrid(items: items); return .handled
        }

        guard let focused = focusedVideoID, items.contains(where: { $0.id == focused }) else {
            let first = items[0].id
            focusedVideoID = first
            selectedVideoIDs = [first]
            lastSelectedVideoID = first
            return .handled
        }

        guard let direction = MediaGridNavigation.direction(for: press) else { return .ignored }
        return moveFocus(direction, items: items, proxy: proxy) != nil ? .handled : .ignored
    }

    /// フォーカスと選択を矢印1回ぶん動かし、移動後の項目を返す。端で動けなければ nil。
    /// キー処理とクイックルック中の送りが同じ動きになるよう、移動はここだけで行う。
    @discardableResult
    private func moveFocus(
        _ direction: QuickLookPreviewController.NavigationDirection,
        items: [VideoItem],
        proxy: ScrollViewProxy
    ) -> VideoItem? {
        guard let focused = focusedVideoID,
              let index = items.firstIndex(where: { $0.id == focused }),
              let next = MediaGridNavigation.nextIndex(
                  from: index, direction: direction, columnCount: columnCount, itemCount: items.count
              ) else { return nil }

        let item = items[next]
        focusedVideoID = item.id
        selectedVideoIDs = [item.id]
        lastSelectedVideoID = item.id
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(item.id, anchor: .center) }
        return item
    }

    private func handleLibraryShortcut(_ press: KeyPress, items: [VideoItem], proxy: ScrollViewProxy) -> KeyPress.Result {
        if MediaShortcutSettings.matches(.libraryOpenFocused, press: press) {
            playFromGrid(items: items)
            return .handled
        } else if MediaShortcutSettings.matches(.libraryQuickLook, press: press) {
            quickLookFocusedVideo(in: items, proxy: proxy)
            return .handled
        } else if MediaShortcutSettings.matches(.libraryOpenExternal, press: press) {
            if let item = primaryTarget(in: items) { openFileExternal(item) }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryRevealInFinder, press: press) {
            if let item = primaryTarget(in: items) { revealInFinder(item) }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryToggleFavorite, press: press) {
            if let item = primaryTarget(in: items) {
                dataManager.toggleFavorite(videoIDs: effectiveTargetIDs(for: item))
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryDelete, press: press) {
            ensureSelectionForFocusedItem(in: items)
            if !selectedVideoIDs.isEmpty { showBulkDeleteConfirmation = true }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryMoveToTrash, press: press) {
            ensureSelectionForFocusedItem(in: items)
            if !selectedVideoIDs.isEmpty { moveSelectedToTrash() }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryExport, press: press) {
            ensureSelectionForFocusedItem(in: items)
            if !selectedVideoIDs.isEmpty { exportSelectedItems() }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryImport, press: press) {
            importFilesViaDialog()
            return .handled
        } else if MediaShortcutSettings.matches(.libraryRandomPlay, press: press) {
            coordinator.playRandom(from: items.filter { $0.mediaType == .video })
            return .handled
        } else if MediaShortcutSettings.matches(.libraryMultiPlay, press: press) {
            let selected = selectedVideoItems
            if selected.count >= 2 { coordinator.playMulti(selected) }
            return .handled
        } else if MediaShortcutSettings.matches(.librarySlideshow, press: press) {
            let selected = selectedVideoItems
            if selected.count >= 2 { coordinator.startSlideshow(selected) }
            return .handled
        } else if MediaShortcutSettings.matches(.librarySplitPlay, press: press) {
            let selected = selectedVideoItems
            if selected.count == 1, let video = selected.first {
                splitTargetVideo = video
                showSplitSheet = true
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryDuplicateCheck, press: press) {
            if canRemoveItemsFromCurrentAlbum, !items.isEmpty {
                runDuplicateCheck()
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryRemoveFromAlbum, press: press) {
            ensureSelectionForFocusedItem(in: items)
            if canRemoveItemsFromCurrentAlbum, !selectedVideoIDs.isEmpty {
                removeSelectedFromAlbum()
            }
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

    private func primaryTarget(in items: [VideoItem]) -> VideoItem? {
        if let focused = focusedVideoID, let item = items.first(where: { $0.id == focused }) {
            return item
        }
        if let selectedID = selectedVideoIDs.first, let item = items.first(where: { $0.id == selectedID }) {
            return item
        }
        return items.first
    }

    /// 選択中の動画を Finder と同じクイックルックパネルで開く（動画専用。画像は対象外）。
    /// Finder と同じく、複数選択しているときはその選択ぶんをパネル内で送れるようにする。
    /// 一覧全件を渡さないのは、URL の解決が1件ずつファイル探索になるため
    /// 大きなアルバムで Space を押すたびに数千回のファイルIOが走ってしまうから。
    private func quickLookFocusedVideo(in items: [VideoItem], proxy: ScrollViewProxy) {
        guard let target = primaryTarget(in: items), target.mediaType == .video else { return }
        var candidates = selectedVideoIDs.count > 1 ? items.filter { selectedVideoIDs.contains($0.id) } : []
        if !candidates.contains(where: { $0.id == target.id }) { candidates = [target] }

        let targets = QuickLookPreviewController.previewTargets(in: candidates, focusedOn: target) {
            dataManager.fileURL(for: $0)
        }
        guard let startIndex = targets.startIndex else { return }

        // プレビュー中の矢印キーで一覧の選択を動かし、その項目をそのまま表示させる。
        // グリッドと同じ moveFocus を通すので、列数ぶんの上下移動もスクロール追従も一致する。
        QuickLookPreviewController.shared.onNavigate = { direction in
            guard let moved = moveFocus(direction, items: items, proxy: proxy) else { return nil }
            return dataManager.fileURL(for: moved)
        }
        QuickLookPreviewController.shared.present(urls: targets.urls, startingAt: startIndex)
    }

    private func ensureSelectionForFocusedItem(in items: [VideoItem]) {
        guard selectedVideoIDs.isEmpty, let item = primaryTarget(in: items) else { return }
        selectedVideoIDs = [item.id]
        lastSelectedVideoID = item.id
        focusedVideoID = item.id
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
        coordinator.rememberReturnTarget(mediaID: video.id)
        if video.mediaType == .video {
            coordinator.playSingle(playlist: albumVideoItems, current: video)
        } else {
            coordinator.viewPhotos(playlist: displayedItems.filter { $0.mediaType == .photo }, current: video)
        }
    }

    // QuickTime Player など外部のデフォルトアプリで開く
    private func openFileExternal(_ video: VideoItem) {
        guard let url = dataManager.fileURL(for: video) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder(_ video: VideoItem) {
        guard let url = dataManager.revealURL(for: video) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        print("📥 [DROP] アルバムへのドロップを受け取りました: providers=\(providers.count)")
        loadDroppedFileURLs(from: providers) { urls in
            var folderURLs: [URL] = []
            var fileURLs: [URL] = []

            for url in urls {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

                if isDirectory.boolValue {
                    folderURLs.append(url)
                } else {
                    fileURLs.append(url)
                }
            }

            if folderURLs.count == 1, fileURLs.isEmpty, let folderURL = folderURLs.first {
                let counts = dataManager.scanFolder(folderURL: folderURL)

                if (album.type == .video && counts.photoCount > 0) || (album.type == .photo && counts.videoCount > 0) {
                    self.mixedContentInfo = "動画: \(counts.videoCount)件, 画像: \(counts.photoCount)件"
                    self.pendingFolderURL = folderURL
                    self.showMixedContentAlert = true
                    return
                }
            }

            Task {
                isImporting = true
                importedCount = 0
                let progress = ImportProgressThrottle { importedCount = $0 }
                for folderURL in folderURLs {
                    await dataManager.importAndLinkFolder(folderURL: folderURL, as: album.type) { progress.tick() }
                }
                await dataManager.importMediaFiles(from: fileURLs, to: album.id) { progress.tick() }
                progress.finish()
                isImporting = false
            }
        }
        return true
    }

    private func loadDroppedFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var loadedURLs: [URL] = []

        func loadNextProvider(at index: Int) {
            guard index < providers.count else {
                if loadedURLs.count != providers.count {
                    print("⚠️ [DROP] \(providers.count)件中\(loadedURLs.count)件のURLを取得しました。")
                }
                completion(loadedURLs)
                return
            }

            let provider = providers[index]
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = droppedFileURL(from: item)
                DispatchQueue.main.async {
                    if let url {
                        loadedURLs.append(url)
                    }
                    loadNextProvider(at: index + 1)
                }
            }
        }

        loadNextProvider(at: 0)
    }

    private func droppedFileURL(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        } else if let itemURL = item as? URL {
            return itemURL
        } else if let itemURL = item as? NSURL {
            return itemURL as URL
        }
        return nil
    }

    private func deleteSelectedVideos() {
        dataManager.deleteVideos(videoIDs: Array(selectedVideoIDs))
        selectedVideoIDs.removeAll()
        lastSelectedVideoID = nil
    }

    private func removeSelectedFromAlbum() {
        guard canRemoveItemsFromCurrentAlbum else { return }
        dataManager.removeVideosFromAlbum(videoIDs: Array(selectedVideoIDs), albumID: album.id)
        selectedVideoIDs.removeAll()
        lastSelectedVideoID = nil
    }

    private func moveSelectedToTrash() {
        dataManager.moveToTrash(videoIDs: Array(selectedVideoIDs))
        selectedVideoIDs.removeAll()
        lastSelectedVideoID = nil
    }

    /// 選択した項目のコピーを指定フォルダへ書き出す。フォルダインポートは元ファイルを参照するだけで
    /// アプリはコピーを持たないため、誤って元ファイルを失っても手元に控えを残せる安全弁として使う。
    private func exportSelectedItems() {
        // runModal はネストしたイベントループを回すため、パネル表示中もタイマーやHTTP起因の
        // 状態変更で selectedVideoIDs が変わりうる。対象はパネルを開く「前」に確定させる。
        let ids = Array(selectedVideoIDs)
        guard !ids.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "書き出し先のフォルダを選択してください"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        Task {
            isExporting = true
            exportProgress = 0
            exportCurrent = 0
            exportTotal = ids.count
            let result = await dataManager.exportMedia(videoIDs: ids, to: folderURL) { current, total in
                exportCurrent = current
                exportTotal = total
                exportProgress = total == 0 ? 0 : Double(current) / Double(total)
            }
            isExporting = false
            exportResultMessage = result.failedCount > 0
                ? "\(result.successCount)件を書き出しました。\(result.failedCount)件は失敗しました。"
                : "\(result.successCount)件を書き出しました。"
            showExportResultAlert = true
        }
    }

    private func runDuplicateCheck() {
        guard !isCheckingDuplicates, !dataManager.isDuplicateCheckRunning else { return }

        isCheckingDuplicates = true
        duplicateCheckProgress = 0
        duplicateCheckCurrent = 0
        duplicateCheckTotal = displayedItems.count

        Task {
            let result = await dataManager.removeDuplicateMedia(in: album.id) { current, total in
                duplicateCheckCurrent = current
                duplicateCheckTotal = total
                duplicateCheckProgress = total == 0 ? 0 : Double(current) / Double(total)
            }

            duplicateCheckResultMessage = duplicateCheckMessage(for: result)
            isCheckingDuplicates = false
            selectedVideoIDs.removeAll()
            lastSelectedVideoID = nil
            showDuplicateCheckResultAlert = true
        }
    }

    private func duplicateCheckMessage(for result: DuplicateCheckResult) -> String {
        var lines: [String]
        if result.duplicateCount > 0 {
            lines = ["\(result.duplicateCount)件の重複メディアをゴミ箱へ移動しました。"]
        } else {
            lines = ["重複メディアは見つかりませんでした。"]
        }

        lines.append("確認した項目: \(result.checkedCount)件")
        if result.missingFileCount > 0 {
            lines.append("ファイルが見つからない項目: \(result.missingFileCount)件")
        }
        if result.failedHashCount > 0 {
            lines.append("ハッシュ計算に失敗した項目: \(result.failedHashCount)件")
        }
        return lines.joined(separator: "\n")
    }

    /// コンテキストメニュー操作の対象（右クリック対象が複数選択に含まれていれば選択全体）
    private func effectiveTargetIDs(for video: VideoItem) -> [UUID] {
        if selectedVideoIDs.contains(video.id) && selectedVideoIDs.count > 1 {
            return Array(selectedVideoIDs)
        }
        return [video.id]
    }

    /// `effectiveTargetIDs` と同じ対象を、確認文へ出すために表示順の項目として返す。
    private func menuTargets(for video: VideoItem, in items: [VideoItem]) -> [VideoItem] {
        guard selectedVideoIDs.contains(video.id), selectedVideoIDs.count > 1 else { return [video] }
        return items.filter { selectedVideoIDs.contains($0.id) }
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

    private func importFilesViaDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "インポートするファイルまたはフォルダを選択してください"

        switch album.type {
        case .video:
            panel.allowedContentTypes = [.movie, .video, .folder]
        case .photo:
            panel.allowedContentTypes = [.image, .folder]
        case .mixed:
            panel.allowedContentTypes = [.movie, .video, .image, .folder]
        }

        if panel.runModal() == .OK {
            let urls = panel.urls
            var folderURLs: [URL] = []
            var fileURLs: [URL] = []

            for url in urls {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

                if isDirectory.boolValue {
                    folderURLs.append(url)
                } else {
                    fileURLs.append(url)
                }
            }

            if folderURLs.count == 1, fileURLs.isEmpty, let folderURL = folderURLs.first {
                let counts = dataManager.scanFolder(folderURL: folderURL)

                if (album.type == .video && counts.photoCount > 0) || (album.type == .photo && counts.videoCount > 0) {
                    self.mixedContentInfo = "動画: \(counts.videoCount)件, 画像: \(counts.photoCount)件"
                    self.pendingFolderURL = folderURL
                    self.showMixedContentAlert = true
                    return
                }
            }

            Task {
                isImporting = true
                importedCount = 0
                let progress = ImportProgressThrottle { importedCount = $0 }
                for folderURL in folderURLs {
                    await dataManager.importAndLinkFolder(folderURL: folderURL, as: album.type) { progress.tick() }
                }
                await dataManager.importMediaFiles(from: fileURLs, to: album.id) { progress.tick() }
                progress.finish()
                isImporting = false
            }
        }
    }

    private func linkFolderViaDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "このアルバムに紐づけるフォルダを選択してください"

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        Task {
            isImporting = true
            importedCount = 0
            let progress = ImportProgressThrottle { importedCount = $0 }
            await dataManager.linkFolder(folderURL: folderURL, to: album.id) { progress.tick() }
            progress.finish()
            isImporting = false
        }
    }

    private func rescanLinkedFolder() {
        Task {
            isImporting = true
            importedCount = 0
            let progress = ImportProgressThrottle { importedCount = $0 }
            await dataManager.rescanLinkedFolder(albumID: album.id) { progress.tick() }
            progress.finish()
            isImporting = false
        }
    }

    @MainActor
    private func restoreReturnTarget(items: [VideoItem], proxy: ScrollViewProxy) async {
        guard let targetID = coordinator.returnToMediaID else { return }

        for attempt in 0..<4 {
            if let _ = items.first(where: { $0.id == targetID }) {
                focusedVideoID = targetID
                selectedVideoIDs = [targetID]
                lastSelectedVideoID = targetID
                // プレイヤーから戻ってきた直後もそのまま矢印キーで送れるようにする。
                isGridFocused = true
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
                coordinator.clearReturnTarget()
                return
            }

            if attempt == 3 {
                coordinator.clearReturnTarget()
                return
            }
            await Task.yield()
        }
    }
}

// MARK: - メディアグリッドアイテム（ホバー/選択ハイライト付き）
struct MediaGridItem: View {
    let video: VideoItem
    let dataManager: VideoDataManager
    let isSelected: Bool
    var showTitle: Bool = true
    var showImportDate: Bool = true
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
    /// このセルのメニュー操作が実際に対象とする項目（表示順）。
    /// 複数選択中に右クリックすると選択全体が対象になるため、
    /// 確認文が「このセル1件」の話に見えないよう、対象の実態をここで受け取る。
    var affectedItems: [VideoItem] = []

    @State private var isHovering = false
    @State private var showDeleteConfirmation = false

    /// 削除確認の本文。対象が複数のときは件数と中身を並べて、
    /// 「1件だけ消えるつもりが選択全体だった」という取り違えを防ぐ。
    private var deleteConfirmationMessage: String {
        let targets = affectedItems.isEmpty ? [video] : affectedItems
        guard targets.count > 1 else {
            return isTrashView
                ? "「\(video.originalFilename)」を完全に削除します。この操作は取り消せません。"
                : "「\(video.originalFilename)」をゴミ箱に入れますか？それとも完全に削除しますか？"
        }
        let head = isTrashView
            ? "選択した\(targets.count)件を完全に削除します。この操作は取り消せません。"
            : "選択した\(targets.count)件をゴミ箱に入れますか？それとも完全に削除しますか？"
        return "\(head)\n\n\(SelectionSummary.text(for: targets))"
    }

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
                    // 常時は状態表示のみ（お気に入り済みならハート）。ホバー中は右クリック
                    // メニューを開かなくてもワンクリックでトグルできるボタンにする。
                    if isHovering && !isTrashView {
                        Button(action: onToggleFavorite) {
                            Image(systemName: video.isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                                .padding(7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(video.isFavorite ? "お気に入りから外す" : "お気に入りに追加")
                    } else if video.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .padding(7)
                    }
                }

            if showTitle || showImportDate {
                VStack(alignment: .leading, spacing: 2) {
                    if showTitle {
                        Text(video.originalFilename)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if showImportDate {
                        Text(MediaGridItem.itemFormatter.string(from: video.importDate))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(MediaGridLayout.itemInset)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.12)
                      : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            // アニメーション付きだとセルの出入りのたびにトランザクションが発生し、
            // 大量枚数のグリッドでスクロールがカクつく原因になるため即時反映にしている。
            isHovering = hovering
        }
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture(count: 1) {
            onSingleTap(NSApp.currentEvent?.modifierFlags ?? [])
        }
        .contextMenu {
            Button("開く") { onOpen() }
            Button("外部プレイヤーで開く") { onOpenExternal() }
            Button("Finderで表示") { onReveal() }
            Button("フォルダにエクスポート…") { exportThisItem() }
            Divider()
            if isTrashView {
                Button("元に戻す") { onRestore() }
                Button("完全に削除…", role: .destructive) { showDeleteConfirmation = true }
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
                Button("削除…", role: .destructive) { showDeleteConfirmation = true }
            }
        }
        // 削除は必ず「ゴミ箱に入れる」か「完全に削除」かを確認してから実行する
        // （元ファイルの誤削除を繰り返さないための安全策）。
        .confirmationDialog(
            isTrashView ? "完全に削除しますか？" : "削除方法を選んでください",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if !isTrashView {
                Button("ゴミ箱に入れる") { onMoveToTrash() }
            }
            Button("完全に削除", role: .destructive) { onDelete() }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    /// この1件を選んだフォルダへコピーとして書き出す（元ファイルを万一失っても手元にコピーが残る安全弁）。
    private func exportThisItem() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "書き出し先のフォルダを選択してください"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        Task { await dataManager.exportMedia(videoIDs: [video.id], to: folderURL) }
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
    /// 「サイズ」「最後に開いた日」等を選んだときにファイル属性キャッシュを最新化するためだけに参照する。
    /// 表示更新は監視しないので @ObservedObject ではなく素の参照にしている。
    let dataManager: VideoDataManager

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
                    Button(order.rawValue) {
                        // ファイル属性で並べる順を選び直したときは実ファイルを読み直して最新化する。
                        if order.needsFileMetadata { dataManager.refreshFileMetadataCache() }
                        appSettings.sortOrder = order
                    }
                }
            } label: {
                Label(appSettings.sortOrder.rawValue, systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()

            // 並び順の上下をワンクリックで反転する（既に並んだ結果を反転するだけなので再読み込み不要）。
            Button {
                appSettings.sortReversed.toggle()
            } label: {
                Image(systemName: appSettings.sortReversed ? "arrow.up" : "arrow.down")
            }
            .help(appSettings.sortReversed ? "並び順を元に戻す（逆順中）" : "並び順を上下逆にする")

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

            Menu {
                Toggle("タイトルを表示", isOn: $appSettings.showTitles)
                Toggle("インポート日を表示", isOn: $appSettings.showImportDates)
            } label: {
                Image(systemName: appSettings.showTitles || appSettings.showImportDates ? "text.below.photo.fill" : "text.below.photo")
            }
            .help("サムネイル下の表示項目を設定")

            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                Slider(value: $appSettings.columnCount, in: 2...12, step: 1)
                    .frame(width: 140)
                Image(systemName: "square.grid.4x3.fill")
            }
            .help("表示列数: \(Int(appSettings.columnCount))列")
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
    }
    let kind: Kind
    @ObservedObject var dataManager: VideoDataManager

    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var appSettings: AppSettings

    @State private var selectedVideoIDs = Set<UUID>()
    @State private var lastSelectedVideoID: UUID?
    @State private var searchText = ""
    @State private var showEmptyTrashAlert = false
    @State private var showMoveToNewAlbumAlert = false
    @State private var newAlbumNameForMove = ""
    @State private var pendingMoveVideoIDs: [UUID] = []
    /// キーボードで今どのセルを指しているか。セル側の @FocusState ではなくただの状態として持つ
    /// （SwiftUI 標準のフォーカス送りと矢印キーを取り合わないようにするため）。
    @State private var focusedVideoID: UUID?
    /// グリッドがキー入力を受け取れる状態か。フォーカスはグリッド全体で1つ。
    @FocusState private var isGridFocused: Bool

    // 分割再生用
    @State private var showSplitSheet = false
    @State private var splitCount: Int = 4
    @State private var splitTargetVideo: VideoItem?

    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportCurrent = 0
    @State private var exportTotal = 0
    @State private var exportResultMessage = ""
    @State private var showExportResultAlert = false

    @State private var showBulkDeleteConfirmation = false

    private var isTrash: Bool { kind == .trash }

    private var sourceItems: [VideoItem] {
        switch kind {
        case .favorites:
            return dataManager.favoriteVideos
        case .trash:
            return dataManager.trashedVideos
        }
    }
    private var displayedItems: [VideoItem] {
        sourceItems.filtered(bySearch: searchText).sorted(by: appSettings.sortOrder, reversed: appSettings.sortReversed) { dataManager.fileMetadata(for: $0) }
    }
    private var selectedVideoItems: [VideoItem] {
        displayedItems.filter { selectedVideoIDs.contains($0.id) && $0.mediaType == .video }
    }

    /// 現在の選択すべて（表示順、画像も含む）。削除の確認で何を消すのか見せるために使う。
    private var selectedItems: [VideoItem] {
        displayedItems.filter { selectedVideoIDs.contains($0.id) }
    }

    /// 実際に並べる列数。グリッドの組み立てと矢印キーの上下移動が必ず同じ値を見るように、
    /// ここだけで決める（ズレると下キーが斜めに飛ぶ）。
    private var columnCount: Int {
        max(2, Int(appSettings.columnCount))
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: MediaGridLayout.spacing), count: columnCount)
    }

    var body: some View {
        // displayedItems（フィルタ＋ソート）は1回の描画につき1回だけ計算し、toolbar/sheetも含めて使い回す。
        let items = displayedItems
        let videoItems = items.filter { $0.mediaType == .video }
        let selectedItems = items.filter { selectedVideoIDs.contains($0.id) && $0.mediaType == .video }

        return VStack(spacing: 0) {
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selectedVideoIDs.removeAll(); lastSelectedVideoID = nil }

                if items.isEmpty {
                    emptyState
                } else {
                    grid(items)
                }

                if isExporting {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView("エクスポート中...", value: exportProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 220)
                            .tint(.accentColor)
                            .foregroundColor(.white)
                        Text("\(exportCurrent) / \(exportTotal)")
                            .foregroundColor(.white)
                            .font(.subheadline)
                    }
                    .padding()
                    .background(.thickMaterial)
                    .cornerRadius(12)
                }
            }
            Divider()
            MediaGridControlBar(dataManager: dataManager)
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
                    if !videoItems.isEmpty {
                        Button { coordinator.playRandom(from: videoItems) } label: {
                            Label("ランダム再生", systemImage: "shuffle")
                        }
                    }
                }
                if !selectedVideoIDs.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Text("\(selectedVideoIDs.count)項目を選択中")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if selectedItems.count >= 2 {
                    ToolbarItem(placement: .primaryAction) {
                        Button { coordinator.playMulti(selectedItems) } label: {
                            Label("同時再生", systemImage: "square.grid.2x2.fill")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { coordinator.startSlideshow(selectedItems) } label: {
                            Label("スライドショー", systemImage: "play.square.stack")
                        }
                    }
                }
                if selectedItems.count == 1, let video = selectedItems.first {
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
                if !selectedVideoIDs.isEmpty {
                    // 以前は右クリックメニューでしか一括削除できず、多数選択後の
                    // 操作先が分かりにくかったため、他画面と同じ削除ボタンをツールバーにも出す。
                    // 削除は必ず「ゴミ箱に入れる」か「完全に削除」かを確認してから実行する。
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) { showBulkDeleteConfirmation = true } label: {
                            Label("削除", systemImage: "trash")
                        }
                        .help("選択した項目をゴミ箱に入れるか完全に削除します")
                    }
                }
            }
            if !selectedVideoIDs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: exportSelectedItems) {
                        Label("エクスポート", systemImage: "square.and.arrow.up")
                    }
                    .help("選択した項目のコピーを指定フォルダへ書き出す（元ファイルが失われた場合の安全弁）")
                }
            }
        }
        .alert("ゴミ箱を空にしますか？", isPresented: $showEmptyTrashAlert) {
            Button("空にする", role: .destructive) { dataManager.emptyTrash() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は取り消せません。ファイルが完全に削除されます。")
        }
        .alert("エクスポート完了", isPresented: $showExportResultAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportResultMessage)
        }
        .confirmationDialog("削除方法を選んでください", isPresented: $showBulkDeleteConfirmation, titleVisibility: .visible) {
            Button("ゴミ箱に入れる") {
                dataManager.moveToTrash(videoIDs: Array(selectedVideoIDs))
                selectedVideoIDs.removeAll()
            }
            Button("完全に削除", role: .destructive) {
                dataManager.deleteVideos(videoIDs: Array(selectedVideoIDs))
                selectedVideoIDs.removeAll()
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("選択した\(selectedVideoIDs.count)件をゴミ箱に入れますか？それとも完全に削除しますか？この操作は元に戻せません（完全に削除の場合）。\n\n\(SelectionSummary.text(for: selectedItems))")
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
        // 他の画面に移動したら、ここで表示していたサムネイルはメモリから解放する。
        .onDisappear {
            MacVideoThumbnailView.evictFromMemoryCache(videoIDs: items.map { $0.id })
        }
    }

    private func grid(_ items: [VideoItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: MediaGridLayout.spacing) {
                    ForEach(items) { video in
                        MediaGridItem(
                            video: video,
                            dataManager: dataManager,
                            isSelected: selectedVideoIDs.contains(video.id),
                            showTitle: appSettings.showTitles,
                            showImportDate: appSettings.showImportDates,
                            showRemoveFromAlbum: false,
                            onSingleTap: { flags in
                                handleSelection(for: video, in: items, flags: flags)
                                focusedVideoID = video.id
                                // クリック後もそのまま矢印キーで送れるようにフォーカスを戻す。
                                isGridFocused = true
                            },
                            onDoubleTap: { open(video) },
                            onOpen: { open(video) },
                            onOpenExternal: { if let url = dataManager.fileURL(for: video) { NSWorkspace.shared.open(url) } },
                            onReveal: { if let url = dataManager.revealURL(for: video) { NSWorkspace.shared.activateFileViewerSelecting([url]) } },
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
                            },
                            affectedItems: menuTargets(for: video, in: items)
                        )
                        .id(video.id)
                    }
                }
                .padding(MediaGridLayout.contentInset)
            }
            // フォーカスはグリッド全体で1つだけ持つ。セルごとに .focusable() を付けると、
            // SwiftUI 標準の矢印キーによるフォーカス送りが自前の「index ± 列数」移動と同時に走り、
            // 1回の入力で二重に動いたり斜めに飛んだりする（列数によって挙動が変わって見える原因）。
            // どのセルを指しているかは focusedVideoID（ただの @State）で持つ。
            .focusable()
            .focusEffectDisabled()
            .focused($isGridFocused)
            .task(id: coordinator.returnToMediaID) {
                await restoreReturnTarget(items: items, proxy: proxy)
            }
            .onKeyPress(phases: .down) { press in handleKey(press, items: items, proxy: proxy) }
            .onAppear {
                isGridFocused = true
                if focusedVideoID == nil, let first = items.first { focusedVideoID = first.id }
                if coordinator.returnToMediaID != nil {
                    Task { await restoreReturnTarget(items: items, proxy: proxy) }
                }
            }
        }
    }

    private func open(_ video: VideoItem) {
        coordinator.rememberReturnTarget(mediaID: video.id)
        if video.mediaType == .video {
            coordinator.playSingle(playlist: displayedItems.filter { $0.mediaType == .video }, current: video)
        } else {
            // 画像は最初から「全画面表示（PhotoViewerView）」で開く
            coordinator.viewPhotos(playlist: displayedItems.filter { $0.mediaType == .photo }, current: video)
        }
    }

    private func targetIDs(for video: VideoItem) -> [UUID] {
        if selectedVideoIDs.contains(video.id) && selectedVideoIDs.count > 1 { return Array(selectedVideoIDs) }
        return [video.id]
    }

    /// `targetIDs` と同じ対象を、確認文へ出すために表示順の項目として返す。
    private func menuTargets(for video: VideoItem, in items: [VideoItem]) -> [VideoItem] {
        guard selectedVideoIDs.contains(video.id), selectedVideoIDs.count > 1 else { return [video] }
        return items.filter { selectedVideoIDs.contains($0.id) }
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

        if handleLibraryShortcut(press, items: items, proxy: proxy) == .handled {
            return .handled
        }

        // Option+Space は既存互換の固定ショートカットとして残す。
        if press.key == .space, press.modifiers.contains(.option) {
            playFocused(items: items); return .handled
        }

        guard let focused = focusedVideoID, items.contains(where: { $0.id == focused }) else {
            let first = items[0].id
            focusedVideoID = first; selectedVideoIDs = [first]; lastSelectedVideoID = first
            return .handled
        }

        guard let direction = MediaGridNavigation.direction(for: press) else { return .ignored }
        return moveFocus(direction, items: items, proxy: proxy) != nil ? .handled : .ignored
    }

    /// フォーカスと選択を矢印1回ぶん動かし、移動後の項目を返す。端で動けなければ nil。
    /// キー処理とクイックルック中の送りが同じ動きになるよう、移動はここだけで行う。
    @discardableResult
    private func moveFocus(
        _ direction: QuickLookPreviewController.NavigationDirection,
        items: [VideoItem],
        proxy: ScrollViewProxy
    ) -> VideoItem? {
        guard let focused = focusedVideoID,
              let index = items.firstIndex(where: { $0.id == focused }),
              let next = MediaGridNavigation.nextIndex(
                  from: index, direction: direction, columnCount: columnCount, itemCount: items.count
              ) else { return nil }

        let item = items[next]
        focusedVideoID = item.id
        selectedVideoIDs = [item.id]
        lastSelectedVideoID = item.id
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(item.id, anchor: .center) }
        return item
    }

    private func handleLibraryShortcut(_ press: KeyPress, items: [VideoItem], proxy: ScrollViewProxy) -> KeyPress.Result {
        if MediaShortcutSettings.matches(.libraryOpenFocused, press: press) {
            playFocused(items: items)
            return .handled
        } else if MediaShortcutSettings.matches(.libraryQuickLook, press: press) {
            quickLookFocusedVideo(in: items, proxy: proxy)
            return .handled
        } else if MediaShortcutSettings.matches(.libraryOpenExternal, press: press) {
            if let item = primaryTarget(in: items), let url = dataManager.fileURL(for: item) {
                NSWorkspace.shared.open(url)
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryRevealInFinder, press: press) {
            if let item = primaryTarget(in: items), let url = dataManager.revealURL(for: item) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryToggleFavorite, press: press) {
            if !isTrash, let item = primaryTarget(in: items) {
                dataManager.toggleFavorite(videoIDs: targetIDs(for: item))
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryDelete, press: press) {
            ensureSelectionForFocusedItem(in: items)
            if !selectedVideoIDs.isEmpty { showBulkDeleteConfirmation = true }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryMoveToTrash, press: press) {
            guard !isTrash else { return .handled }
            ensureSelectionForFocusedItem(in: items)
            if !selectedVideoIDs.isEmpty {
                dataManager.moveToTrash(videoIDs: Array(selectedVideoIDs))
                selectedVideoIDs.removeAll()
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryRestoreFromTrash, press: press) {
            guard isTrash else { return .handled }
            ensureSelectionForFocusedItem(in: items)
            if !selectedVideoIDs.isEmpty {
                dataManager.restoreFromTrash(videoIDs: Array(selectedVideoIDs))
                selectedVideoIDs.removeAll()
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryExport, press: press) {
            ensureSelectionForFocusedItem(in: items)
            if !selectedVideoIDs.isEmpty { exportSelectedItems() }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryRandomPlay, press: press) {
            guard !isTrash else { return .handled }
            coordinator.playRandom(from: items.filter { $0.mediaType == .video })
            return .handled
        } else if MediaShortcutSettings.matches(.libraryMultiPlay, press: press) {
            guard !isTrash else { return .handled }
            let selected = selectedVideoItems
            if selected.count >= 2 { coordinator.playMulti(selected) }
            return .handled
        } else if MediaShortcutSettings.matches(.librarySlideshow, press: press) {
            guard !isTrash else { return .handled }
            let selected = selectedVideoItems
            if selected.count >= 2 { coordinator.startSlideshow(selected) }
            return .handled
        } else if MediaShortcutSettings.matches(.librarySplitPlay, press: press) {
            guard !isTrash else { return .handled }
            let selected = selectedVideoItems
            if selected.count == 1, let video = selected.first {
                splitTargetVideo = video
                showSplitSheet = true
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryEmptyTrash, press: press) {
            if isTrash, !dataManager.trashedVideos.isEmpty {
                showEmptyTrashAlert = true
            }
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

    private func primaryTarget(in items: [VideoItem]) -> VideoItem? {
        if let focused = focusedVideoID, let item = items.first(where: { $0.id == focused }) {
            return item
        }
        if let selectedID = selectedVideoIDs.first, let item = items.first(where: { $0.id == selectedID }) {
            return item
        }
        return items.first
    }

    /// 選択中の動画を Finder と同じクイックルックパネルで開く（動画専用。画像は対象外）。
    /// Finder と同じく、複数選択しているときはその選択ぶんをパネル内で送れるようにする。
    /// 一覧全件を渡さないのは、URL の解決が1件ずつファイル探索になるため
    /// 大きなアルバムで Space を押すたびに数千回のファイルIOが走ってしまうから。
    private func quickLookFocusedVideo(in items: [VideoItem], proxy: ScrollViewProxy) {
        guard let target = primaryTarget(in: items), target.mediaType == .video else { return }
        var candidates = selectedVideoIDs.count > 1 ? items.filter { selectedVideoIDs.contains($0.id) } : []
        if !candidates.contains(where: { $0.id == target.id }) { candidates = [target] }

        let targets = QuickLookPreviewController.previewTargets(in: candidates, focusedOn: target) {
            dataManager.fileURL(for: $0)
        }
        guard let startIndex = targets.startIndex else { return }

        // プレビュー中の矢印キーで一覧の選択を動かし、その項目をそのまま表示させる。
        // グリッドと同じ moveFocus を通すので、列数ぶんの上下移動もスクロール追従も一致する。
        QuickLookPreviewController.shared.onNavigate = { direction in
            guard let moved = moveFocus(direction, items: items, proxy: proxy) else { return nil }
            return dataManager.fileURL(for: moved)
        }
        QuickLookPreviewController.shared.present(urls: targets.urls, startingAt: startIndex)
    }

    private func ensureSelectionForFocusedItem(in items: [VideoItem]) {
        guard selectedVideoIDs.isEmpty, let item = primaryTarget(in: items) else { return }
        selectedVideoIDs = [item.id]
        lastSelectedVideoID = item.id
        focusedVideoID = item.id
    }

    @MainActor
    private func restoreReturnTarget(items: [VideoItem], proxy: ScrollViewProxy) async {
        guard let targetID = coordinator.returnToMediaID else { return }

        for attempt in 0..<4 {
            if let _ = items.first(where: { $0.id == targetID }) {
                focusedVideoID = targetID
                selectedVideoIDs = [targetID]
                lastSelectedVideoID = targetID
                // プレイヤーから戻ってきた直後もそのまま矢印キーで送れるようにする。
                isGridFocused = true
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
                coordinator.clearReturnTarget()
                return
            }

            if attempt == 3 {
                coordinator.clearReturnTarget()
                return
            }
            await Task.yield()
        }
    }

    /// 選択した項目のコピーを指定フォルダへ書き出す（元ファイルが失われた場合の安全弁）。
    private func exportSelectedItems() {
        // runModal はネストしたイベントループを回すため、パネル表示中もタイマーやHTTP起因の
        // 状態変更で selectedVideoIDs が変わりうる。対象はパネルを開く「前」に確定させる。
        let ids = Array(selectedVideoIDs)
        guard !ids.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "書き出し先のフォルダを選択してください"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        Task {
            isExporting = true
            exportProgress = 0
            exportCurrent = 0
            exportTotal = ids.count
            let result = await dataManager.exportMedia(videoIDs: ids, to: folderURL) { current, total in
                exportCurrent = current
                exportTotal = total
                exportProgress = total == 0 ? 0 : Double(current) / Double(total)
            }
            isExporting = false
            exportResultMessage = result.failedCount > 0
                ? "\(result.successCount)件を書き出しました。\(result.failedCount)件は失敗しました。"
                : "\(result.successCount)件を書き出しました。"
            showExportResultAlert = true
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
