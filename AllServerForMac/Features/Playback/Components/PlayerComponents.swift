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

// MARK: - プレイヤー共通の見た目

/// 動画の上に重ねる操作部品の配色。アプリ本体と同じ「無彩色・平ら・影なし」にそろえる。
/// 動画の明暗や、アプリの明るい/暗い外観に左右されないよう、常に暗い面に白い文字で組む。
/// アクセントの青は使わず、「いま入っている」状態は面を一段明るくして示す。
enum PlayerChrome {
    /// 操作部品の面。動画が透けて見える程度の暗い半透明（ぼかしは使わず、平らに塗る）。
    static let panel = Color.black.opacity(0.74)
    static let panelBorder = Color.white.opacity(0.09)
    /// 「入っている」状態・押している間の面。
    static let chip = Color.white.opacity(0.18)
    static let hover = Color.white.opacity(0.09)
    static let icon = Color.white.opacity(0.88)
    static let iconMuted = Color.white.opacity(0.58)
    static let radius: CGFloat = 12
}

extension View {
    /// 暗い平らな面（細い縁線つき）。操作バーやパネルの下地。
    func playerPanel(cornerRadius: CGFloat = PlayerChrome.radius) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(PlayerChrome.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(PlayerChrome.panelBorder, lineWidth: 0.5)
        )
    }
}

/// 操作バーの中に並べる、線の細いアイコンボタン。
/// 「入っている」状態（シャッフル・リピート・お気に入りなど）は、色ではなく面の明るさで示す。
struct PlayerIconButton: View {
    let systemImage: String
    var isActive = false
    let help: String
    var accessibilityLabel: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isActive ? Color.white : PlayerChrome.icon)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? PlayerChrome.chip : (isHovering ? PlayerChrome.hover : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(accessibilityLabel ?? help)
    }
}

/// 再生/一時停止だけは主役のボタンとして、白い丸に黒いアイコンで目立たせる（色は付けない）。
struct PlayerPlayButton: View {
    let isPlaying: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.88))
                // 再生の三角は重心が左に寄って見えるので、わずかに右へ寄せて丸の中央に見せる。
                .offset(x: isPlaying ? 0 : 1)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.94)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(isPlaying ? "一時停止" : "再生")
    }
}

/// 画面隅に置く丸いボタン（ヘルプ・閉じる）。
struct PlayerRoundButton: View {
    let systemImage: String
    let help: String
    var accessibilityLabel: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PlayerChrome.icon)
                .frame(width: 32, height: 32)
                .background(Circle().fill(PlayerChrome.panel))
                .overlay(Circle().fill(isHovering ? PlayerChrome.hover : Color.clear))
                .overlay(Circle().strokeBorder(PlayerChrome.panelBorder, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(accessibilityLabel ?? help)
    }
}

// MARK: - プレイヤー共通UI（閉じる・ショートカットヘルプ）

/// プレイヤー画面の隅に重ねる「音量」「ヘルプ」「閉じる」の組。
/// 全プレイヤーで見た目と操作感を揃える。
struct PlayerCornerControls: View {
    @Binding var showShortcutHelp: Bool
    /// 音量つまみを出す場合に渡す。nil のときは音量 UI を出さない
    /// （同時再生のように音を別の仕組みで扱うプレイヤー向け）。
    var volume: Binding<Float>? = nil
    var isMuted: Binding<Bool>? = nil
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let volume, let isMuted {
                volumeControl(volume: volume, isMuted: isMuted)
            }

            PlayerRoundButton(
                systemImage: "questionmark",
                help: "キーボードショートカット一覧（?キー）",
                accessibilityLabel: "キーボードショートカット一覧"
            ) {
                showShortcutHelp.toggle()
            }

            PlayerRoundButton(
                systemImage: "xmark",
                help: "閉じる（Esc）",
                accessibilityLabel: "プレイヤーを閉じる",
                action: onClose
            )
        }
        .padding()
        .padding(.top, Self.titlebarClearance)
    }

    /// プレイヤーはタイトルバーの下まで広げて描くが，透明なタイトルバーはその帯のクリックを横取りする。
    /// ボタンを上端に置くと上半分が押せず「× を押しても閉じない」ので，その帯の下まで下げる。
    static let titlebarClearance: CGFloat = 24

    /// スピーカーボタン（クリックでミュート切替）と音量スライダー。
    /// 全画面再生中はメニューバーもウィンドウのツールバーも出ないため、
    /// 音量を変えられる場所がここしかない。
    private func volumeControl(volume: Binding<Float>, isMuted: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Button {
                isMuted.wrappedValue.toggle()
            } label: {
                Image(systemName: Self.speakerSymbol(volume: volume.wrappedValue, isMuted: isMuted.wrappedValue))
                    .font(.system(size: 14, weight: .regular))
                    // 記号ごとに幅が違うのでスライダーが左右に揺れないよう固定幅にする。
                    .frame(width: 20, alignment: .center)
                    .foregroundStyle(PlayerChrome.icon)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isMuted.wrappedValue ? "ミュート解除" : "ミュート")
            .accessibilityLabel(isMuted.wrappedValue ? "ミュート解除" : "ミュート")

            // ミュート中も動かせるようにし，動かしたらミュートを解除する（無効化して薄くすると壊れて見える）。
            Slider(
                value: Binding(
                    get: { volume.wrappedValue },
                    set: { newValue in
                        volume.wrappedValue = newValue
                        if isMuted.wrappedValue { isMuted.wrappedValue = false }
                    }
                ),
                in: 0...1
            )
                .controlSize(.small)
                .frame(width: 96)
                .tint(.white.opacity(0.9))
                .opacity(isMuted.wrappedValue ? 0.5 : 1)
                .help("音量")
                .accessibilityLabel("音量")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .playerPanel(cornerRadius: 16)
        // 動画の上に重ねる暗い面なので，スライダーのトラックも暗い背景向けの色で描かせる。
        .environment(\.colorScheme, .dark)
    }

    private static func speakerSymbol(volume: Float, isMuted: Bool) -> String {
        if isMuted || volume <= 0.001 { return "speaker.slash" }
        if volume < 0.34 { return "speaker" }
        if volume < 0.67 { return "speaker.wave.1" }
        return "speaker.wave.2"
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
            Color.black.opacity(0.5)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(title, systemImage: "keyboard")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    PlayerRoundButton(systemImage: "xmark", help: "ヘルプを閉じる", action: onDismiss)
                }

                Rectangle().fill(PlayerChrome.panelBorder).frame(height: 0.5)

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, item in
                        GridRow {
                            Text(item.key)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(PlayerChrome.hover)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .gridColumnAlignment(.trailing)
                            Text(item.action)
                                .font(.appBody)
                                .foregroundStyle(PlayerChrome.icon)
                        }
                    }
                }
            }
            .foregroundStyle(PlayerChrome.icon)
            .padding(24)
            .frame(maxWidth: 420)
            // 暗い平らな面。ぼかしや影は付けない（アプリ本体のカードと同じ質感にそろえる）。
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.13)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PlayerChrome.panelBorder, lineWidth: 0.5))
            .environment(\.colorScheme, .dark)
        }
        .transition(.opacity)
    }
}
