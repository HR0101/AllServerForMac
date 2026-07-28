import Combine
import Foundation

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
    /// 通常再生をIキーで右下に小さくたたみ、アルバム一覧を裏に表示している間 true。
    @Published var isMiniPlayerActive = false

    var isPresenting: Bool { mode != nil }

    /// 通常再生（再生リスト＋開始位置を指定）
    func playSingle(playlist: [VideoItem], current: VideoItem) {
        let videos = playlist.filter { $0.mediaType == .video }
        let start = (videos.contains(current) ? current : videos.first) ?? current
        isMiniPlayerActive = false
        mode = .single(playlist: videos.isEmpty ? [current] : videos, current: start)
    }

    /// 表示中リストをシャッフルしてランダム再生
    func playRandom(from videos: [VideoItem]) {
        let shuffled = videos.filter { $0.mediaType == .video }.shuffled()
        guard let first = shuffled.first else { return }
        isMiniPlayerActive = false
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

    func close() {
        mode = nil
        isMiniPlayerActive = false
    }

    /// プレイヤーを閉じたあとに一覧側で復帰させたい項目を記録する。
    func rememberReturnTarget(mediaID: UUID) {
        returnToMediaID = mediaID
    }

    /// 一覧側で復帰処理を終えたら呼ぶ。
    func clearReturnTarget() {
        returnToMediaID = nil
    }
}
