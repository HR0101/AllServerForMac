import SwiftUI
import UniformTypeIdentifiers

struct MainSidebarView: View {
    @ObservedObject var dataManager: VideoDataManager
    @Binding var selection: NavigationSelection?

    @State private var isShowingAddAlbumSheet = false
    @State private var newAlbumName = ""
    @State private var newAlbumType: AlbumType = .video
    @State private var albumToDelete: Album?

    @State private var isSidebarTargeted = false
    @State private var showSidebarMixedContentAlert = false
    @State private var pendingSidebarFolderURL: URL?
    @State private var sidebarMixedContentInfo = ""

    @State private var isShowingStorageManager = false

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
                NavigationLink(value: NavigationSelection.faces) {
                    sidebarRowLabel("顔認識グループ", systemImage: "person.crop.rectangle.stack", count: FaceDatabase.shared.clusters.count)
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

    private func nonTrashedCount(in album: Album) -> Int {
        let trashed = Set(dataManager.trashedVideos.map { $0.id })
        return album.videoIDs.filter { !trashed.contains($0) }.count
    }

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
