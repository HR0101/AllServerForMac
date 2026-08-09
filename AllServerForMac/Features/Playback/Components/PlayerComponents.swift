import AVKit
import SwiftUI

// MARK: - AVKit-safe player surface
//
// SwiftUI の VideoPlayer は _AVKit_SwiftUI のみ参照され AVKit 本体がリンクされず
// 実行時クラッシュするため、各プレイヤーモードはこの AVPlayerView ラッパーを共有して使う。
struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer?
    // .inline は再生コントロール（シークバー）を画面最下部に沿って表示する。
    // .floating だと中央寄りに浮いて動画に被るため inline を既定にしている。
    var controlsStyle: AVPlayerViewControlsStyle = .inline
    var showsFullScreenToggleButton: Bool = true
    var allowsPictureInPicturePlayback: Bool = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = controlsStyle
        view.showsFullScreenToggleButton = showsFullScreenToggleButton
        view.allowsPictureInPicturePlayback = allowsPictureInPicturePlayback
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

// MARK: - プレイヤー共通UI（閉じる・ショートカットヘルプ）

/// プレイヤー画面の隅に重ねる「ヘルプ」「閉じる」ボタンの組。
/// 全プレイヤーで見た目と操作感を揃える。
struct PlayerCornerControls: View {
    @Binding var showShortcutHelp: Bool
    /// 音量つまみを出す場合に渡す。nil のときは音量 UI を出さない
    /// （同時再生のように音を別の仕組みで扱うプレイヤー向け）。
    var volume: Binding<Float>? = nil
    var isMuted: Binding<Bool>? = nil
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let volume, let isMuted {
                volumeControl(volume: volume, isMuted: isMuted)
            }

            Button {
                showShortcutHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("キーボードショートカット一覧（?キー）")
            .accessibilityLabel("キーボードショートカット一覧")

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("閉じる（Esc）")
            .accessibilityLabel("プレイヤーを閉じる")
        }
        .padding()
    }

    /// スピーカーボタン（クリックでミュート切替）と音量スライダー。
    /// 全画面再生中はメニューバーもウィンドウのツールバーも出ないため、
    /// 音量を変えられる場所がここしかない。
    private func volumeControl(volume: Binding<Float>, isMuted: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Button {
                isMuted.wrappedValue.toggle()
            } label: {
                Image(systemName: Self.speakerSymbol(volume: volume.wrappedValue, isMuted: isMuted.wrappedValue))
                    .font(.system(size: 15, weight: .semibold))
                    // 記号ごとに幅が違うのでスライダーが左右に揺れないよう固定幅にする。
                    .frame(width: 20, alignment: .center)
                    .foregroundStyle(.white.opacity(0.85))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isMuted.wrappedValue ? "ミュート解除" : "ミュート")
            .accessibilityLabel(isMuted.wrappedValue ? "ミュート解除" : "ミュート")

            Slider(value: volume, in: 0...1)
                .controlSize(.small)
                .frame(width: 96)
                .tint(.white.opacity(0.85))
                .disabled(isMuted.wrappedValue)
                .opacity(isMuted.wrappedValue ? 0.35 : 1)
                .help("音量")
                .accessibilityLabel("音量")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }

    private static func speakerSymbol(volume: Float, isMuted: Bool) -> String {
        if isMuted || volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.fill" }
        if volume < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }
}

/// キーボードショートカットの一覧パネル。?キーまたはヘルプボタンで表示し、
/// クリックか Esc / ? で閉じる。
struct ShortcutHelpPanel: View {
    let title: String
    let shortcuts: [(key: String, action: String)]
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(title, systemImage: "keyboard")
                        .font(.headline)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("ヘルプを閉じる")
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, item in
                        GridRow {
                            Text(item.key)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .gridColumnAlignment(.trailing)
                            Text(item.action)
                                .font(.body)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 24)
        }
        .transition(.opacity)
    }
}
