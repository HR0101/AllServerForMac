import AVKit
import Combine
import Foundation

@MainActor
final class MultiVideoPlayerViewModel: ObservableObject {
    @Published var players: [AVPlayer] = []
    @Published var commonCurrentTime: Double = 0
    @Published var commonDuration: Double = 1.0

    /// 再生位置合わせ・一斉スタートの面倒はここが見る（差分切り替え再生と共通）。
    private let group: SynchronizedPlayerGroup
    private var isSliderEditing = false

    /// タイル1枚ぶんの音声設定。並びは `players` と同じ＝画面の配置と同じ。
    struct TileAudio: Identifiable {
        let id: Int
        let title: String
        var volume: Float
        var isMuted: Bool
        /// -1（完全に左）〜 0（中央）〜 +1（完全に右）
        var pan: Float
    }

    @Published var tileAudio: [TileAudio] = []
    /// 処理タップへ値を渡す箱。`tileAudio` と同じ並び。
    private var tapSettings: [AudioTapSettings] = []

    init(videos: [VideoItem], dataManager: LibraryViewModel) {
        let playable = videos.compactMap { item -> (VideoItem, URL)? in
            guard let url = dataManager.fileURL(for: item) else { return nil }
            return (item, url)
        }

        self.group = SynchronizedPlayerGroup(urls: playable.map(\.1))
        self.players = group.players

        let defaultPans = MultiPlayerLayout.defaultPans(for: players.count)
        self.tileAudio = playable.enumerated().map { index, entry in
            TileAudio(
                id: index,
                title: entry.0.originalFilename,
                volume: 1,
                isMuted: false,
                pan: defaultPans[index] ?? 0
            )
        }
        self.tapSettings = tileAudio.map { tile in
            let settings = AudioTapSettings()
            settings.update(volume: tile.volume, isMuted: tile.isMuted, pan: tile.pan)
            return settings
        }

        group.onDurationUpdate = { [weak self] duration in
            self?.commonDuration = duration
        }
        group.onTimeUpdate = { [weak self] time in
            guard let self, !self.isSliderEditing else { return }
            self.commonCurrentTime = time
        }
        attachAudioProcessing()
    }

    /// 各プレイヤーの音声トラックに処理タップを挟む。
    /// トラックの読み込みは非同期なので、再生開始を待たせないように後から差し込む。
    private func attachAudioProcessing() {
        for (index, player) in players.enumerated() {
            guard let item = player.currentItem, index < tapSettings.count else { continue }
            let settings = tapSettings[index]
            Task { @MainActor in
                guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
                item.audioMix = MultiPlayerAudio.makeAudioMix(for: track, settings: settings)
            }
        }
    }

    /// コンソールで音量・ミュート・定位をいじったときに、その場で音へ反映する。
    func applyTileAudio(at index: Int) {
        guard tileAudio.indices.contains(index), tapSettings.indices.contains(index) else { return }
        let tile = tileAudio[index]
        tapSettings[index].update(volume: tile.volume, isMuted: tile.isMuted, pan: tile.pan)
    }

    /// 全タイルの定位を、いまの並びから決まる既定値へ戻す（音量・ミュートはそのまま）。
    func resetPansToLayout() {
        let defaultPans = MultiPlayerLayout.defaultPans(for: players.count)
        for index in tileAudio.indices {
            tileAudio[index].pan = defaultPans[index] ?? 0
            applyTileAudio(at: index)
        }
    }

    /// 自分以外を全部ミュートする（1つの音だけ聴きたいとき用）。
    func soloTile(at index: Int) {
        for i in tileAudio.indices {
            tileAudio[i].isMuted = (i != index)
            applyTileAudio(at: i)
        }
    }

    func unmuteAllTiles() {
        for i in tileAudio.indices {
            tileAudio[i].isMuted = false
            applyTileAudio(at: i)
        }
    }

    func commonSliderEditingChanged(isEditing: Bool) {
        self.isSliderEditing = isEditing
        if !isEditing {
            guard commonDuration > 0 else { return }
            seekAll(toPercentage: commonCurrentTime / commonDuration)
        }
    }

    var isPlaying: Bool { group.isPlaying }

    func playAll() { group.play() }

    func pauseAll() { group.pause() }

    func togglePlayPauseAll() {
        if isPlaying { group.pause() } else { group.play() }
    }

    func seekAll(by seconds: Double) { group.seekAll(by: seconds) }

    func seekAll(toPercentage percentage: Double) { group.seekAll(toPercentage: percentage) }

    /// 全動画を同じ秒数（最短動画の範囲内）へランダムシークする
    func seekAllToRandomTime() { group.seekAllToRandomTime() }

    func cleanup() {
        group.cleanup()
        players.removeAll()
    }
}
