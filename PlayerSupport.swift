import SwiftUI
import AVKit
import AVFoundation
import CoreMedia
import Combine

// MARK: - Playback coordinator
//
// 元アプリ同様、再生中はウィンドウ全体をプレイヤーに差し替える（シートではなく全画面）。
// どのモードを表示中かを一元管理し、各プレイヤーは close() で元のライブラリ画面へ戻る。
@MainActor
final class PlaybackCoordinator: ObservableObject {
    enum Mode: Equatable {
        case single(playlist: [VideoItem], current: VideoItem)
        case multi([VideoItem])
        case slideshow([VideoItem])
        case splitPlay(video: VideoItem, splitCount: Int)
        case photos(playlist: [VideoItem], current: VideoItem)
    }

    @Published var mode: Mode?
    @Published var returnToMediaID: UUID?

    var isPresenting: Bool { mode != nil }

    /// 通常再生（再生リスト＋開始位置を指定）
    func playSingle(playlist: [VideoItem], current: VideoItem) {
        let videos = playlist.filter { $0.mediaType == .video }
        let start = (videos.contains(current) ? current : videos.first) ?? current
        mode = .single(playlist: videos.isEmpty ? [current] : videos, current: start)
    }

    /// 表示中リストをシャッフルしてランダム再生
    func playRandom(from videos: [VideoItem]) {
        let shuffled = videos.filter { $0.mediaType == .video }.shuffled()
        guard let first = shuffled.first else { return }
        mode = .single(playlist: shuffled, current: first)
    }

    /// 同時同期再生（2〜9本、9本超は先頭9本）
    func playMulti(_ videos: [VideoItem]) {
        let items = videos.filter { $0.mediaType == .video }
        guard items.count >= 2 else { return }
        mode = .multi(Array(items.prefix(9)))
    }

    /// スライドショー（2本以上）
    func startSlideshow(_ videos: [VideoItem]) {
        let items = videos.filter { $0.mediaType == .video }
        guard items.count >= 2 else { return }
        mode = .slideshow(items)
    }

    /// 分割再生（1本の動画をN分割してグリッドで同期再生）
    func playSplit(video: VideoItem, splitCount: Int) {
        guard video.mediaType == .video else { return }
        mode = .splitPlay(video: video, splitCount: min(max(splitCount, 2), 9))
    }

    /// 画像をウィンドウ全体で表示（動画の全画面再生に相当）
    func viewPhotos(playlist: [VideoItem], current: VideoItem) {
        let photos = playlist.filter { $0.mediaType == .photo }
        let start = (photos.contains(current) ? current : photos.first) ?? current
        mode = .photos(playlist: photos.isEmpty ? [current] : photos, current: start)
    }

    func close() { mode = nil }

    /// プレイヤーを閉じたあとに一覧側で復帰させたい項目を記録する。
    func rememberReturnTarget(mediaID: UUID) {
        returnToMediaID = mediaID
    }

    /// 一覧側で復帰処理を終えたら呼ぶ。
    func clearReturnTarget() {
        returnToMediaID = nil
    }
}

// MARK: - AVKit-safe player surface
//
// SwiftUI の VideoPlayer は _AVKit_SwiftUI のみ参照され AVKit 本体がリンクされず
// 実行時クラッシュするため、各プレイヤーモードはこの AVPlayerView ラッパーを共有して使う。
struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer?
    // .inline は再生コントロール（シークバー）を画面最下部に沿って表示する。
    // .floating だと中央寄りに浮いて動画に被るため inline を既定にしている。
    var controlsStyle: AVPlayerViewControlsStyle = .inline
    var showsFullScreenToggleButton: Bool = true
    var allowsPictureInPicturePlayback: Bool = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = controlsStyle
        view.showsFullScreenToggleButton = showsFullScreenToggleButton
        view.allowsPictureInPicturePlayback = allowsPictureInPicturePlayback
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

// MARK: - プレイヤー共通UI（閉じる・ショートカットヘルプ）

/// プレイヤー画面の隅に重ねる「ヘルプ」「閉じる」ボタンの組。
/// 全プレイヤーで見た目と操作感を揃える。
struct PlayerCornerControls: View {
    @Binding var showShortcutHelp: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                showShortcutHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("キーボードショートカット一覧（?キー）")
            .accessibilityLabel("キーボードショートカット一覧")

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("閉じる（Esc）")
            .accessibilityLabel("プレイヤーを閉じる")
        }
        .padding()
    }
}

/// キーボードショートカットの一覧パネル。?キーまたはヘルプボタンで表示し、
/// クリックか Esc / ? で閉じる。
struct ShortcutHelpPanel: View {
    let title: String
    let shortcuts: [(key: String, action: String)]
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(title, systemImage: "keyboard")
                        .font(.headline)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("ヘルプを閉じる")
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, item in
                        GridRow {
                            Text(item.key)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .gridColumnAlignment(.trailing)
                            Text(item.action)
                                .font(.body)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 24)
        }
        .transition(.opacity)
    }
}

// MARK: - Chapter model

/// プレイヤーサイドバーに表示するチャプター情報を表す構造体
struct ChapterPoint: Identifiable, Hashable {
    let id = UUID()
    let percentage: Double // 0.1, 0.2 ... 0.9
    let time: CMTime
    let thumbnail: Image?

    var timeString: String {
        let totalSeconds = Int(round(CMTimeGetSeconds(time)))
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func == (lhs: ChapterPoint, rhs: ChapterPoint) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Live thumbnail generation (no cache)

/// 再生中プレビュー（チャプター等）用に、キャッシュなしでサムネイルを生成するユーティリティ。
enum PlayerThumbnailGenerator {

    /// 指定された時間からサムネイルを生成する。真っ黒なフレームの場合は少し先で再試行する。
    static func generateLiveThumbnail(for asset: AVAsset, at time: CMTime) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let maxAttempts = 5
        let retryTimeOffset: Double = 2.0

        for attempt in 0..<maxAttempts {
            let attemptTime = CMTimeAdd(time, CMTime(seconds: Double(attempt) * retryTimeOffset, preferredTimescale: 600))
            do {
                let cgImage = try await generator.image(at: attemptTime).image
                if !isPredominantlyBlack(image: cgImage) {
                    return cgImage
                }
            } catch {
                continue
            }
        }
        return try? await generator.image(at: time).image
    }

    /// CGImage が主に黒（非常に暗い色）で構成されているかを判定する。
    private static func isPredominantlyBlack(
        image: CGImage,
        darknessThreshold: UInt8 = 30,
        percentageThreshold: Double = 0.95
    ) -> Bool {
        guard let pixelData = image.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else { return false }

        let width = image.width
        let height = image.height
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return false }

        let totalPixels = width * height
        guard totalPixels > 0 else { return false }

        // パフォーマンスのため最大1万ピクセル程度をサンプリングする
        let step = max(1, totalPixels / 10000)
        let sampleTotal = max(1, totalPixels / step)
        var darkPixelCount = 0

        for i in stride(from: 0, to: totalPixels, by: step) {
            let x = i % width
            let y = i / width
            let offset = (y * image.bytesPerRow) + (x * bytesPerPixel)
            let red = data[offset]
            let green = data[offset + 1]
            let blue = data[offset + 2]
            if red < darknessThreshold && green < darknessThreshold && blue < darknessThreshold {
                darkPixelCount += 1
            }
        }
        return Double(darkPixelCount) / Double(sampleTotal) >= percentageThreshold
    }
}
