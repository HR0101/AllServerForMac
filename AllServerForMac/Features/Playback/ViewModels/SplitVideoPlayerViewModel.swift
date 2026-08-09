import AVKit
import Combine
import Foundation

@MainActor
final class SplitVideoPlayerViewModel: ObservableObject {
    @Published var players: [AVPlayer] = []
    @Published var commonCurrentTime: Double = 0   // リードプレイヤー基準の再生位置
    @Published var commonDuration: Double = 1.0     // 各セグメントの長さ
    @Published var totalDuration: Double = 1.0      // 元動画の全体長

    let splitCount: Int
    private let segmentDuration: Double
    private let segmentOffsets: [Double]            // 各セグメントの開始秒
    private var leadPlayer: AVPlayer?
    private var leadObserver: Any?
    private var isSliderEditing = false
    private var boundaryObservers: [Any] = []

    /// video: ローカルファイルURL, splitCount: 分割数 (2〜9), duration: 動画の尺(秒)
    init(url: URL, splitCount: Int, duration: TimeInterval) {
        self.splitCount = min(max(splitCount, 2), 9)

        let effectiveDuration = duration > 0 ? duration : 1.0
        self.totalDuration = effectiveDuration

        let segLen = effectiveDuration / Double(self.splitCount)
        self.segmentDuration = segLen
        self.commonDuration = segLen

        var offsets: [Double] = []
        var pls: [AVPlayer] = []
        for i in 0..<self.splitCount {
            let offset = segLen * Double(i)
            offsets.append(offset)
            let player = AVPlayer(url: url)
            player.seek(to: CMTime(seconds: offset, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            pls.append(player)
        }
        self.segmentOffsets = offsets
        self.players = pls

        setupLeadObserver()
        setupBoundaryObservers()
    }

    // MARK: - リードプレイヤーの時間追従
    private func setupLeadObserver() {
        guard let lead = players.first else { return }
        self.leadPlayer = lead

        leadObserver = lead.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isSliderEditing else { return }
                // リードプレイヤーの「セグメント内での経過時間」を表示
                let elapsed = time.seconds - self.segmentOffsets[0]
                if elapsed >= 0 && elapsed <= self.segmentDuration {
                    self.commonCurrentTime = elapsed
                }
            }
        }
    }

    // MARK: - セグメント末尾で自動ループ
    private func setupBoundaryObservers() {
        for (i, player) in players.enumerated() {
            let endTime = segmentOffsets[i] + segmentDuration
            let boundary = CMTime(seconds: endTime, preferredTimescale: 600)
            let segmentOffset = segmentOffsets[i]
            let observer = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: boundary)], queue: .main
            ) { [weak self, weak player, segmentOffset] in
                Task { @MainActor [weak self, weak player, segmentOffset] in
                    guard let self, let player else { return }
                    // セグメント先頭に戻してループ再生
                    let start = CMTime(seconds: segmentOffset, preferredTimescale: 600)
                    player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
                    player.play()
                }
            }
            boundaryObservers.append(observer)
        }
    }

    // MARK: - 操作
    var isPlaying: Bool { players.contains { $0.rate > 0 } }

    func playAll() { players.forEach { $0.play() } }

    func togglePlayPauseAll() {
        if isPlaying {
            players.forEach { $0.pause() }
        } else {
            players.forEach { $0.play() }
        }
    }

    /// 各セグメント内で相対シーク
    func seekAll(by seconds: Double) {
        for (i, player) in players.enumerated() {
            let cur = player.currentTime().seconds
            let newTime = min(max(segmentOffsets[i], cur + seconds),
                              segmentOffsets[i] + segmentDuration)
            player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// 各セグメント内での割合指定シーク
    func seekAll(toPercentage pct: Double) {
        let offset = segmentDuration * min(max(pct, 0), 1)
        for (i, player) in players.enumerated() {
            let target = segmentOffsets[i] + offset
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// 各セグメント内でランダム位置へシーク
    func seekAllToRandomTime() {
        let offset = Double.random(in: 0..<segmentDuration)
        for (i, player) in players.enumerated() {
            let target = segmentOffsets[i] + offset
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func commonSliderEditingChanged(isEditing: Bool) {
        self.isSliderEditing = isEditing
        if !isEditing {
            seekAll(toPercentage: commonCurrentTime / segmentDuration)
        }
    }

    func cleanup() {
        if let obs = leadObserver, let lp = leadPlayer {
            lp.removeTimeObserver(obs)
        }
        leadObserver = nil
        leadPlayer = nil
        for (i, obs) in boundaryObservers.enumerated() {
            if i < players.count {
                players[i].removeTimeObserver(obs)
            }
        }
        boundaryObservers.removeAll()
        players.forEach { $0.pause(); $0.replaceCurrentItem(with: nil) }
        players.removeAll()
    }
}
