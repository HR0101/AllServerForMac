import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation

/// シークバーをなぞっている位置のプレビュー画像を作る。
///
/// チャプター用の `PlayerThumbnailGenerator` と分けているのは狙いが違うため。
/// あちらは「きれいな1枚」を作るために黒フレームを避けて厳密な時刻で取り直すが、
/// なぞっている最中は速さが最優先で、多少ずれたキーフレームで構わない。
@MainActor
final class ScrubPreviewGenerator: ObservableObject {

    @Published private(set) var image: CGImage?
    /// `image` が実際に指している位置。要求した位置とは限らない（近くのキーフレームを使うため）。
    @Published private(set) var seconds: Double = 0

    /// これ未満しか動いていない要求は捨てる。1ピクセル動くたびに作り直さないための歯止め。
    private let minimumStepSeconds: Double = 1.0
    private let maximumSize = CGSize(width: 320, height: 320)

    private var generator: AVAssetImageGenerator?
    private var preparedVideoID: UUID?
    private var task: Task<Void, Never>?
    private var lastRequestedSeconds: Double = .infinity

    /// 動画が変わったら作り直す。同じ動画で何度呼ばれても作り直さない。
    func prepare(asset: AVAsset?, videoID: UUID) {
        guard preparedVideoID != videoID else { return }
        cancel()
        preparedVideoID = videoID
        image = nil
        seconds = 0
        lastRequestedSeconds = .infinity

        guard let asset else {
            generator = nil
            return
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 近くのキーフレームで十分。厳密な時刻を求めると1枚に数百msかかり、なぞる動きに追従できない。
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        generator.maximumSize = maximumSize
        self.generator = generator
    }

    func request(seconds requested: Double) {
        guard let generator, requested.isFinite, requested >= 0 else { return }
        guard abs(requested - lastRequestedSeconds) >= minimumStepSeconds else { return }
        lastRequestedSeconds = requested

        task?.cancel()
        let time = CMTime(seconds: requested, preferredTimescale: 600)
        task = Task { [weak self] in
            // なぞっている最中の連打を捨てるための間。素早く動かしている間は
            // ここで次の要求に追い越されるので、一度もデコードせずに済む。
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            guard let result = try? await generator.image(at: time), !Task.isCancelled else { return }
            self?.image = result.image
            self?.seconds = result.actualTime.seconds
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
