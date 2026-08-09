import AVKit
import Combine
import Foundation

@MainActor
final class SlideshowPlayerViewModel: ObservableObject {
    @Published var player: AVPlayer
    @Published var chapters: [SlideshowChapter] = []
    @Published var currentChapterID: UUID?

    private var timeObserver: Any?

    init(playerItem: AVPlayerItem, videos: [VideoItem], clipDurations: [TimeInterval], dataManager: LibraryViewModel) {
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
            Task { @MainActor [weak self] in
                self?.updateCurrentChapter(at: time.seconds)
            }
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
