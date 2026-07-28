import Foundation
import SwiftUI
import AVKit

// MARK: - Multi-video synchronized playback (3-B)
// 選択した2〜9個の動画をグリッドに並べ、共通スライダー/キーボードで完全同期して再生する。

/// グリッド内の個々のプレイヤーセル（操作は共通スライダー/キーボードに集約）
private struct PlayerCellView: View {
    let player: AVPlayer
    /// ミキサーを開いている間だけ、コンソールの行と見比べられるよう番号とミュート状態を出す。
    var badgeNumber: Int?
    var isMuted: Bool = false

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
        .overlay(alignment: .topLeading) {
            if let badgeNumber {
                HStack(spacing: 5) {
                    Text("\(badgeNumber)")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                    if isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(8)
            }
        }
    }
}

struct MultiVideoPlayerView: View {
    @StateObject private var viewModel: MultiVideoPlayerViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @FocusState private var isFocused: Bool
    @State private var showShortcutHelp = false
    @State private var isAudioConsoleVisible = false
    @AppStorage(MediaShortcutSettings.versionKey) private var shortcutSettingsVersion = 0
    private let videoCount: Int

    init(videos: [VideoItem], dataManager: LibraryViewModel) {
        _viewModel = StateObject(wrappedValue: MultiVideoPlayerViewModel(videos: videos, dataManager: dataManager))
        self.videoCount = videos.count
    }

    private var shortcutList: [(key: String, action: String)] {
        _ = shortcutSettingsVersion
        return MediaShortcutSettings.shortcutList(
            for: [
                .videoClose,
                .videoPlayPause,
                .videoSeekBack10,
                .videoSeekBack5,
                .videoSeekForward5,
                .videoSeekForward10,
                .videoRandomSeek
            ],
            extraItems: [
                ("0〜9", "0%〜90% の位置へ同時ジャンプ"),
                ("M", "音声ミキサーの表示/非表示"),
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
            if isAudioConsoleVisible {
                audioConsole
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
        // コンソールのボタンやスライダーを押すとフォーカスがそちらへ移り、
        // 以降 .onKeyPress が効かなくなる。開閉のたびに本体へ戻しておく。
        .onChange(of: isAudioConsoleVisible) { _, _ in
            isFocused = true
        }
        .onDisappear(perform: viewModel.cleanup)
    }

    @ViewBuilder
    private var grid: some View {
        let players = viewModel.players
        if players.isEmpty {
            Text("再生する動画がありません").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 2) {
                ForEach(Array(MultiPlayerLayout.rows(for: players.count).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 2) {
                        ForEach(row, id: \.self) { index in
                            PlayerCellView(
                                player: players[index],
                                badgeNumber: isAudioConsoleVisible ? index + 1 : nil,
                                isMuted: viewModel.tileAudio.indices.contains(index)
                                    ? viewModel.tileAudio[index].isMuted
                                    : false
                            )
                        }
                    }
                }
            }
        }
    }

    /// M キーで開閉する音声ミキサー。タイルと同じ並びで出すので、
    /// 画面のどの位置の音を触っているのかが見たままで分かる。
    private var audioConsole: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Label("音声ミキサー", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button("全部鳴らす") { viewModel.unmuteAllTiles() }
                    .help("すべてのミュートを解除")
                Button("定位を配置どおりに") { viewModel.resetPansToLayout() }
                    .help("左右の振り分けを、いまのタイル配置から決まる既定値へ戻す")
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { isAudioConsoleVisible = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .help("ミキサーを閉じる（M / Esc）")
            }

            ForEach(Array(MultiPlayerLayout.rows(for: viewModel.players.count).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(row, id: \.self) { index in
                        tileStrip(index)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 920)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder
    private func tileStrip(_ index: Int) -> some View {
        if viewModel.tileAudio.indices.contains(index) {
            let tile = viewModel.tileAudio[index]
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white.opacity(0.18)))
                    Text(tile.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        viewModel.tileAudio[index].isMuted.toggle()
                        viewModel.applyTileAudio(at: index)
                    } label: {
                        Image(systemName: tile.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 18)
                    }
                    .buttonStyle(.plain)
                    .help(tile.isMuted ? "ミュート解除" : "ミュート")
                    Button {
                        viewModel.soloTile(at: index)
                    } label: {
                        Text("SOLO").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("これだけ鳴らす（他を全部ミュート）")
                }

                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.1")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { viewModel.tileAudio[index].volume },
                            set: {
                                viewModel.tileAudio[index].volume = $0
                                viewModel.applyTileAudio(at: index)
                            }
                        ),
                        in: 0...1
                    )
                    .controlSize(.mini)
                    .disabled(tile.isMuted)
                }

                HStack(spacing: 6) {
                    Text("L")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { viewModel.tileAudio[index].pan },
                            set: {
                                viewModel.tileAudio[index].pan = $0
                                viewModel.applyTileAudio(at: index)
                            }
                        ),
                        in: -1...1
                    )
                    .controlSize(.mini)
                    .disabled(tile.isMuted)
                    Text("R")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(minWidth: 210)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.25)))
            .opacity(tile.isMuted ? 0.55 : 1)
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
        if MediaShortcutSettings.matches(.videoClose, press: press) {
            coordinator.close()
            return .handled
        }

        if let digit = press.key.character.wholeNumberValue {
            viewModel.seekAll(toPercentage: Double(digit) / 10.0)
            return .handled
        }
        switch press.key {
        case .escape:
            if showShortcutHelp {
                showShortcutHelp = false
            } else if isAudioConsoleVisible {
                withAnimation(.easeOut(duration: 0.18)) { isAudioConsoleVisible = false }
            } else {
                coordinator.close()
            }
            return .handled
        case "?":
            showShortcutHelp.toggle()
            return .handled
        case "m", "M":
            withAnimation(.easeOut(duration: 0.18)) { isAudioConsoleVisible.toggle() }
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
