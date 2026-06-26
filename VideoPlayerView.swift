import Foundation
import SwiftUI
import AVKit
import Combine

// MARK: - Single playback (3-A)
// 通常再生モード: 自動チャプターサイドバー / 充実したシーク操作 / 前後の動画へ移動。
// データモデルはサーバーアプリの VideoItem + VideoDataManager.fileURL(for:) に合わせて移植している。

@MainActor
final class VideoPlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var chapterPoints: [ChapterPoint] = []
    @Published var currentVideo: VideoItem

    /// 前後移動の対象となる動画リスト（動画のみ）
    let allVideos: [VideoItem]
    private let dataManager: VideoDataManager
    private var chapterGenerationTask: Task<Void, Never>?

    init(videos: [VideoItem], currentVideo: VideoItem, dataManager: VideoDataManager) {
        self.allVideos = videos
        self.currentVideo = currentVideo
        self.dataManager = dataManager
    }

    func setupPlayer() {
        guard player == nil else { return }
        guard let url = dataManager.fileURL(for: currentVideo) else {
            self.player = nil
            return
        }
        // View 更新中に @Published を変更しないよう次のループで実行する
        Task { @MainActor in
            let newPlayer = AVPlayer(playerItem: AVPlayerItem(url: url))
            self.player = newPlayer
            newPlayer.play()
            self.generateChapterPoints()
        }
    }

    private func generateChapterPoints() {
        chapterGenerationTask?.cancel()
        chapterGenerationTask = Task {
            guard let asset = player?.currentItem?.asset,
                  let duration = try? await asset.load(.duration) else { return }

            await MainActor.run { self.chapterPoints.removeAll() }

            for i in 1...9 {
                if Task.isCancelled { return }
                let percentage = Double(i) / 10.0
                let timeInSeconds = duration.seconds * percentage
                guard timeInSeconds.isFinite else { continue }
                let time = CMTime(seconds: timeInSeconds, preferredTimescale: 600)

                let cgImage = await PlayerThumbnailGenerator.generateLiveThumbnail(for: asset, at: time)
                let chapterPoint = ChapterPoint(
                    percentage: percentage,
                    time: time,
                    thumbnail: cgImage != nil ? Image(nsImage: NSImage(cgImage: cgImage!, size: .zero)) : nil
                )
                await MainActor.run {
                    self.chapterPoints.append(chapterPoint)
                    self.chapterPoints.sort { $0.percentage < $1.percentage }
                }
            }
        }
    }

    func cleanup() {
        chapterGenerationTask?.cancel()
        player?.pause()
        player = nil
    }

    func seek(by seconds: Double) {
        guard let player = player, let currentTime = player.currentItem?.currentTime() else { return }
        let newTime = CMTimeGetSeconds(currentTime) + seconds
        let seekTime = CMTime(seconds: newTime, preferredTimescale: .max)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(toPercentage percentage: Double) {
        guard let player = player, let duration = player.currentItem?.duration, duration.seconds > 0 else { return }
        let targetSeconds = duration.seconds * percentage
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekToRandomTime() {
        guard let player = player, let duration = player.currentItem?.duration, duration.seconds > 0 else { return }
        let randomSeconds = Double.random(in: 0..<duration.seconds)
        let randomTime = CMTime(seconds: randomSeconds, preferredTimescale: 600)
        player.seek(to: randomTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func playPause() {
        guard let player = player else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
    }

    private func changeVideo(to newVideo: VideoItem) {
        self.currentVideo = newVideo
        guard let newURL = dataManager.fileURL(for: newVideo) else { return }
        self.player?.replaceCurrentItem(with: AVPlayerItem(url: newURL))
        self.player?.play()
        generateChapterPoints()
    }

    func playNextVideo() {
        guard let currentIndex = allVideos.firstIndex(of: currentVideo) else { return }
        let nextIndex = currentIndex + 1
        if allVideos.indices.contains(nextIndex) { changeVideo(to: allVideos[nextIndex]) }
    }

    func playPreviousVideo() {
        guard let currentIndex = allVideos.firstIndex(of: currentVideo) else { return }
        let previousIndex = currentIndex - 1
        if allVideos.indices.contains(previousIndex) { changeVideo(to: allVideos[previousIndex]) }
    }
}

/// サイドバーの各チャプター行
private struct ChapterRow: View {
    let chapter: ChapterPoint
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                (chapter.thumbnail ?? Image(systemName: "film"))
                    .resizable()
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .cornerRadius(4)
                Text(chapter.timeString)
                    .font(.caption.monospacedDigit())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct VideoPlayerView: View {
    @StateObject private var viewModel: VideoPlayerViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator

    @FocusState private var isViewFocused: Bool
    @State private var isSidebarVisible = false
    private let sidebarWidth: CGFloat = 240
    private let triggerWidth: CGFloat = 10

    init(videos: [VideoItem], currentVideo: VideoItem, dataManager: VideoDataManager) {
        _viewModel = StateObject(wrappedValue: VideoPlayerViewModel(videos: videos, currentVideo: currentVideo, dataManager: dataManager))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            ZStack {
                Color.black
                PlayerContainerView(player: viewModel.player)
            }
            sidebar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .focusable()
        .focused($isViewFocused)
        .onAppear {
            isViewFocused = true
            viewModel.setupPlayer()
        }
        .onDisappear { viewModel.cleanup() }
        .onKeyPress(phases: .down, action: handleKeyPress)
    }

    /// チャプターサムネイルを表示するサイドバー（右端ホバーで展開）
    private var sidebar: some View {
        ZStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.chapterPoints) { chapter in
                        ChapterRow(chapter: chapter) {
                            viewModel.seek(toPercentage: chapter.percentage)
                        }
                    }
                }
                .padding(8)
            }
            .frame(width: sidebarWidth)
            .background(.regularMaterial)
            .offset(x: isSidebarVisible ? 0 : sidebarWidth)
        }
        .frame(width: isSidebarVisible ? sidebarWidth : triggerWidth)
        .contentShape(Rectangle())
        .onHover { hovering in
            if isSidebarVisible != hovering {
                withAnimation(.easeInOut(duration: 0.2)) { isSidebarVisible = hovering }
            }
        }
    }

    private func handleKeyPress(press: KeyPress) -> KeyPress.Result {
        if let digit = press.key.character.wholeNumberValue {
            viewModel.seek(toPercentage: Double(digit) / 10.0)
            return .handled
        }

        switch press.key {
        case .escape:
            coordinator.close()
            return .handled
        case .space:
            if press.modifiers.contains(.option) { coordinator.close() } else { viewModel.playPause() }
            return .handled
        case "r": viewModel.seekToRandomTime(); return .handled
        case "g": viewModel.seek(by: -15); return .handled
        case "h": viewModel.seek(by: -10); return .handled
        case "j": viewModel.seek(by: -5); return .handled
        case "k": viewModel.playPause(); return .handled
        case "l": viewModel.seek(by: 5); return .handled
        case ";": viewModel.seek(by: 10); return .handled
        case "'": viewModel.seek(by: 15); return .handled
        case .leftArrow: viewModel.playPreviousVideo(); return .handled
        case .rightArrow: viewModel.playNextVideo(); return .handled
        default: return .ignored
        }
    }
}
