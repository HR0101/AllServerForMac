import AppKit
import Foundation
import MediaPlayer

/// コントロールセンター・メニューバーの「再生中」表示と、キーボードの再生キー（F8 など）の受け口。
///
/// 通常再生は AVKit のコントロールを使わない（`controlsStyle = .none`）ため、
/// AVKit が自動で面倒を見てくれる分がまるごと無い。ここで明示的に登録する。
/// 登録した target は必ず `deactivate()` で外す。外し忘れると次に開いたプレイヤーと
/// 二重に反応して、1回のキーで2回シークするといった壊れ方をする。
@MainActor
final class NowPlayingCenter {

    struct Handlers {
        let play: () -> Void
        let pause: () -> Void
        let toggle: () -> Void
        let next: () -> Void
        let previous: () -> Void
        /// 絶対位置へのシーク（秒）。
        let seek: (Double) -> Void
        /// 相対シーク（秒、負なら戻る）。
        let skip: (Double) -> Void
    }

    /// リモートコマンドの送り戻し幅。プレイヤー側の 15 秒シークに合わせる。
    private let skipIntervalSeconds: Double = 15

    private var registeredTargets: [(MPRemoteCommand, Any)] = []
    private var isActive = false
    /// アートワークの作り直しは重い（JPEG を読み直す）。update は再生・一時停止・シークの
    /// たびに呼ばれるので、同じ動画の間は使い回す。
    private var cachedArtwork: (url: URL, artwork: MPMediaItemArtwork)?

    func activate(handlers: Handlers) {
        guard !isActive else { return }
        isActive = true

        let center = MPRemoteCommandCenter.shared()

        add(center.playCommand) { handlers.play() }
        add(center.pauseCommand) { handlers.pause() }
        add(center.togglePlayPauseCommand) { handlers.toggle() }
        add(center.nextTrackCommand) { handlers.next() }
        add(center.previousTrackCommand) { handlers.previous() }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipIntervalSeconds)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipIntervalSeconds)]
        add(center.skipForwardCommand) { [skipIntervalSeconds] in handlers.skip(skipIntervalSeconds) }
        add(center.skipBackwardCommand) { [skipIntervalSeconds] in handlers.skip(-skipIntervalSeconds) }

        // シークバーのドラッグだけは引数付きなので個別に登録する。
        let seekCommand = center.changePlaybackPositionCommand
        seekCommand.isEnabled = true
        let seekTarget = seekCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            handlers.seek(event.positionTime)
            return .success
        }
        registeredTargets.append((seekCommand, seekTarget))
    }

    /// 表示内容の更新。経過時間はシステムが速度から補間するので、
    /// 再生・一時停止・シーク・曲の切り替えといった節目でだけ呼べばよい。
    func update(title: String, duration: TimeInterval, elapsed: TimeInterval, rate: Double, artworkURL: URL?) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        // サムネイルは生成済みのものを使い回す。無ければ絵なしで出す（表示自体は成立する）。
        if let artworkURL, let artwork = artwork(at: artworkURL) {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = rate > 0 ? .playing : .paused
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        for (command, target) in registeredTargets {
            command.removeTarget(target)
        }
        registeredTargets.removeAll()
        cachedArtwork = nil

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    private func artwork(at url: URL) -> MPMediaItemArtwork? {
        if let cachedArtwork, cachedArtwork.url == url { return cachedArtwork.artwork }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        cachedArtwork = (url, artwork)
        return artwork
    }

    private func add(_ command: MPRemoteCommand, action: @escaping () -> Void) {
        command.isEnabled = true
        let target = command.addTarget { _ in
            action()
            return .success
        }
        registeredTargets.append((command, target))
    }
}
