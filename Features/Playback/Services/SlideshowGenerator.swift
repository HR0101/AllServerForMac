import AVFoundation
import Foundation

/// 複数のクリップからスライドショーを生成する
enum SlideshowGenerator {

    static func generate(from videos: [VideoItem], clipDuration: TimeInterval, dataManager: LibraryViewModel) async throws -> SlideshowGenerationResult {
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
