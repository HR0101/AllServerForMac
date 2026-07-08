import SwiftUI
import AVKit

// アプリ内でのメディア再生・表示ビュー（動画: AVPlayer / 画像: NSImage）
struct MediaPreviewView: View {
    @State var item: VideoItem
    var items: [VideoItem] = []
    let dataManager: VideoDataManager
    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @State private var player: AVPlayer?
    @State private var photo: NSImage?
    @State private var fileMissing = false
    @AppStorage("isMangaMode") private var isMangaMode = false
    @State private var photoCache: [UUID: NSImage] = [:]
    @State private var loadingTask: Task<Void, Never>?
    @State private var preloadTask: Task<Void, Never>?

    private var currentIndex: Int? {
        items.firstIndex(where: { $0.id == item.id })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 760, idealWidth: 920, minHeight: 500, idealHeight: 640)
        .onAppear(perform: load)
        .onDisappear {
            loadingTask?.cancel()
            preloadTask?.cancel()
            player?.pause()
            player = nil
        }
        .onChange(of: item.id) { _, _ in
            load()
        }
    }

    private func changeItem(offset: Int) {
        guard let idx = currentIndex else { return }
        let nextIdx = idx + offset
        if nextIdx >= 0 && nextIdx < items.count {
            item = items[nextIdx]
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: item.mediaType == .video ? "play.rectangle.fill" : "photo.fill")
                .foregroundStyle(.secondary)
            Text(item.originalFilename)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            if item.mediaType == .video, item.duration > 0 {
                Text(formatDuration(item.duration))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !items.isEmpty && items.count > 1 && item.mediaType == .photo {
                Button(action: {
                    isMangaMode.toggle()
                }) {
                    Text(isMangaMode ? "漫画モード" : "通常モード")
                        .font(.system(size: 11))
                        .foregroundColor(isMangaMode ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)

                Text("\(currentIndex! + 1) / \(items.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if item.mediaType == .photo {
                Button {
                    let list = items.isEmpty ? [item] : items
                    let target = item
                    dismiss()
                    // シートを閉じてから全画面ビューア（ウィンドウ全体差し替え）へ切り替える
                    DispatchQueue.main.async {
                        coordinator.viewPhotos(playlist: list, current: target)
                    }
                } label: {
                    Label("全画面表示", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("f", modifiers: [])
            }

            Button {
                if let url = dataManager.fileURL(for: item) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("外部プレイヤーで開く", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)

            Button("閉じる") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if fileMissing {
            ContentUnavailableView(
                "ファイルが見つかりません",
                systemImage: "questionmark.video",
                description: Text("メディアファイルが移動または削除された可能性があります")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.mediaType == .video {
            PlayerContainerView(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else {
            ZStack {
                Color.black
                if let photo = photo {
                    GeometryReader { geo in
                        Image(nsImage: photo)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                let w = geo.size.width
                                if location.x < w * 0.3 {
                                    changeItem(offset: isMangaMode ? 1 : -1)
                                } else if location.x > w * 0.7 {
                                    changeItem(offset: isMangaMode ? -1 : 1)
                                }
                            }
                    }
                } else {
                    ProgressView()
                }

                if !items.isEmpty {
                    HStack {
                        Button("") { changeItem(offset: -1) }.keyboardShortcut(isMangaMode ? .rightArrow : .leftArrow, modifiers: []).opacity(0)
                        Button("") { changeItem(offset: 1) }.keyboardShortcut(isMangaMode ? .leftArrow : .rightArrow, modifiers: []).opacity(0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() {
        loadingTask?.cancel()
        player?.pause()
        player = nil
        fileMissing = false

        guard let url = dataManager.fileURL(for: item) else {
            photo = nil
            fileMissing = true
            return
        }
        if item.mediaType == .video {
            photo = nil
            let p = AVPlayer(url: url)
            player = p
            p.play()
        } else {
            if let cached = photoCache[item.id] {
                photo = cached
                preloadNeighborPhotos()
                return
            }

            photo = nil
            let targetID = item.id
            loadingTask = Task.detached(priority: .userInitiated) {
                let image = PhotoImageLoader.loadDisplayImage(from: url)
                await MainActor.run {
                    guard item.id == targetID else { return }
                    if let image = image {
                        photoCache[targetID] = image
                        photo = image
                        trimPhotoCache()
                        preloadNeighborPhotos()
                    } else {
                        fileMissing = true
                    }
                }
            }
        }
    }

    private func preloadNeighborPhotos() {
        guard item.mediaType == .photo, let index = currentIndex else { return }
        preloadTask?.cancel()
        let neighborIndexes = [index - 1, index + 1].filter { items.indices.contains($0) }
        let targets = neighborIndexes
            .map { items[$0] }
            .filter { $0.mediaType == .photo && photoCache[$0.id] == nil }
            .compactMap { item -> (UUID, URL)? in
                guard let url = dataManager.fileURL(for: item) else { return nil }
                return (item.id, url)
            }

        guard !targets.isEmpty else { return }

        preloadTask = Task.detached(priority: .utility) {
            for (id, url) in targets {
                guard !Task.isCancelled else { return }
                guard let image = PhotoImageLoader.loadDisplayImage(from: url) else { continue }
                await MainActor.run {
                    guard photoCache[id] == nil else { return }
                    photoCache[id] = image
                    trimPhotoCache()
                }
            }
        }
    }

    private func trimPhotoCache() {
        guard let index = currentIndex else { return }
        let keepIndexes = [index - 1, index, index + 1].filter { items.indices.contains($0) }
        let keepIDs = Set(keepIndexes.map { items[$0].id })
        photoCache = photoCache.filter { keepIDs.contains($0.key) }
    }

    private func formatDuration(_ totalSeconds: TimeInterval) -> String {
        let s = Int(totalSeconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
