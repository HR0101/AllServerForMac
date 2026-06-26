import Foundation
import SwiftUI
import AVKit
import AVFoundation
import Combine

// MARK: - Slideshow playback (3-C)
// 選択した複数の動画を指定秒数ずつ切り出して1本のスライドショーとして連続再生する。
// クリップ単位のチャプターをサイドバーに表示し、クリックで該当クリップへジャンプできる。

/// スライドショー生成の結果
struct SlideshowGenerationResult {
    let playerItem: AVPlayerItem
    let clipDurations: [TimeInterval]
}

/// 複数のクリップからスライドショーを生成する
enum SlideshowGenerator {

    static func generate(from videos: [VideoItem], clipDuration: TimeInterval, dataManager: VideoDataManager) async throws -> SlideshowGenerationResult {
        let urls: [URL] = videos.compactMap { dataManager.fileURL(for: $0) }

        let composition = AVMutableComposition()
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var actualClipDurations: [TimeInterval] = []

        // レンダーサイズは全クリップの最大サイズに合わせる
        let videoSizes = await withTaskGroup(of: CGSize?.self, returning: [CGSize].self) { group in
            for url in urls {
                group.addTask {
                    let asset = AVURLAsset(url: url)
                    guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
                    return try? await videoTrack.load(.naturalSize)
                }
            }
            var collected: [CGSize] = []
            for await size in group { if let size = size { collected.append(size) } }
            return collected
        }

        let renderSize = CGSize(
            width: videoSizes.map { $0.width }.max() ?? 1920,
            height: videoSizes.map { $0.height }.max() ?? 1080
        )

        var currentTime = CMTime.zero

        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else { continue }

            let assetDurationSeconds = CMTimeGetSeconds(duration)
            let clipDurationSeconds = min(clipDuration, assetDurationSeconds)
            actualClipDurations.append(clipDurationSeconds)

            var startTimeSeconds: Double = 0
            if assetDurationSeconds > clipDuration {
                startTimeSeconds = Double.random(in: 0...(assetDurationSeconds - clipDuration))
            }

            let startTime = CMTime(seconds: startTimeSeconds, preferredTimescale: 600)
            let clipCMTime = CMTime(seconds: clipDurationSeconds, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: startTime, duration: clipCMTime)

            if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
               let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: currentTime)

                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: currentTime, duration: clipCMTime)

                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
                let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? renderSize
                let preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity

                let transformedSize = naturalSize.applying(preferredTransform)
                let videoDisplaySize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
                let scale = max(renderSize.width / videoDisplaySize.width, renderSize.height / videoDisplaySize.height)

                let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
                let scaledSize = videoDisplaySize.applying(scaleTransform)
                let translationTransform = CGAffineTransform(
                    translationX: (renderSize.width - scaledSize.width) / 2.0,
                    y: (renderSize.height - scaledSize.height) / 2.0
                )
                let finalTransform = preferredTransform.concatenating(scaleTransform).concatenating(translationTransform)
                layerInstruction.setTransform(finalTransform, at: .zero)

                instruction.layerInstructions = [layerInstruction]
                instructions.append(instruction)
            }

            if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
               let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: currentTime)
            }

            currentTime = CMTimeAdd(currentTime, clipCMTime)
        }

        let playerItem = AVPlayerItem(asset: composition)
        if !instructions.isEmpty {
            let videoComposition = AVMutableVideoComposition()
            videoComposition.instructions = instructions
            videoComposition.renderSize = renderSize
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            playerItem.videoComposition = videoComposition
        }

        return SlideshowGenerationResult(playerItem: playerItem, clipDurations: actualClipDurations)
    }
}

/// スライドショーのチャプター（クリップ単位）
struct SlideshowChapter: Identifiable, Hashable {
    let id: UUID
    let title: String
    let startTime: TimeInterval
    let sourceURL: URL?
}

@MainActor
final class SlideshowPlayerViewModel: ObservableObject {
    @Published var player: AVPlayer
    @Published var chapters: [SlideshowChapter] = []
    @Published var currentChapterID: UUID?

    private var timeObserver: Any?

    init(playerItem: AVPlayerItem, videos: [VideoItem], clipDurations: [TimeInterval], dataManager: VideoDataManager) {
        self.player = AVPlayer(playerItem: playerItem)

        var accumulatedTime: TimeInterval = 0
        self.chapters = zip(videos, clipDurations).map { (video, duration) in
            let chapter = SlideshowChapter(
                id: video.id,
                title: (video.originalFilename as NSString).deletingPathExtension,
                startTime: accumulatedTime,
                sourceURL: dataManager.fileURL(for: video)
            )
            accumulatedTime += duration
            return chapter
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.updateCurrentChapter(at: time.seconds) }
        }

        self.player.play()
    }

    func seek(to chapter: SlideshowChapter) {
        player.seek(to: CMTime(seconds: chapter.startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func updateCurrentChapter(at currentTime: TimeInterval) {
        if let current = chapters.last(where: { $0.startTime <= currentTime }), current.id != currentChapterID {
            currentChapterID = current.id
        }
    }

    func playPause() {
        if player.rate == 0 { player.play() } else { player.pause() }
    }

    func seek(by seconds: Double) {
        guard let currentTime = player.currentItem?.currentTime() else { return }
        let newTime = CMTimeGetSeconds(currentTime) + seconds
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: .max), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(toPercentage percentage: Double) {
        guard let duration = player.currentItem?.duration, duration.seconds > 0 else { return }
        player.seek(to: CMTime(seconds: duration.seconds * percentage, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekToRandomTime() {
        guard let duration = player.currentItem?.duration, duration.seconds > 0 else { return }
        player.seek(to: CMTime(seconds: Double.random(in: 0..<duration.seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func cleanup() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        player.pause()
    }
}

/// 生成状態を管理し、準備ができたらプレイヤーを表示するラッパーView
struct SlideshowPlayerView: View {
    let videos: [VideoItem]
    let dataManager: VideoDataManager
    @EnvironmentObject private var coordinator: PlaybackCoordinator

    private enum Phase {
        case setup
        case loading
        case playing(SlideshowGenerationResult)
        case error(String)
    }

    @State private var phase: Phase = .setup
    @State private var clipDuration: Double = 15

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case .setup:
                setupForm
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("スライドショーを生成中...").foregroundStyle(.white)
                }
            case .playing(let result):
                SlideshowContentView(
                    playerItem: result.playerItem,
                    videos: videos,
                    clipDurations: result.clipDurations,
                    dataManager: dataManager
                )
            case .error(let message):
                VStack(spacing: 10) {
                    Image(systemName: "xmark.octagon.fill").font(.largeTitle).foregroundStyle(.red)
                    Text(message).foregroundStyle(.white).padding()
                    Button("閉じる") { coordinator.close() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var setupForm: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Image(systemName: "play.square.stack.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                Text("スライドショー")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text("\(videos.count)本の動画から各クリップを切り出して連続再生します")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
            }

            VStack(spacing: 8) {
                HStack {
                    Text("1クリップの長さ")
                    Spacer()
                    Text("\(Int(clipDuration))秒").monospacedDigit()
                }
                .foregroundStyle(.white)
                Slider(value: $clipDuration, in: 1...60, step: 1)
            }
            .frame(maxWidth: 360)

            HStack(spacing: 12) {
                Button("キャンセル") { coordinator.close() }
                    .keyboardShortcut(.cancelAction)
                Button("開始") { startGeneration() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }

    private func startGeneration() {
        phase = .loading
        let seconds = clipDuration
        Task {
            do {
                let result = try await SlideshowGenerator.generate(from: videos, clipDuration: seconds, dataManager: dataManager)
                phase = .playing(result)
            } catch {
                phase = .error("スライドショーの生成に失敗しました: \(error.localizedDescription)")
            }
        }
    }
}

/// チャプターリストの各行（サムネイル付き）
private struct SlideshowChapterRow: View {
    let chapter: SlideshowChapter
    @State private var thumbnail: Image?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.2))
                if let thumbnail = thumbnail { thumbnail.resizable() }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .cornerRadius(4)
            .clipped()

            Text(chapter.title).font(.caption).lineLimit(2)
        }
        .padding(.vertical, 4)
        .task(id: chapter.id) { await generateThumbnail() }
    }

    private func generateThumbnail() async {
        guard thumbnail == nil, let url = chapter.sourceURL else { return }
        let asset = AVURLAsset(url: url)
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        if let cgImage = await PlayerThumbnailGenerator.generateLiveThumbnail(for: asset, at: time) {
            thumbnail = Image(cgImage, scale: 1.0, label: Text("Chapter Thumbnail"))
        }
    }
}

/// 実際のプレイヤーと操作ロジックを持つView
private struct SlideshowContentView: View {
    @StateObject private var viewModel: SlideshowPlayerViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @FocusState private var isFocused: Bool

    @State private var selectedChapterID: UUID?
    @State private var isSidebarVisible = false
    private let sidebarWidth: CGFloat = 250
    private let triggerWidth: CGFloat = 20

    init(playerItem: AVPlayerItem, videos: [VideoItem], clipDurations: [TimeInterval], dataManager: VideoDataManager) {
        _viewModel = StateObject(wrappedValue: SlideshowPlayerViewModel(
            playerItem: playerItem, videos: videos, clipDurations: clipDurations, dataManager: dataManager
        ))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            PlayerContainerView(player: viewModel.player)
                .ignoresSafeArea()

            List(viewModel.chapters, selection: $selectedChapterID) { chapter in
                SlideshowChapterRow(chapter: chapter).tag(chapter.id)
            }
            .frame(width: sidebarWidth)
            .background(.regularMaterial)
            .offset(x: isSidebarVisible ? 0 : -sidebarWidth + triggerWidth)
            .onHover { hovering in isSidebarVisible = hovering }

            VStack {
                HStack {
                    Spacer()
                    Button { coordinator.close() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
                Spacer()
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onDisappear { viewModel.cleanup() }
        .onKeyPress(phases: .down, action: handleKeyPress)
        .onChange(of: selectedChapterID) { _, newID in
            guard let newID = newID, let chapter = viewModel.chapters.first(where: { $0.id == newID }) else { return }
            if abs(viewModel.player.currentTime().seconds - chapter.startTime) > 1 {
                viewModel.seek(to: chapter)
            }
        }
        .onChange(of: viewModel.currentChapterID) { _, newID in
            withAnimation { selectedChapterID = newID }
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
            if press.modifiers.contains(.option) { coordinator.close(); return .handled }
            viewModel.playPause()
            return .handled
        case "r": viewModel.seekToRandomTime(); return .handled
        case "g": viewModel.seek(by: -15); return .handled
        case "h": viewModel.seek(by: -10); return .handled
        case "j": viewModel.seek(by: -5); return .handled
        case "k": viewModel.playPause(); return .handled
        case "l": viewModel.seek(by: 5); return .handled
        case ";": viewModel.seek(by: 10); return .handled
        case "'": viewModel.seek(by: 15); return .handled
        default: return .ignored
        }
    }
}
