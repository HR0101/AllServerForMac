import AVKit
import SwiftUI

// MARK: - 差分切り替え再生
//
// 同じ尺・同じ動きの差分動画を重ねて置き、完全同期で全部走らせたまま
// 見せる1枚だけを入れ替える。切り替えは「どれを不透明にするか」でしかないので継ぎ目が出ない。
//
// 重ねたビューを `if` で出し分けると、切り替えのたびに AVPlayerView が作り直されて
// 一瞬黒くなる。全部を常に置いたまま `opacity` だけ変えるのが要点。

struct VariantSwitchPlayerView: View {
    @StateObject private var viewModel: VariantSwitchPlayerViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @FocusState private var isFocused: Bool
    @State private var showShortcutHelp = false
    @State private var isPanelVisible = true
    @AppStorage(MediaShortcutSettings.versionKey) private var shortcutSettingsVersion = 0

    /// キーで間隔を刻むときの幅。
    private static let intervalStep: Double = 0.5

    init(videos: [VideoItem], dataManager: LibraryViewModel) {
        _viewModel = StateObject(wrappedValue: VariantSwitchPlayerViewModel(videos: videos, dataManager: dataManager))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                stack
                if isPanelVisible {
                    controlPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            PlayerCornerControls(
                showShortcutHelp: $showShortcutHelp,
                volume: $viewModel.volume,
                isMuted: $viewModel.isMuted
            ) {
                coordinator.close()
            }
            if showShortcutHelp {
                ShortcutHelpPanel(title: "差分切り替え再生のショートカット", shortcuts: shortcutList) {
                    showShortcutHelp = false
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down, action: handleKeyPress)
        .onAppear {
            viewModel.start()
            isFocused = true
        }
        // パネルのボタンやスライダーを押すとフォーカスがそちらへ移り、
        // 以降 .onKeyPress が効かなくなる。開閉のたびに本体へ戻しておく。
        .onChange(of: isPanelVisible) { _, _ in isFocused = true }
        .onDisappear(perform: viewModel.cleanup)
    }

    // MARK: - 映像

    @ViewBuilder
    private var stack: some View {
        if viewModel.players.isEmpty {
            Text("再生する動画がありません")
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                ForEach(Array(viewModel.players.enumerated()), id: \.offset) { index, player in
                    PlayerContainerView(
                        player: player,
                        controlsStyle: .none,
                        showsFullScreenToggleButton: false,
                        allowsPictureInPicturePlayback: false
                    )
                    .opacity(index == viewModel.activeIndex ? 1 : 0)
                    // 裏に回っているぶんはクリックを拾わせない（重なり順の一番上が全部持っていくため）。
                    .allowsHitTesting(index == viewModel.activeIndex)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { activeBadge }
        }
    }

    /// いま何番の差分を見ているかを、映像に軽く重ねて出す。
    private var activeBadge: some View {
        HStack(spacing: 8) {
            Text("\(viewModel.activeIndex + 1) / \(viewModel.variantCount)")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
            Text(activeTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            if viewModel.isAutoSwitching, viewModel.variantCount > 1 {
                Text(String(format: "次まで %.1fs", max(0, viewModel.secondsUntilSwitch)))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.55)))
        .padding(.top, 14)
        .allowsHitTesting(false)
    }

    private var activeTitle: String {
        viewModel.variants.indices.contains(viewModel.activeIndex)
            ? viewModel.variants[viewModel.activeIndex].title
            : ""
    }

    // MARK: - 操作パネル

    private var controlPanel: some View {
        VStack(spacing: 10) {
            variantChips
            HStack(spacing: 12) {
                transportControls
                Divider().frame(height: 22)
                intervalControls
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    /// 番号を押せば即その差分へ。数字キー 1〜9 と同じ並び。
    private var variantChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.variants.enumerated()), id: \.element.id) { index, variant in
                    Button {
                        viewModel.showVariant(at: index)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .bold).monospacedDigit())
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(.white.opacity(0.18)))
                            Text(variant.title)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(index == viewModel.activeIndex
                                ? Color.accentColor.opacity(0.85)
                                : Color.primary.opacity(0.08))
                        )
                        .foregroundStyle(index == viewModel.activeIndex ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(variant.title)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 10) {
            Button(action: viewModel.togglePlayPause) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(viewModel.isPlaying ? "一時停止（Space）" : "再生（Space）")
            .accessibilityLabel(viewModel.isPlaying ? "一時停止" : "再生")

            Button(action: viewModel.showPreviousVariant) {
                Image(systemName: "chevron.left.square")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.variantCount < 2)
            .help("前の差分へ（\(keyLabel(.variantPrevious))）")
            .accessibilityLabel("前の差分へ")

            Button(action: viewModel.showRandomVariant) {
                Image(systemName: "shuffle")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.variantCount < 2)
            .help("ランダムな差分へ（\(keyLabel(.variantRandom))）")
            .accessibilityLabel("ランダムな差分へ")

            Button(action: viewModel.showNextVariant) {
                Image(systemName: "chevron.right.square")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.variantCount < 2)
            .help("次の差分へ（\(keyLabel(.variantNext))）")
            .accessibilityLabel("次の差分へ")

            Text(formatTime(viewModel.commonCurrentTime))
                .font(.caption.monospacedDigit())
            Slider(value: $viewModel.commonCurrentTime, in: 0...max(viewModel.commonDuration, 0.1)) { isEditing in
                viewModel.sliderEditingChanged(isEditing: isEditing)
            }
            .frame(minWidth: 160)
            Text(formatTime(viewModel.commonDuration))
                .font(.caption.monospacedDigit())
        }
    }

    private var intervalControls: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $viewModel.isAutoSwitching) {
                Text("自動切り替え").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("一定間隔で差分を自動的に切り替える（\(keyLabel(.variantToggleAuto))）")

            HStack(spacing: 4) {
                Text("間隔").font(.caption).foregroundStyle(.secondary)
                intervalField(value: $viewModel.minInterval, label: "下限の秒数")
                Text("〜").font(.caption).foregroundStyle(.secondary)
                intervalField(value: $viewModel.maxInterval, label: "上限の秒数")
                Text("秒").font(.caption).foregroundStyle(.secondary)
            }
            .opacity(viewModel.isAutoSwitching ? 1 : 0.4)
            .disabled(!viewModel.isAutoSwitching)
            .help("この範囲からランダムに選んだ秒数ごとに切り替えます。上下を同じ値にすれば固定間隔（− / + キーでも変えられます）")

            Toggle(isOn: $viewModel.avoidsImmediateRepeat) {
                Text("同じものを続けない").font(.caption)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .help("切り替えたのに同じ差分が選ばれて「何も変わらない」のを防ぎます")
        }
    }

    private func intervalField(value: Binding<Double>, label: String) -> some View {
        Stepper(
            value: value,
            in: VariantSwitchSettings.allowedRange,
            step: Self.intervalStep
        ) {
            Text(String(format: "%.1f", value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 30, alignment: .trailing)
        }
        .controlSize(.mini)
        .accessibilityLabel(label)
    }

    // MARK: - キーボード

    private var shortcutList: [(key: String, action: String)] {
        _ = shortcutSettingsVersion
        return MediaShortcutSettings.shortcutList(
            for: [
                .videoClose,
                .videoPlayPause,
                .variantNext,
                .variantPrevious,
                .variantRandom,
                .variantToggleAuto,
                .videoSeekBack10,
                .videoSeekBack5,
                .videoSeekForward5,
                .videoSeekForward10
            ],
            extraItems: [
                ("1〜9", "その番号の差分へ直接切り替え"),
                ("− / +", "切り替え間隔を 0.5 秒ずつ縮める／伸ばす"),
                ("T", "下の操作パネルの表示/非表示"),
                ("?", "ショートカット一覧を表示"),
                ("Esc", "プレイヤーを閉じる")
            ]
        )
    }

    private func keyLabel(_ action: MediaShortcutAction) -> String {
        _ = shortcutSettingsVersion
        return MediaShortcutSettings.keys(for: action).map(\.displayName).joined(separator: " / ")
    }

    private func handleKeyPress(press: KeyPress) -> KeyPress.Result {
        if MediaShortcutSettings.matches(.videoClose, press: press) {
            coordinator.close()
            return .handled
        }

        // 数字は差分の直接指定に使う（同時再生と違い、割合シークよりこちらのほうが要る）。
        if let digit = press.key.character.wholeNumberValue, (1...9).contains(digit) {
            viewModel.showVariant(at: digit - 1)
            return .handled
        }

        switch press.key {
        case .escape:
            if showShortcutHelp { showShortcutHelp = false } else { coordinator.close() }
            return .handled
        case "?":
            showShortcutHelp.toggle()
            return .handled
        case "t", "T":
            withAnimation(.easeOut(duration: 0.18)) { isPanelVisible.toggle() }
            return .handled
        case "-", "_":
            shiftInterval(by: -Self.intervalStep)
            return .handled
        case "+", "=":
            shiftInterval(by: Self.intervalStep)
            return .handled
        case .space:
            if press.modifiers.contains(.option) {
                coordinator.close()
                return .handled
            }
        default:
            break
        }

        if MediaShortcutSettings.matches(.variantNext, press: press) {
            viewModel.showNextVariant()
        } else if MediaShortcutSettings.matches(.variantPrevious, press: press) {
            viewModel.showPreviousVariant()
        } else if MediaShortcutSettings.matches(.variantRandom, press: press) {
            viewModel.showRandomVariant()
        } else if MediaShortcutSettings.matches(.variantToggleAuto, press: press) {
            viewModel.isAutoSwitching.toggle()
        } else if MediaShortcutSettings.matches(.videoPlayPause, press: press) {
            viewModel.togglePlayPause()
        } else if MediaShortcutSettings.matches(.videoSeekBack10, press: press) {
            viewModel.seek(by: -10)
        } else if MediaShortcutSettings.matches(.videoSeekBack5, press: press) {
            viewModel.seek(by: -5)
        } else if MediaShortcutSettings.matches(.videoSeekForward5, press: press) {
            viewModel.seek(by: 5)
        } else if MediaShortcutSettings.matches(.videoSeekForward10, press: press) {
            viewModel.seek(by: 10)
        } else {
            return .ignored
        }
        return .handled
    }

    /// 下限と上限を同じ幅だけ動かして、ばらつきの幅は保ったまま速さだけ変える。
    private func shiftInterval(by delta: Double) {
        let span = viewModel.maxInterval - viewModel.minInterval
        let newMin = VariantSwitchSettings.clamp(viewModel.minInterval + delta)
        viewModel.minInterval = newMin
        viewModel.maxInterval = VariantSwitchSettings.clamp(newMin + span)
    }

    private func formatTime(_ time: Double) -> String {
        let seconds = Int(time)
        guard seconds >= 0 else { return "0:00" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
