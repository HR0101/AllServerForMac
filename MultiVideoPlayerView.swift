import Foundation
import SwiftUI
import AVKit
import Combine

// MARK: - Multi-video synchronized playback (3-B)
// 選択した2〜9個の動画をグリッドに並べ、共通スライダー/キーボードで完全同期して再生する。

@MainActor
final class MultiVideoPlayerViewModel: ObservableObject {
    @Published var players: [AVPlayer] = []
    @Published var commonCurrentTime: Double = 0
    @Published var commonDuration: Double = 1.0

    private var leadPlayerTimeObserver: Any?
    private var leadPlayer: AVPlayer?
    private var cancellables = Set<AnyCancellable>()
    private var isSliderEditing = false

    init(videos: [VideoItem], dataManager: VideoDataManager) {
        self.players = videos.compactMap { item -> AVPlayer? in
            guard let url = dataManager.fileURL(for: item) else { return nil }
            return AVPlayer(url: url)
        }
        setupLeadPlayerObserver()
    }

    private func setupLeadPlayerObserver() {
        guard let leadPlayer = players.max(by: {
            ($0.currentItem?.duration.seconds ?? 0) < ($1.currentItem?.duration.seconds ?? 0)
        }) else { return }
        self.leadPlayer = leadPlayer

        leadPlayer.publisher(for: \.currentItem?.duration)
            .compactMap { $0?.seconds }
            .filter { !$0.isNaN && $0 > 0 }
            .assign(to: &$commonDuration)

        leadPlayerTimeObserver = leadPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isSliderEditing else { return }
                self.commonCurrentTime = time.seconds
            }
        }
    }

    func commonSliderEditingChanged(isEditing: Bool) {
        self.isSliderEditing = isEditing
        if !isEditing {
            guard commonDuration > 0 else { return }
            seekAll(toPercentage: commonCurrentTime / commonDuration)
        }
    }

    var isPlaying: Bool { players.contains { $0.rate > 0 } }

    func playAll() { players.forEach { $0.play() } }

    func togglePlayPauseAll() {
        if isPlaying {
            players.forEach { $0.pause() }
        } else {
            players.forEach { $0.play() }
        }
    }

    func seekAll(by seconds: Double) {
        for player in players {
            guard let currentTime = player.currentItem?.currentTime() else { continue }
            let newTime = CMTimeGetSeconds(currentTime) + seconds
            player.seek(to: CMTime(seconds: newTime, preferredTimescale: .max), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func seekAll(toPercentage percentage: Double) {
        for player in players {
            guard let duration = player.currentItem?.duration, duration.seconds > 0 else { continue }
            let targetTime = CMTime(seconds: duration.seconds * percentage, preferredTimescale: 600)
            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// 全動画を同じ秒数（最短動画の範囲内）へランダムシークする
    func seekAllToRandomTime() {
        let shortestDuration = players.compactMap { $0.currentItem?.duration.seconds }.min() ?? 0
        guard shortestDuration > 0 else { return }
        let seekCMTime = CMTime(seconds: Double.random(in: 0..<shortestDuration), preferredTimescale: 600)
        for player in players {
            player.seek(to: seekCMTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func cleanup() {
        if let observer = leadPlayerTimeObserver {
            leadPlayer?.removeTimeObserver(observer)
            leadPlayerTimeObserver = nil
        }
        leadPlayer = nil
        players.forEach { $0.pause() }
        players.removeAll()
    }
}

/// グリッド内の個々のプレイヤーセル（操作は共通スライダー/キーボードに集約）
private struct PlayerCellView: View {
    let player: AVPlayer

    var body: some View {
        PlayerContainerView(
            player: player,
            controlsStyle: .none,
            showsFullScreenToggleButton: false,
            allowsPictureInPicturePlayback: false
        )
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }
}

struct MultiVideoPlayerView: View {
    @StateObject private var viewModel: MultiVideoPlayerViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @FocusState private var isFocused: Bool
    @State private var showShortcutHelp = false
    @AppStorage(MediaShortcutSettings.versionKey) private var shortcutSettingsVersion = 0
    private let videoCount: Int

    init(videos: [VideoItem], dataManager: VideoDataManager) {
        _viewModel = StateObject(wrappedValue: MultiVideoPlayerViewModel(videos: videos, dataManager: dataManager))
        self.videoCount = videos.count
    }

    private var shortcutList: [(key: String, action: String)] {
        _ = shortcutSettingsVersion
        return MediaShortcutSettings.shortcutList(
            for: [
                .videoPlayPause,
                .videoSeekBack10,
                .videoSeekBack5,
                .videoSeekForward5,
                .videoSeekForward10,
                .videoRandomSeek
            ],
            extraItems: [
                ("0〜9", "0%〜90% の位置へ同時ジャンプ"),
                ("?", "ショートカット一覧を表示"),
                ("Esc", "プレイヤーを閉じる")
            ]
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                grid
                controls
            }
            PlayerCornerControls(showShortcutHelp: $showShortcutHelp) {
                coordinator.close()
            }
            if showShortcutHelp {
                ShortcutHelpPanel(title: "同時再生のショートカット", shortcuts: shortcutList) {
                    showShortcutHelp = false
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down, action: handleKeyPress)
        .onAppear {
            viewModel.playAll()
            isFocused = true
        }
        .onDisappear(perform: viewModel.cleanup)
    }

    @ViewBuilder
    private var grid: some View {
        let players = viewModel.players
        switch players.count {
        case 2:
            VStack(spacing: 2) {
                PlayerCellView(player: players[0])
                PlayerCellView(player: players[1])
            }
        case 3, 4:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    PlayerCellView(player: players[0])
                    PlayerCellView(player: players[1])
                }
                HStack(spacing: 2) {
                    PlayerCellView(player: players[2])
                    if players.count == 4 { PlayerCellView(player: players[3]) }
                }
            }
        case 5:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    PlayerCellView(player: players[0])
                    PlayerCellView(player: players[1])
                    PlayerCellView(player: players[2])
                }
                HStack(spacing: 2) {
                    PlayerCellView(player: players[3])
                    PlayerCellView(player: players[4])
                }
            }
        case 6:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    PlayerCellView(player: players[0])
                    PlayerCellView(player: players[1])
                }
                HStack(spacing: 2) {
                    PlayerCellView(player: players[2])
                    PlayerCellView(player: players[3])
                }
                HStack(spacing: 2) {
                    PlayerCellView(player: players[4])
                    PlayerCellView(player: players[5])
                }
            }
        case 7:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    PlayerCellView(player: players[0])
                    PlayerCellView(player: players[1])
                    PlayerCellView(player: players[2])
                }
                HStack(spacing: 2) {
                    PlayerCellView(player: players[3])
                    PlayerCellView(player: players[4])
                }
                HStack(spacing: 2) {
                    PlayerCellView(player: players[5])
                    PlayerCellView(player: players[6])
                }
            }
        case 8, 9:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    PlayerCellView(player: players[0])
                    PlayerCellView(player: players[1])
                    PlayerCellView(player: players[2])
                }
                HStack(spacing: 2) {
                    PlayerCellView(player: players[3])
                    PlayerCellView(player: players[4])
                    PlayerCellView(player: players[5])
                }
                HStack(spacing: 2) {
                    PlayerCellView(player: players[6])
                    if players.count > 7 { PlayerCellView(player: players[7]) }
                    if players.count > 8 { PlayerCellView(player: players[8]) }
                }
            }
        default:
            if let player = players.first {
                PlayerCellView(player: player)
            } else {
                Text("再生する動画がありません").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var controls: some View {
        HStack {
            Button {
                viewModel.togglePlayPauseAll()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .help(viewModel.isPlaying ? "一時停止（Space）" : "再生（Space）")
            .accessibilityLabel(viewModel.isPlaying ? "一時停止" : "再生")

            Text(formatTime(viewModel.commonCurrentTime))
                .font(.caption.monospacedDigit())
            Slider(value: $viewModel.commonCurrentTime, in: 0...max(viewModel.commonDuration, 0.1)) { isEditing in
                viewModel.commonSliderEditingChanged(isEditing: isEditing)
            }
            Text(formatTime(viewModel.commonDuration))
                .font(.caption.monospacedDigit())
        }
        .padding()
        .background(.regularMaterial)
    }

    private func handleKeyPress(press: KeyPress) -> KeyPress.Result {
        if let digit = press.key.character.wholeNumberValue {
            viewModel.seekAll(toPercentage: Double(digit) / 10.0)
            return .handled
        }
        switch press.key {
        case .escape:
            if showShortcutHelp { showShortcutHelp = false } else { coordinator.close() }
            return .handled
        case "?":
            showShortcutHelp.toggle()
            return .handled
        case .space:
            if press.modifiers.contains(.option) {
                coordinator.close()
                return .handled
            }
            break
        default:
            break
        }

        if MediaShortcutSettings.matches(.videoPlayPause, press: press) {
            viewModel.togglePlayPauseAll()
            return .handled
        } else if MediaShortcutSettings.matches(.videoRandomSeek, press: press) {
            viewModel.seekAllToRandomTime()
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekBack10, press: press) {
            viewModel.seekAll(by: -10)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekBack5, press: press) {
            viewModel.seekAll(by: -5)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekForward5, press: press) {
            viewModel.seekAll(by: 5)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekForward10, press: press) {
            viewModel.seekAll(by: 10)
            return .handled
        }

        return .ignored
    }

    private func formatTime(_ time: Double) -> String {
        let seconds = Int(time)
        guard seconds >= 0 else { return "0:00" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
