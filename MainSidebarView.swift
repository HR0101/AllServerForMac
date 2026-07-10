import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

/// サイドバーのアルバムをドラッグする際のペイロード。
/// フォルダは実体を持たず名前の "/" 区切りだけで表現されるため、
/// ドロップ側は名前の付け替え（VideoDataManager.renameAlbums）で移動を実現する。
private struct AlbumDragPayload: Codable, Transferable {
    /// 移動対象となる実アルバムのID群（フォルダごとドラッグした場合はその配下全部）
    var albumIDs: [UUID]
    /// フォルダそのものをドラッグした場合の、そのフォルダの完全パス（例: "旅行/2024年"）。
    /// 単体アルバムのドラッグの場合は nil（末尾の名前だけを残して移動先直下に置く）。
    var sourceFolderPath: String?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .allServerAlbumDrag)
    }
}

private extension UTType {
    static let allServerAlbumDrag = UTType(exportedAs: "hr.AllServerForMac.album-drag-payload")
}

struct MainSidebarView: View {
    @ObservedObject var dataManager: VideoDataManager
    @ObservedObject var webServerManager: WebServerManager
    @Binding var selection: NavigationSelection?

    @State private var isShowingPreferences = false

    @State private var isShowingAddAlbumSheet = false
    @State private var newAlbumName = ""
    @State private var newAlbumType: AlbumType = .video
    @State private var albumDeletionRequest: AlbumDeletionRequest?
    @State private var isAlbumSelectionMode = false
    @State private var selectedAlbumIDs = Set<UUID>()

    @State private var isSidebarTargeted = false
    @State private var showSidebarMixedContentAlert = false
    @State private var pendingSidebarFolderURL: URL?
    @State private var sidebarMixedContentInfo = ""

    @State private var isShowingStorageManager = false

    @State private var isShowingCreateFolderFromSelectionAlert = false
    @State private var newFolderNameForSelection = ""
    @State private var dropTargetFolderID: String?

    // サイドバーへ個別ファイル（フォルダではない写真・動画）を直接ドロップしたときに、
    // 新規アルバム名を入力させて取り込むための状態
    @State private var isShowingSidebarFileImportAlbumNameAlert = false
    @State private var newAlbumNameForSidebarFileImport = ""
    @State private var pendingSidebarFileURLs: [URL] = []

    // サイドバーからアルバム/フォルダをまるごとエクスポートするときの進捗
    @State private var isExportingFromSidebar = false
    @State private var sidebarExportCurrent = 0
    @State private var sidebarExportTotal = 0
    @State private var sidebarExportResultMessage = ""
    @State private var showSidebarExportResultAlert = false

    // 以下はサイドバーの再描画のたびに全件スキャンし直すと重くなるためキャッシュする。
    // selection（クリックしたアルバム）が変わるだけでもサイドバー全体が再描画されるため、
    // キャッシュなしだと「アルバムをクリックするたびにライブラリ全件を再集計する」状態になっていた。
    // dataManager.videos / .albums が実際に変化したときだけ refreshSidebarCaches() で更新する。
    @State private var cachedTrashedVideoIDs: Set<UUID> = []
    @State private var cachedVideoAlbumNodes: [SidebarAlbumNode] = []
    @State private var cachedPhotoAlbumNodes: [SidebarAlbumNode] = []

    /// 展開中のフォルダ（動画/画像ツリーで独立させるため dropKey と同じキーを使う）。
    /// DisclosureGroup 標準の「＞」は当たり判定が小さいため、タイトルをクリックしても
    /// 開閉できるようにこの状態を明示的に持つ。
    @State private var expandedFolderIDs: Set<String> = []

    var body: some View {
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
            if isExportingFromSidebar {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Text("エクスポート中... \(sidebarExportCurrent) / \(sidebarExportTotal)")
                        .foregroundColor(.white)
                        .font(.caption)
                }
                .padding()
                .background(.thickMaterial)
                .cornerRadius(12)
            }
        }
        .alert("エクスポート完了", isPresented: $showSidebarExportResultAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(sidebarExportResultMessage)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { isShowingStorageManager = true }) {
                    Label("ストレージ管理", systemImage: "internaldrive")
                }
                .help("ストレージの内訳とクリーンアップ")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { isShowingPreferences = true }) {
                    Label("詳細設定", systemImage: "gearshape")
                }
                .help("データの安全性・サーバー保護・パフォーマンスの設定")
            }
        }
        .sheet(isPresented: $isShowingStorageManager) {
            StorageManagerView(dataManager: dataManager)
        }
        .sheet(isPresented: $isShowingPreferences) {
            PreferencesView(dataManager: dataManager, webServerManager: webServerManager)
        }
        .onDrop(of: [.fileURL], isTargeted: $isSidebarTargeted) { providers in
            handleDropOnSidebar(providers: providers)
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

    private var albumSectionHeader: some View {
        HStack {
            Text("アルバム")
            Spacer()
            albumSectionHeaderButtons
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dropTargetFolderID == "" ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        // フォルダの外（ルート）へドラッグして戻すためのドロップ領域
        .dropDestination(for: AlbumDragPayload.self) { payloads, _ in
            handleAlbumDrop(payloads, ontoFolderPath: "")
        } isTargeted: { targeted in
            dropTargetFolderID = targeted ? "" : (dropTargetFolderID == "" ? nil : dropTargetFolderID)
        }
        .help("ここにドラッグするとフォルダの外（最上位）に移動します")
    }

    @ViewBuilder
    private var albumSectionHeaderButtons: some View {
        if isAlbumSelectionMode {
            Button(action: { newFolderNameForSelection = ""; isShowingCreateFolderFromSelectionAlert = true }) {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .disabled(selectedAlbumIDs.isEmpty)
            .help("選択したアルバムを新しいフォルダにまとめる")

            Button(action: requestSelectedAlbumDeletion) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(selectedAlbumIDs.isEmpty)
            .help("選択したアルバムを削除")

            Button(action: exitAlbumSelectionMode) {
                Text("完了")
            }
            .buttonStyle(.plain)
        } else {
            Button(action: { isShowingAddAlbumSheet = true }) {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            .help("新規アルバムを作成")

            Button(action: { isAlbumSelectionMode = true }) {
                Image(systemName: "checklist")
            }
            .buttonStyle(.plain)
            .help("複数選択")
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

            Section(header: albumSectionHeader) {
                // 動画アルバムと画像アルバムは別々のツリーとして棲み分ける
                // （フォルダはアルバム名の "/" 区切りだけで表現されるため、混在すると
                // 同名フォルダで動画と画像が同じ階層に混ざって見えてしまう）。
                // ツリー自体は cachedVideoAlbumNodes / cachedPhotoAlbumNodes （refreshSidebarCaches() で更新）を使う。
                ForEach(cachedVideoAlbumNodes) { node in
                    sidebarAlbumNodeRow(node, isPhotoTree: false)
                }

                ForEach(cachedPhotoAlbumNodes) { node in
                    sidebarAlbumNodeRow(node, isPhotoTree: true)
                }
            }
        }
        .listStyle(SidebarListStyle())
        .scrollContentBackground(.hidden)
        .background(CommandDeckBackground())
        .tint(DS.cyan)
        .onAppear {
            refreshSidebarCaches()
            revealSelectedAlbumInSidebar()
        }
        .onChange(of: dataManager.videos) { refreshSidebarCaches() }
        // albums 変更時に自動展開まで行うと、ユーザーが手で閉じたフォルダが
        // バックグラウンドのライブラリ変化をきっかけに勝手に再展開されてしまう。
        // 自動展開は「ユーザーがアルバムを開いた（selection が変わった）」ときだけに限定する。
        .onChange(of: dataManager.albums) { refreshSidebarCaches() }
        // アルバムを開いたときに、それがフォルダの中に畳まれていても選択箇所が
        // ひと目でわかるよう、該当フォルダを自動で展開する。
        .onChange(of: selection) { revealSelectedAlbumInSidebar() }
        .sheet(isPresented: $isShowingAddAlbumSheet) {
            addAlbumSheet
        }
        .confirmationDialog(
            "アルバムの削除",
            isPresented: albumDeletionDialogBinding,
            titleVisibility: .visible,
            presenting: albumDeletionRequest
        ) { request in
            Button("アルバムだけ削除して ALL PHOTOS / ALL VIDEOS に残す") {
                performAlbumDeletion(request, contentDisposal: .keep)
            }
            Button("中身をゴミ箱に入れる") {
                performAlbumDeletion(request, contentDisposal: .trash)
            }
            Button("中身ごと完全に削除", role: .destructive) {
                performAlbumDeletion(request, contentDisposal: .delete)
            }
            Button("キャンセル", role: .cancel) {
                albumDeletionRequest = nil
            }
        } message: { request in
            Text(deletionMessage(for: request))
        }
        .alert("新規フォルダを作成", isPresented: $isShowingCreateFolderFromSelectionAlert) {
            TextField("フォルダ名", text: $newFolderNameForSelection)
            Button("作成", action: createFolderFromSelection)
            Button("キャンセル", role: .cancel) { newFolderNameForSelection = "" }
        } message: {
            Text("選択した\(selectedAlbumIDs.count)件のアルバムをこのフォルダの中に移動します。")
        }
        .alert("新規アルバムに取り込む", isPresented: $isShowingSidebarFileImportAlbumNameAlert) {
            TextField("アルバム名", text: $newAlbumNameForSidebarFileImport)
            Button("作成して取り込む", action: importSidebarDroppedFiles)
            Button("キャンセル", role: .cancel) { pendingSidebarFileURLs = []; newAlbumNameForSidebarFileImport = "" }
        } message: {
            Text("ドロップした\(pendingSidebarFileURLs.count)件のファイルを、新しく作るアルバムに取り込みます。")
        }
    }

    private func sidebarRowLabel(_ title: String, systemImage: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium, design: .rounded))
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(DS.cyan.opacity(0.75))
        }
    }

    private func sidebarSelectableRowLabel(_ title: String, systemImage: String, count: Int, isSelected: Bool) -> some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Label(title, systemImage: systemImage)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func sidebarAlbumRow(album: Album, title: String, systemImage: String) -> AnyView {
        if isAlbumSelectionMode {
            return AnyView(Button {
                toggleAlbumSelection(album.id)
            } label: {
                sidebarSelectableRowLabel(title, systemImage: systemImage, count: nonTrashedCount(in: album), isSelected: selectedAlbumIDs.contains(album.id))
            }
            .buttonStyle(.plain))
        }

        return AnyView(NavigationLink(value: NavigationSelection.album(album.id)) {
            sidebarRowLabel(title, systemImage: systemImage, count: nonTrashedCount(in: album))
        }
        .draggable(AlbumDragPayload(albumIDs: [album.id], sourceFolderPath: nil))
        .contextMenu {
            Button("フォルダにエクスポート…") {
                exportAlbums(albumIDs: [album.id])
            }
            Divider()
            Button("削除", role: .destructive) {
                requestAlbumDeletion(albumIDs: [album.id])
            }
        })
    }

    private func iconForAlbum(_ album: Album) -> String {
        album.type == .photo ? "photo.on.rectangle.angled" : "folder.fill"
    }

    private func nonTrashedCount(in album: Album) -> Int {
        album.videoIDs.filter { !cachedTrashedVideoIDs.contains($0) }.count
    }

    private func nonTrashedCount(in node: SidebarAlbumNode) -> Int {
        let ownCount = node.album.map { nonTrashedCount(in: $0) } ?? 0
        let childCount = node.children.reduce(0) { $0 + nonTrashedCount(in: $1) }
        return ownCount + childCount
    }

    /// isPhotoTree: この行が動画ツリーと画像ツリーのどちら側のものか。
    /// ドラッグ&ドロップやフォルダの識別（ハイライト用キー）を型ごとに分離するために使う。
    private func sidebarAlbumNodeRow(_ node: SidebarAlbumNode, isPhotoTree: Bool) -> AnyView {
        if node.children.isEmpty, let album = node.album {
            return sidebarAlbumRow(album: album, title: node.name, systemImage: iconForAlbum(album))
        } else {
            let key = dropKey(forPath: node.id, isPhotoTree: isPhotoTree)
            return AnyView(DisclosureGroup(isExpanded: expandedBinding(for: key)) {
                if let album = node.album {
                    sidebarAlbumRow(album: album, title: "このフォルダ内のメディア", systemImage: iconForAlbum(album))
                }

                ForEach(node.children) { child in
                    sidebarAlbumNodeRow(child, isPhotoTree: isPhotoTree)
                }
            } label: {
                folderRowLabel(node, isPhotoTree: isPhotoTree)
            }
            .contextMenu {
                if let album = node.album, album.linkedFolderPath != nil || album.linkedFolderBookmarkData != nil {
                    Button("紐づけフォルダを更新") {
                        rescanLinkedFolder(albumID: album.id)
                    }
                } else {
                    Button("フォルダを紐づけ…") {
                        linkFolderToNode(node, isPhotoTree: isPhotoTree)
                    }
                }
                Divider()
                Button("フォルダにエクスポート…") {
                    exportAlbums(albumIDs: albumIDs(in: node))
                }
                Divider()
                Button("削除", role: .destructive) {
                    requestAlbumDeletion(albumIDs: albumIDs(in: node))
                }
            })
        }
    }

    private func linkFolderToNode(_ node: SidebarAlbumNode, isPhotoTree: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "「\(node.id)」に紐づけるFinderフォルダを選択してください"

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        Task {
            let albumID: UUID?
            if let existingID = node.album?.id {
                albumID = existingID
            } else {
                albumID = dataManager.createAlbum(name: node.id, type: isPhotoTree ? .photo : .video)
            }

            guard let albumID else { return }
            await dataManager.linkFolder(folderURL: folderURL, to: albumID)
        }
    }

    private func rescanLinkedFolder(albumID: UUID) {
        Task {
            await dataManager.rescanLinkedFolder(albumID: albumID)
        }
    }

    /// 指定したアルバム群のメディア（ゴミ箱を除く）を、選んだフォルダへまとめてエクスポートする。
    /// アルバム名（"/" 区切りの階層含む）とファイル名はサーバー上の登録どおりに再現される
    /// （VideoDataManager.exportMedia 側で解決する）。
    private func exportAlbums(albumIDs: [UUID]) {
        let targetIDs = Set(albumIDs)
        let videoIDs = dataManager.albums
            .filter { targetIDs.contains($0.id) }
            .flatMap { $0.videoIDs }
            .filter { !cachedTrashedVideoIDs.contains($0) }
        let uniqueVideoIDs = Array(Set(videoIDs))
        guard !uniqueVideoIDs.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "書き出し先のフォルダを選択してください"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        Task {
            isExportingFromSidebar = true
            sidebarExportCurrent = 0
            sidebarExportTotal = uniqueVideoIDs.count
            let result = await dataManager.exportMedia(videoIDs: uniqueVideoIDs, to: folderURL) { current, total in
                sidebarExportCurrent = current
                sidebarExportTotal = total
            }
            isExportingFromSidebar = false
            sidebarExportResultMessage = result.failedCount > 0
                ? "\(result.successCount)件を書き出しました。\(result.failedCount)件は失敗しました。"
                : "\(result.successCount)件を書き出しました。"
            showSidebarExportResultAlert = true
        }
    }

    private func dropKey(forPath path: String, isPhotoTree: Bool) -> String {
        (isPhotoTree ? "photo:" : "video:") + path
    }

    private func expandedBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { expandedFolderIDs.contains(key) },
            set: { isExpanded in
                if isExpanded { expandedFolderIDs.insert(key) } else { expandedFolderIDs.remove(key) }
            }
        )
    }

    @ViewBuilder
    private func folderRowLabel(_ node: SidebarAlbumNode, isPhotoTree: Bool) -> some View {
        let key = dropKey(forPath: node.id, isPhotoTree: isPhotoTree)
        Group {
            if isAlbumSelectionMode {
                sidebarSelectableRowLabel(node.name, systemImage: "folder.fill", count: nonTrashedCount(in: node), isSelected: isAlbumNodeSelected(node))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleAlbumNodeSelection(node)
                    }
            } else {
                sidebarRowLabel(node.name, systemImage: "folder.fill", count: nonTrashedCount(in: node))
                    .contentShape(Rectangle())
                    // 標準の「＞」だけだと当たり判定が小さいため、タイトル行全体のクリックでも開閉できるようにする。
                    .onTapGesture {
                        if expandedFolderIDs.contains(key) { expandedFolderIDs.remove(key) } else { expandedFolderIDs.insert(key) }
                    }
                    .draggable(AlbumDragPayload(albumIDs: albumIDs(in: node), sourceFolderPath: node.id))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dropTargetFolderID == key ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        // 既存フォルダへドラッグしたアルバム（単体・別フォルダごと）を受け取る。
        // 動画ツリー/画像ツリーをまたぐドロップは handleAlbumDrop 内の型チェックで無視される。
        .dropDestination(for: AlbumDragPayload.self) { payloads, _ in
            handleAlbumDrop(payloads, ontoFolderPath: node.id, restrictToPhoto: isPhotoTree)
        } isTargeted: { targeted in
            dropTargetFolderID = targeted ? key : (dropTargetFolderID == key ? nil : dropTargetFolderID)
        }
    }

    /// ドロップされたアルバム（単体 or フォルダごと）を指定フォルダパス配下へ移動する。
    /// folderPath が空文字ならルート直下（フォルダの外）へ出す。自分自身・自分の子孫フォルダへの
    /// ドロップは循環を避けるため無視する。restrictToPhoto でドロップ先の型を指定し、動画アルバムが
    /// 画像ツリーへ（またはその逆）紛れ込まないようにする（動画/画像は棲み分ける）。
    /// nil はルート（フォルダの外）へのドロップ用で、型を問わずそのまま戻す。
    @discardableResult
    private func handleAlbumDrop(_ payloads: [AlbumDragPayload], ontoFolderPath folderPath: String, restrictToPhoto: Bool? = nil) -> Bool {
        for payload in payloads {
            if let sourcePath = payload.sourceFolderPath,
               folderPath == sourcePath || folderPath.hasPrefix(sourcePath + "/") {
                continue
            }

            let targetIDs = Set(payload.albumIDs)
            var renames: [UUID: String] = [:]
            for album in dataManager.albums where targetIDs.contains(album.id) {
                if let restrictToPhoto, (album.type == .photo) != restrictToPhoto { continue }
                renames[album.id] = newAlbumName(for: album, movingTo: folderPath, draggedFolderPath: payload.sourceFolderPath)
            }
            dataManager.renameAlbums(renames)
        }
        return true
    }

    /// 移動後の新しいアルバム名を計算する。
    /// - フォルダごとのドラッグなら、そのフォルダ自身の相対パス構造を保ったまま移動先へ付け替える
    ///   （Finderでフォルダを移動したときと同様、フォルダ自身の名前は保たれる）。
    /// - 単体アルバムのドラッグなら、末尾の名前だけを残して移動先直下に置く。
    private func newAlbumName(for album: Album, movingTo folderPath: String, draggedFolderPath: String?) -> String {
        let relative: String
        if let draggedFolderPath,
           album.name == draggedFolderPath || album.name.hasPrefix(draggedFolderPath + "/") {
            let parentPath = draggedFolderPath.components(separatedBy: "/").dropLast().joined(separator: "/")
            let stripLength = parentPath.isEmpty ? 0 : parentPath.count + 1
            relative = String(album.name.dropFirst(stripLength))
        } else {
            relative = album.name.components(separatedBy: "/").last ?? album.name
        }
        return folderPath.isEmpty ? relative : "\(folderPath)/\(relative)"
    }

    private func createFolderFromSelection() {
        let name = newFolderNameForSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderNameForSelection = ""
        guard !name.isEmpty, !selectedAlbumIDs.isEmpty else { return }

        let targetIDs = selectedAlbumIDs
        var renames: [UUID: String] = [:]
        for album in dataManager.albums where targetIDs.contains(album.id) {
            renames[album.id] = "\(name)/\(album.name)"
        }
        dataManager.renameAlbums(renames)

        selectedAlbumIDs.removeAll()
        isAlbumSelectionMode = false
    }

    private func buildAlbumTree(from albums: [Album]) -> [SidebarAlbumNode] {
        final class NodeBuilder {
            let id: String
            let name: String
            var album: Album?
            var children: [String: NodeBuilder] = [:]

            init(id: String, name: String) {
                self.id = id
                self.name = name
            }

            func makeNode() -> SidebarAlbumNode {
                SidebarAlbumNode(
                    id: id,
                    name: name,
                    album: album,
                    children: children.values
                        .map { $0.makeNode() }
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                )
            }
        }

        let root = NodeBuilder(id: "root", name: "root")

        for album in albums {
            let parts = album.name
                .components(separatedBy: "/")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }

            var current = root
            var currentPath = ""

            for (index, part) in parts.enumerated() {
                currentPath += (currentPath.isEmpty ? "" : "/") + part
                if current.children[part] == nil {
                    current.children[part] = NodeBuilder(id: currentPath, name: part)
                }
                current = current.children[part]!

                if index == parts.count - 1 {
                    current.album = album
                }
            }
        }

        return root.children.values
            .map { $0.makeNode() }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var albumDeletionDialogBinding: Binding<Bool> {
        Binding(
            get: { albumDeletionRequest != nil },
            set: { isPresented in
                if !isPresented {
                    albumDeletionRequest = nil
                }
            }
        )
    }

    private func toggleAlbumSelection(_ albumID: UUID) {
        if selectedAlbumIDs.contains(albumID) {
            selectedAlbumIDs.remove(albumID)
        } else {
            selectedAlbumIDs.insert(albumID)
        }
    }

    private func toggleAlbumNodeSelection(_ node: SidebarAlbumNode) {
        let ids = Set(albumIDs(in: node))
        guard !ids.isEmpty else { return }

        if ids.isSubset(of: selectedAlbumIDs) {
            selectedAlbumIDs.subtract(ids)
        } else {
            selectedAlbumIDs.formUnion(ids)
        }
    }

    private func isAlbumNodeSelected(_ node: SidebarAlbumNode) -> Bool {
        let ids = Set(albumIDs(in: node))
        return !ids.isEmpty && ids.isSubset(of: selectedAlbumIDs)
    }

    private func albumIDs(in node: SidebarAlbumNode) -> [UUID] {
        var ids = node.album.map { [$0.id] } ?? []
        ids.append(contentsOf: node.children.flatMap { albumIDs(in: $0) })
        return ids
    }

    private func requestAlbumDeletion(albumIDs: [UUID]) {
        let ids = orderedDeletableAlbumIDs(from: albumIDs)
        guard !ids.isEmpty else { return }
        albumDeletionRequest = AlbumDeletionRequest(albumIDs: ids)
    }

    private func requestSelectedAlbumDeletion() {
        requestAlbumDeletion(albumIDs: Array(selectedAlbumIDs))
    }

    private func orderedDeletableAlbumIDs(from albumIDs: [UUID]) -> [UUID] {
        let targetIDs = Set(albumIDs)
        return dataManager.albums
            .filter {
                targetIDs.contains($0.id) &&
                $0.name != VideoDataManager.allVideosAlbumName &&
                $0.name != VideoDataManager.allPhotosAlbumName
            }
            .map { $0.id }
    }

    private func deletionMessage(for request: AlbumDeletionRequest) -> String {
        let albums = albums(for: request)
        let mediaCount = Set(albums.flatMap { $0.videoIDs }).count
        let targetDescription: String
        if albums.count == 1, let album = albums.first {
            targetDescription = "「\(album.name)」"
        } else {
            targetDescription = "\(albums.count)件のアルバム"
        }

        return "\(targetDescription)を削除します。\nアルバムだけ削除する場合，\(mediaCount)件の中身は ALL PHOTOS / ALL VIDEOS に残ります。\n中身をゴミ箱に入れる場合，後から元に戻せます。\n中身ごと完全に削除する場合，対象メディアはライブラリから完全に削除され元に戻せません。"
    }

    private func albums(for request: AlbumDeletionRequest) -> [Album] {
        let ids = Set(request.albumIDs)
        return dataManager.albums.filter { ids.contains($0.id) }
    }

    private func performAlbumDeletion(_ request: AlbumDeletionRequest, contentDisposal: VideoDataManager.AlbumContentDisposal) {
        let ids = orderedDeletableAlbumIDs(from: request.albumIDs)
        dataManager.deleteAlbums(albumIDs: ids, contentDisposal: contentDisposal)

        if case .album(let selectedID) = selection, ids.contains(selectedID) {
            selection = .home
        }

        selectedAlbumIDs.subtract(ids)
        if selectedAlbumIDs.isEmpty {
            isAlbumSelectionMode = false
        }
        albumDeletionRequest = nil
    }

    private func exitAlbumSelectionMode() {
        isAlbumSelectionMode = false
        selectedAlbumIDs.removeAll()
    }

    /// 現在選択中のアルバムが、畳まれたフォルダの中に隠れていないよう祖先フォルダを展開する。
    /// DisclosureGroup は閉じたままだと選択ハイライトが見えず「今どこを見ているか」が
    /// わからなくなるため、アルバムを開くたびに呼ぶ。
    private func revealSelectedAlbumInSidebar() {
        guard case .album(let albumID) = selection else { return }
        if let path = Self.folderPath(containing: albumID, in: cachedVideoAlbumNodes) {
            for folderID in path { expandedFolderIDs.insert(dropKey(forPath: folderID, isPhotoTree: false)) }
        }
        if let path = Self.folderPath(containing: albumID, in: cachedPhotoAlbumNodes) {
            for folderID in path { expandedFolderIDs.insert(dropKey(forPath: folderID, isPhotoTree: true)) }
        }
    }

    /// albumID にたどり着くまでに開いておく必要がある祖先フォルダの id（パス文字列）を返す。
    /// 見つからなければ nil。
    private static func folderPath(containing albumID: UUID, in nodes: [SidebarAlbumNode], ancestors: [String] = []) -> [String]? {
        for node in nodes {
            if node.children.isEmpty {
                if node.album?.id == albumID { return ancestors }
                continue
            }
            // フォルダ自身が「このフォルダ内のメディア」として同じアルバムを指しているケース
            if node.album?.id == albumID { return ancestors + [node.id] }
            if let found = folderPath(containing: albumID, in: node.children, ancestors: ancestors + [node.id]) {
                return found
            }
        }
        return nil
    }

    /// dataManager.videos / .albums の変化に追従してキャッシュを更新する。
    /// selection の変化だけではここは呼ばれない（body 内で直接計算していないため）。
    private func refreshSidebarCaches() {
        cachedTrashedVideoIDs = Set(dataManager.trashedVideos.map { $0.id })

        let userAlbums = dataManager.albums.filter { $0.name != VideoDataManager.allVideosAlbumName && $0.name != VideoDataManager.allPhotosAlbumName }
        cachedVideoAlbumNodes = buildAlbumTree(from: userAlbums.filter { $0.type != .photo })
        cachedPhotoAlbumNodes = buildAlbumTree(from: userAlbums.filter { $0.type == .photo })
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

            Divider()

            Button(action: importAlbumFromFolder) {
                Label("フォルダをインポートして作成", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("フォルダを選ぶと、そのフォルダ名でアルバムを作成し中身を一括インポートします")
        }
        .padding(24)
        .frame(width: 320)
    }

    /// フォルダを選んで、そのフォルダ名のアルバムを作成しつつ中身を一括インポートする。
    /// サイドバーへのドラッグ＆ドロップと同じ挙動（混在時は同じ確認アラートを使う）。
    private func importAlbumFromFolder() {
        // 「新規アルバム」シートを表示したまま NSOpenPanel（別のモーダル）を重ねて開くと、
        // モーダル同士が競合してパネルが正しく開かない／即座にキャンセル扱いになることがある。
        // そのため先にシートを閉じ、閉じるアニメーションが終わるのを少し待ってからパネルを開く。
        isShowingAddAlbumSheet = false
        newAlbumName = ""
        newAlbumType = .video

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "アルバムとしてインポートするフォルダを選択してください"

            guard panel.runModal() == .OK, let folderURL = panel.url else {
                print("⚠️ [IMPORT-BTN] パネルがキャンセルされたか、フォルダURLが取得できませんでした")
                return
            }
            print("📥 [IMPORT-BTN] フォルダ選択: \(folderURL.path)")

            let counts = dataManager.scanFolder(folderURL: folderURL)
            print("📥 [IMPORT-BTN] フォルダ内訳: 動画=\(counts.videoCount)件 画像=\(counts.photoCount)件")
            if counts.videoCount > 0 && counts.photoCount > 0 {
                sidebarMixedContentInfo = "動画: \(counts.videoCount)件, 画像: \(counts.photoCount)件"
                pendingSidebarFolderURL = folderURL
                showSidebarMixedContentAlert = true
                return
            }
            if counts.videoCount == 0 && counts.photoCount == 0 {
                print("⚠️ [IMPORT-BTN] フォルダ内に対応するメディアが見つかりませんでした: \(folderURL.path)")
            }

            let albumType: AlbumType = counts.photoCount > 0 ? .photo : .video
            Task {
                print("📥 [IMPORT-BTN] importFolder開始: \(folderURL.path) as \(albumType)")
                await dataManager.importFolder(folderURL: folderURL, as: albumType)
                print("📥 [IMPORT-BTN] importFolder完了: \(folderURL.path)")
            }
        }
    }

    private func handleDropOnSidebar(providers: [NSItemProvider]) -> Bool {
        print("📥 [DROP] サイドバーへのドロップを受け取りました: providers=\(providers.count)")
        loadDroppedURLs(from: providers) { urls in
            print("📥 [DROP] URL解決結果: \(urls.count)件 \(urls.map { $0.path })")
            var folderURLs: [URL] = []
            var fileURLs: [URL] = []
            for url in urls {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    print("⚠️ [DROP] fileExists=false: \(url.path)")
                    continue
                }
                if isDirectory.boolValue { folderURLs.append(url) } else { fileURLs.append(url) }
            }
            print("📥 [DROP] 分類結果: フォルダ=\(folderURLs.count)件 ファイル=\(fileURLs.count)件")

            guard !folderURLs.isEmpty || !fileURLs.isEmpty else {
                print("⚠️ [DROP] フォルダ・ファイルどちらも見つからなかったため何もしません")
                return
            }

            if folderURLs.count == 1, fileURLs.isEmpty, let folderURL = folderURLs.first {
                let counts = dataManager.scanFolder(folderURL: folderURL)
                print("📥 [DROP] フォルダ内訳: 動画=\(counts.videoCount)件 画像=\(counts.photoCount)件")
                if counts.videoCount > 0 && counts.photoCount > 0 {
                    self.sidebarMixedContentInfo = "動画: \(counts.videoCount)件, 画像: \(counts.photoCount)件"
                    self.pendingSidebarFolderURL = folderURL
                    self.showSidebarMixedContentAlert = true
                    return
                }
                if counts.videoCount == 0 && counts.photoCount == 0 {
                    print("⚠️ [DROP] フォルダ内に対応するメディアが見つかりませんでした: \(folderURL.path)")
                }
            }

            if !folderURLs.isEmpty {
                Task {
                    for folderURL in folderURLs {
                        let counts = dataManager.scanFolder(folderURL: folderURL)
                        let albumType: AlbumType = counts.photoCount > 0 ? .photo : .video
                        print("📥 [DROP] importFolder開始: \(folderURL.path) as \(albumType)")
                        await dataManager.importFolder(folderURL: folderURL, as: albumType)
                        print("📥 [DROP] importFolder完了: \(folderURL.path)")
                    }
                }
            }

            // フォルダではなく個別ファイル（写真・動画）を直接ドロップした場合は、
            // 取り込み先のアルバム名が自明ではないため、名前を入力してもらってから新規アルバムに取り込む。
            if !fileURLs.isEmpty {
                print("📥 [DROP] 個別ファイルのアルバム名入力アラートを表示します")
                self.pendingSidebarFileURLs = fileURLs
                self.newAlbumNameForSidebarFileImport = ""
                self.isShowingSidebarFileImportAlbumNameAlert = true
            }
        }
        return true
    }

    private func importSidebarDroppedFiles() {
        let name = newAlbumNameForSidebarFileImport.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = pendingSidebarFileURLs
        pendingSidebarFileURLs = []
        newAlbumNameForSidebarFileImport = ""
        guard !name.isEmpty, !urls.isEmpty,
              let newAlbumID = dataManager.createAlbum(name: name, type: .mixed) else { return }
        Task { await dataManager.importMediaFiles(from: urls, to: newAlbumID) }
    }

    private func loadDroppedURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
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
                let url = Self.resolveDroppedURL(from: item)
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

    private static func resolveDroppedURL(from item: NSSecureCoding?) -> URL? {
        let url: URL?
        if let data = item as? Data {
            url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let itemURL = item as? URL {
            url = itemURL
        } else if let itemURL = item as? NSURL {
            url = itemURL as URL
        } else {
            url = nil
        }

        guard let url else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }
}

private struct SidebarAlbumNode: Identifiable {
    let id: String
    let name: String
    let album: Album?
    let children: [SidebarAlbumNode]
}

private struct AlbumDeletionRequest: Identifiable {
    let id = UUID()
    let albumIDs: [UUID]
}
