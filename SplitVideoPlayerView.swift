import Foundation
import SwiftUI
import AVKit
import Combine

// MARK: - 1本の動画を N 分割して同時再生するプレイヤー
//
// 例: 120秒の動画を4分割 → 0-30s, 30-60s, 60-90s, 90-120s の4つのプレイヤーが
// グリッドに並び、全体のシークバーで同期操作できる。

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
            Task { @MainActor in
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
            let observer = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: boundary)], queue: .main
            ) { [weak self, weak player] in
                Task { @MainActor in
                    guard let self, let player else { return }
                    // セグメント先頭に戻してループ再生
                    let start = CMTime(seconds: self.segmentOffsets[i], preferredTimescale: 600)
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

// MARK: - View

struct SplitVideoPlayerView: View {
    @StateObject private var viewModel: SplitVideoPlayerViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @FocusState private var isFocused: Bool
    private let filename: String
    private let splitCount: Int

    init(video: VideoItem, splitCount: Int, dataManager: VideoDataManager) {
        let url = dataManager.fileURL(for: video) ?? URL(fileURLWithPath: "/dev/null")
        self.filename = video.originalFilename
        self.splitCount = splitCount
        _viewModel = StateObject(wrappedValue: SplitVideoPlayerViewModel(url: url, splitCount: splitCount, duration: video.duration))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            grid
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .focusable()
        .focused($isFocused)
        .onKeyPress(phases: .down, action: handleKeyPress)
        .onAppear {
            viewModel.playAll()
            isFocused = true
        }
        .onDisappear(perform: viewModel.cleanup)
    }

    // MARK: - ヘッダー
    private var header: some View {
        HStack {
            Text("\(filename)  —  \(splitCount)分割再生")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            // 各セグメントの範囲を表示
            ForEach(0..<splitCount, id: \.self) { i in
                let start = viewModel.totalDuration / Double(splitCount) * Double(i)
                let end = start + viewModel.totalDuration / Double(splitCount)
                Text("\(formatTime(start))–\(formatTime(end))")
                    .font(.system(size: 10).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    // MARK: - グリッド（MultiVideoPlayerViewと同じレイアウト）
    @ViewBuilder
    private var grid: some View {
        let players = viewModel.players
        switch players.count {
        case 2:
            HStack(spacing: 2) {
                cellView(players[0])
                cellView(players[1])
            }
        case 3:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    cellView(players[0])
                    cellView(players[1])
                }
                cellView(players[2])
            }
        case 4:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    cellView(players[0])
                    cellView(players[1])
                }
                HStack(spacing: 2) {
                    cellView(players[2])
                    cellView(players[3])
                }
            }
        case 5:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    cellView(players[0])
                    cellView(players[1])
                    cellView(players[2])
                }
                HStack(spacing: 2) {
                    cellView(players[3])
                    cellView(players[4])
                }
            }
        case 6:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    cellView(players[0])
                    cellView(players[1])
                    cellView(players[2])
                }
                HStack(spacing: 2) {
                    cellView(players[3])
                    cellView(players[4])
                    cellView(players[5])
                }
            }
        case 7:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    cellView(players[0])
                    cellView(players[1])
                    cellView(players[2])
                }
                HStack(spacing: 2) {
                    cellView(players[3])
                    cellView(players[4])
                }
                HStack(spacing: 2) {
                    cellView(players[5])
                    cellView(players[6])
                }
            }
        case 8:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    cellView(players[0])
                    cellView(players[1])
                    cellView(players[2])
                }
                HStack(spacing: 2) {
                    cellView(players[3])
                    cellView(players[4])
                    cellView(players[5])
                }
                HStack(spacing: 2) {
                    cellView(players[6])
                    cellView(players[7])
                }
            }
        case 9:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    cellView(players[0])
                    cellView(players[1])
                    cellView(players[2])
                }
                HStack(spacing: 2) {
                    cellView(players[3])
                    cellView(players[4])
                    cellView(players[5])
                }
                HStack(spacing: 2) {
                    cellView(players[6])
                    cellView(players[7])
                    cellView(players[8])
                }
            }
        default:
            Text("再生する動画がありません").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cellView(_ player: AVPlayer) -> some View {
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

    // MARK: - コントロール
    private var controls: some View {
        HStack {
            Text(formatTime(viewModel.commonCurrentTime))
                .font(.caption.monospacedDigit())
            Slider(
                value: $viewModel.commonCurrentTime,
                in: 0...max(viewModel.commonDuration, 0.1)
            ) { isEditing in
                viewModel.commonSliderEditingChanged(isEditing: isEditing)
            }
            Text(formatTime(viewModel.commonDuration))
                .font(.caption.monospacedDigit())
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - キーボード
    private func handleKeyPress(press: KeyPress) -> KeyPress.Result {
        if let digit = press.key.character.wholeNumberValue {
            viewModel.seekAll(toPercentage: Double(digit) / 10.0)
            return .handled
        }
        switch press.key {
        case .escape:
            coordinator.close()
            return .handled
        case .space:
            if press.modifiers.contains(.option) { coordinator.close(); return .handled }
            viewModel.togglePlayPauseAll()
            return .handled
        case "r": viewModel.seekAllToRandomTime(); return .handled
        case "h": viewModel.seekAll(by: -10); return .handled
        case "j": viewModel.seekAll(by: -5); return .handled
        case "k": viewModel.togglePlayPauseAll(); return .handled
        case "l": viewModel.seekAll(by: 5); return .handled
        case ";": viewModel.seekAll(by: 10); return .handled
        default: return .ignored
        }
    }

    private func formatTime(_ time: Double) -> String {
        let seconds = Int(max(0, time))
        guard seconds >= 0 else { return "0:00" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
