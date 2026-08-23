import Foundation
import SwiftUI
import AVKit

// MARK: - 1本の動画を N 分割して同時再生するプレイヤー
//
// 例: 120秒の動画を4分割 → 0-30s, 30-60s, 60-90s, 90-120s の4つのプレイヤーが
// グリッドに並び、全体のシークバーで同期操作できる。

// MARK: - View

struct SplitVideoPlayerView: View {
    @StateObject private var viewModel: SplitVideoPlayerViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @FocusState private var isFocused: Bool
    @State private var showShortcutHelp = false
    /// 操作系の出し入れ（他のプレイヤーと共通）。
    @StateObject private var chrome = PlayerChromeController()
    /// 一時停止中は操作系を出したままにしたいが、`viewModel.isPlaying` は
    /// 実際に走り出すまで真にならない。押した側の意思をこちらで持っておく。
    @State private var isPlayIntended = true
    @AppStorage(MediaShortcutSettings.versionKey) private var shortcutSettingsVersion = 0
    private let filename: String
    private let splitCount: Int

    init(video: VideoItem, splitCount: Int, dataManager: LibraryViewModel) {
        let url = dataManager.fileURL(for: video) ?? URL(fileURLWithPath: "/dev/null")
        self.filename = video.originalFilename
        self.splitCount = splitCount
        _viewModel = StateObject(wrappedValue: SplitVideoPlayerViewModel(url: url, splitCount: splitCount, duration: video.duration))
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
                ("0〜9", "各セグメント内 0%〜90% へジャンプ"),
                ("?", "ショートカット一覧を表示"),
                ("Esc", "プレイヤーを閉じる")
            ]
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 操作系は映像に重ねる。下に積むと、出入りのたびにタイルが伸び縮みしてしまう。
            grid
                .overlay(alignment: .top) {
                    if chrome.isShown {
                        header.transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottom) {
                    if chrome.isShown {
                        controls
                            .playerChromeHoverGuard(chrome)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            if chrome.isShown {
                PlayerCornerControls(showShortcutHelp: $showShortcutHelp) {
                    coordinator.close()
                }
                .playerChromeHoverGuard(chrome)
                .transition(.opacity)
            }
            if showShortcutHelp {
                ShortcutHelpPanel(title: "分割再生のショートカット", shortcuts: shortcutList) {
                    showShortcutHelp = false
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .playerChromeActivity(chrome)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down) { press in
            // 拾ったキーのときだけ操作系を出す（無関係なキーで出てくると邪魔になる）。
            let result = handleKeyPress(press: press)
            if result == .handled { chrome.reveal() }
            return result
        }
        .onAppear {
            viewModel.playAll()
            isFocused = true
            chrome.reveal()
        }
        .onChange(of: showShortcutHelp) { _, shown in
            chrome.setHold(.overlayVisible, shown)
        }
        // 操作系が引っ込んだ時点でポインタは離れているので、そこでキー入力を本体へ戻す。
        .onChange(of: chrome.isShown) { _, shown in
            if !shown { isFocused = true }
        }
        .onDisappear {
            chrome.cancel()
            viewModel.cleanup()
        }
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

    /// 再生・一時停止はここを通す。止めている間は操作系を出したままにしたいので、
    /// 押した意思をここで一元的に反映する（ボタンとキーの両方から呼ぶ）。
    private func togglePlayPause() {
        viewModel.togglePlayPauseAll()
        isPlayIntended.toggle()
        chrome.setHold(.paused, !isPlayIntended)
    }

    // MARK: - コントロール
    private var controls: some View {
        HStack {
            Button {
                togglePlayPause()
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
            togglePlayPause()
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
        let seconds = Int(max(0, time))
        guard seconds >= 0 else { return "0:00" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
