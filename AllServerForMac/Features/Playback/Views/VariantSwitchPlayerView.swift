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
    @ObservedObject private var dataManager: LibraryViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    /// 閉じ方。ウィンドウ全体を占有しているときは省略してコーディネータに任せ、
    /// 「差分動画を探す」の上に重ねているときは、その重なりだけを外すために渡してもらう。
    private let onClose: (() -> Void)?
    @FocusState private var isFocused: Bool
    @State private var showShortcutHelp = false
    @State private var showDeleteConfirmation = false
    /// 操作系の出し入れ（他のプレイヤーと共通）。
    @StateObject private var chrome = PlayerChromeController()
    @AppStorage(MediaShortcutSettings.versionKey) private var shortcutSettingsVersion = 0

    private static let activeTitleWidth: CGFloat = 280

    /// 差分を直接選ぶキー。数字はシークバーの割合ジャンプ（他のプレイヤーと同じ）に使うので、
    /// キーボード上段を左から順に 1本目〜9本目へ割り当てる（本数の上限も 9 本）。
    private static let directSelectKeys = ["q", "w", "e", "r", "t", "y", "u", "i", "o"]

    private static func directSelectKey(for index: Int) -> String? {
        directSelectKeys.indices.contains(index) ? directSelectKeys[index].uppercased() : nil
    }

    init(
        videos: [VideoItem],
        dataManager: LibraryViewModel,
        onClose: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: VariantSwitchPlayerViewModel(videos: videos, dataManager: dataManager))
        _dataManager = ObservedObject(wrappedValue: dataManager)
        self.onClose = onClose
    }

    private func close() {
        if let onClose { onClose() } else { coordinator.close() }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 操作系は映像の上に重ねる。映像の下に積むと、出入りのたびに映像が伸び縮みしてしまう。
            stack
                .overlay(alignment: .topLeading) {
                    if viewModel.variantCount > 0 {
                        activeBadge
                    }
                }
                .overlay(alignment: .bottom) {
                    if chrome.isShown {
                        controlPanel
                            .playerChromeHoverGuard(chrome)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

            if chrome.isShown {
                PlayerCornerControls(
                    showShortcutHelp: $showShortcutHelp,
                    volume: $viewModel.volume,
                    isMuted: $viewModel.isMuted
                ) {
                    close()
                }
                .playerChromeHoverGuard(chrome)
                .transition(.opacity)
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
        .playerChromeActivity(chrome)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down, action: handleKeyPress)
        .onAppear {
            viewModel.start()
            isFocused = true
            chrome.reveal()
        }
        // パネルのボタンやスライダーを押すとフォーカスがそちらへ移り、以降 .onKeyPress が
        // 効かなくなる。引っ込んだ時点でポインタは離れているので、そこで本体へ戻す。
        // 出るたびに戻すと、スライダーをドラッグしている最中に奪ってしまう。
        .onChange(of: chrome.isShown) { _, shown in
            if !shown { isFocused = true }
        }
        .onChange(of: showShortcutHelp) { _, shown in
            chrome.setHold(.overlayVisible, shown || viewModel.isDeleteMode)
        }
        // 削除モードの間は、選んだ結果が見えないと話にならないので出したままにする。
        .onChange(of: viewModel.isDeleteMode) { _, active in
            chrome.setHold(.overlayVisible, active || showShortcutHelp)
        }
        .sheet(isPresented: $showDeleteConfirmation) {
            MediaDeletionConfirmationSheet(
                items: viewModel.markedItems,
                dataManager: dataManager,
                onMoveToAppTrash: {
                    applyDeletion { dataManager.moveToTrash(videoIDs: $0) }
                },
                onDeleteCompletely: {
                    applyDeletion { dataManager.deleteVideos(videoIDs: $0) }
                },
                onMoveToSystemTrash: {
                    applyDeletion {
                        dataManager.moveMediaFilesToSystemTrash(videoIDs: $0)
                    }
                }
            )
        }
        .onDisappear {
            chrome.cancel()
            viewModel.cleanup()
        }
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // AVPlayerView 自体には用がない（コントロールは出しておらず、操作はパネルとキーボード）。
            // クリックを AVKit 側へ吸わせないためだけに切る。
            // なお `.onContinuousHover` はこれが無くても届く。AppKit のトラッキング領域は
            // 重なり順で遮られず、mouseMoved は NSHostingView にも配られるため。
            .allowsHitTesting(false)
        }
    }

    /// 操作系が隠れていても，いま見ている差分だけは固定位置で判別できるようにする。
    /// 幅を固定し，タイトル長によってバッジ全体が高速で伸び縮みしないようにする。
    private var activeBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.72))
            Text("\(viewModel.activeIndex + 1) / \(viewModel.variantCount)")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
            Text(activeTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.activeTitleWidth, alignment: .leading)
            if viewModel.isAutoSwitching,
               viewModel.variantCount > 1,
               viewModel.minInterval > VariantSwitchSettings.fineIntervalThreshold {
                Text(String(format: "次まで %.1fs", max(0, viewModel.secondsUntilSwitch)))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.42)))
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.top, 14)
        .padding(.leading, 14)
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
            if viewModel.isDeleteMode { deleteBar }
            variantChips
            HStack(spacing: 12) {
                transportControls
                Divider().frame(height: 22)
                intervalControls
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
        .padding(16)
        .frame(maxWidth: 1200)
    }

    /// 押せば即その差分へ。丸の中は番号ではなく、その差分に割り当たっているキーを出す
    /// （番号を出すと数字キーで飛べると読めてしまうが、数字は割合シークに使っている）。
    private var variantChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.variants.enumerated()), id: \.element.id) { index, variant in
                    variantChip(index: index, variant: variant)
                }
            }
            .padding(.vertical, 1)
        }
    }

    @ViewBuilder
    private func variantChip(index: Int, variant: VariantSwitchPlayerViewModel.Variant) -> some View {
        let isActive = index == viewModel.activeIndex
        let isMarked = viewModel.markedForDeletionIDs.contains(variant.id)
        HStack(spacing: 6) {
            // 削除モードでも、本体を押せば従来どおり切り替わる。
            // 見比べないと消していいか判断できないので、印付けと切り替えは別の当たり判定にする。
            if viewModel.isDeleteMode {
                Button {
                    viewModel.toggleMark(at: index)
                } label: {
                    Image(systemName: isMarked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isMarked ? Color.red : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(isMarked ? "削除対象から外す" : "削除対象にする")
            }
            Button {
                viewModel.showVariant(at: index)
            } label: {
                HStack(spacing: 6) {
                    Text(Self.directSelectKey(for: index) ?? "\(index + 1)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(0.18)))
                    Text(variant.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(isMarked ? Color.white : Color.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(isMarked ? Color.red.opacity(0.75)
                           : Color.primary.opacity(0.08))
        )
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(isActive ? Color.accentColor.opacity(0.78) : Color.clear)
                .frame(height: 3)
                .padding(.horizontal, 10)
                .offset(y: 3)
        }
        .help(Self.directSelectKey(for: index).map { "\(variant.title)（\($0)）" } ?? variant.title)
    }

    /// 削除モードの帯。何本選んでいるかと、その場での実行・取りやめ。
    private var deleteBar: some View {
        HStack(spacing: 10) {
            Label("削除モード", systemImage: "trash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            Text("消したい差分に印を付けてください（表示中のものは \(keyLabel(.variantMarkForDeletion))）")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(viewModel.markedForDeletionIDs.count)本を選択中")
                .font(.caption.monospacedDigit())
            Button("やめる") { viewModel.isDeleteMode = false }
                .font(.caption)
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("削除", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.markedForDeletionIDs.isEmpty)
        }
        .padding(.horizontal, 4)
    }

    /// 削除を実行する。見比べる相手がいなくなったらプレイヤーを閉じて一覧へ戻す。
    ///
    /// 先に再生から外してから消す。開いたままのファイルを消しても macOS では問題ないが、
    /// 消してから外すまでの間だけ「もう無いファイルを再生し続けている」状態になる。
    private func applyDeletion(_ delete: ([UUID]) -> Void) {
        let ids = viewModel.markedForDeletionIDs
        guard !ids.isEmpty else { return }
        viewModel.removeVariants(ids: ids)
        delete(Array(ids))
        viewModel.isDeleteMode = false
        if viewModel.variantCount < 2 { close() }
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

            Button {
                viewModel.isDeleteMode.toggle()
            } label: {
                Image(systemName: viewModel.isDeleteMode ? "trash.fill" : "trash")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.isDeleteMode ? Color.red : Color.primary)
            .help("見比べて要らないと分かったものを選んで消す（\(keyLabel(.variantToggleDeleteMode))）")
            .accessibilityLabel("削除モード")

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
                intervalField(
                    value: viewModel.minInterval,
                    label: "下限の秒数",
                    set: viewModel.setMinInterval
                )
                Text("〜").font(.caption).foregroundStyle(.secondary)
                intervalField(
                    value: viewModel.maxInterval,
                    label: "上限の秒数",
                    set: viewModel.setMaxInterval
                )
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

    /// 上下限は互いを押し合うので、`Binding` を直に持たせず必ずビューモデルの設定メソッドを通す。
    private func intervalField(
        value: Double,
        label: String,
        set: @escaping (Double) -> Void
    ) -> some View {
        Stepper(
            onIncrement: {
                set(
                    VariantSwitchSettings.adjustedInterval(
                        value,
                        increasing: true
                    )
                )
            },
            onDecrement: {
                set(
                    VariantSwitchSettings.adjustedInterval(
                        value,
                        increasing: false
                    )
                )
            }
        ) {
            Text(String(format: "%.1f", value))
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
                .variantToggleDeleteMode,
                .variantMarkForDeletion,
                .videoSeekBack10,
                .videoSeekBack5,
                .videoSeekForward5,
                .videoSeekForward10
            ],
            extraItems: [
                ("Q W E R T Y U I O", "1本目〜9本目の差分へ直接切り替え（操作パネルは出しません）"),
                ("0〜9", "0%〜90% の位置へジャンプ"),
                ("− / +", "切り替え間隔を調整（0.5秒以下は0.1秒刻み）"),
                ("P", "操作パネルを出しっぱなしにする／自動で隠す"),
                ("マウスを動かす", "隠れている操作パネルを出す（2.5秒後に自動で隠れます）"),
                ("差分の切り替え", "映像に被らないよう、操作パネルは出しません"),
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
        // 差分の切り替え，キーボードによるスキップ，再生・一時停止では操作系を出さない。
        // 見比べながら何度も押す操作なので，そのたびに映像へ被らないようにする。
        var revealsChrome = true
        defer { if revealsChrome { chrome.reveal() } }

        if MediaShortcutSettings.matches(.videoClose, press: press) {
            close()
            return .handled
        }

        switch press.key {
        case .escape:
            if showShortcutHelp { showShortcutHelp = false } else { close() }
            return .handled
        case "?":
            showShortcutHelp.toggle()
            return .handled
        case .space:
            if press.modifiers.contains(.option) {
                close()
                return .handled
            }
        default:
            break
        }

        // 数字は他のプレイヤーと揃えて割合ジャンプ。差分の直接指定は上段キーへ逃がしてある。
        if let digit = press.key.character.wholeNumberValue, (0...9).contains(digit) {
            revealsChrome = false
            viewModel.seek(toPercentage: Double(digit) / 10.0)
            return .handled
        }

        // 設定で変えられるキーを先に見る。上段キーへ何かを割り当て直した人が、
        // 固定割り当ての差分選択に食われないようにするため。
        if MediaShortcutSettings.matches(.variantNext, press: press) {
            revealsChrome = false
            viewModel.showNextVariant()
        } else if MediaShortcutSettings.matches(.variantPrevious, press: press) {
            revealsChrome = false
            viewModel.showPreviousVariant()
        } else if MediaShortcutSettings.matches(.variantRandom, press: press) {
            revealsChrome = false
            viewModel.showRandomVariant()
        } else if MediaShortcutSettings.matches(.variantToggleAuto, press: press) {
            viewModel.isAutoSwitching.toggle()
        } else if MediaShortcutSettings.matches(.variantToggleDeleteMode, press: press) {
            viewModel.isDeleteMode.toggle()
        } else if MediaShortcutSettings.matches(.variantMarkForDeletion, press: press) {
            // 印を付けるだけなら削除モードに入っていなくても始められるようにする。
            if !viewModel.isDeleteMode { viewModel.isDeleteMode = true }
            viewModel.toggleMarkOnActiveVariant()
        } else if MediaShortcutSettings.matches(.videoPlayPause, press: press) {
            revealsChrome = false
            viewModel.togglePlayPause()
        } else if MediaShortcutSettings.matches(.videoSeekBack10, press: press) {
            revealsChrome = false
            viewModel.seek(by: -10)
        } else if MediaShortcutSettings.matches(.videoSeekBack5, press: press) {
            revealsChrome = false
            viewModel.seek(by: -5)
        } else if MediaShortcutSettings.matches(.videoSeekForward5, press: press) {
            revealsChrome = false
            viewModel.seek(by: 5)
        } else if MediaShortcutSettings.matches(.videoSeekForward10, press: press) {
            revealsChrome = false
            viewModel.seek(by: 10)
        } else if let index = Self.directSelectKeys.firstIndex(of: pressedLetter(press)) {
            revealsChrome = false
            viewModel.showVariant(at: index)
        } else {
            switch press.key {
            case "p", "P":
                chrome.togglePin()
            case "-", "_":
                viewModel.shiftIntervals(increasing: false)
            case "+", "=":
                viewModel.shiftIntervals(increasing: true)
            default:
                // 何にも当たらなかったキーで操作系を出す理由はない。
                revealsChrome = false
                return .ignored
            }
        }
        return .handled
    }

    /// 固定割り当てのキーと突き合わせるための小文字1文字。修飾キー付きは対象外。
    private func pressedLetter(_ press: KeyPress) -> String {
        guard !press.modifiers.contains(.command),
              !press.modifiers.contains(.control),
              !press.modifiers.contains(.option) else { return "" }
        return String(press.key.character).lowercased()
    }

    private func formatTime(_ time: Double) -> String {
        let seconds = Int(time)
        guard seconds >= 0 else { return "0:00" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
