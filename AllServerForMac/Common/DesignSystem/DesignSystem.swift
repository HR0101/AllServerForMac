import AppKit
import SwiftUI

// MARK: - デザイントークン

enum DS {
    static let cardCornerRadius: CGFloat = 16
    static let cardPadding: CGFloat = 20
    static let cardSpacing: CGFloat = 20
    static let cyan = Color(red: 0.18, green: 0.86, blue: 1.0)
    static let violet = Color(red: 0.52, green: 0.42, blue: 1.0)
    static let lime = Color(red: 0.42, green: 1.0, blue: 0.63)
    static let signalRed = Color(red: 1.0, green: 0.19, blue: 0.18)
    static let signalAmber = Color(red: 1.0, green: 0.65, blue: 0.16)
    static let tallyGreen = Color(red: 0.49, green: 0.9, blue: 0.13)
    static let surface = Color.black
    static let surfaceRaised = Color(white: 0.028)
}

/// ガラス風テーマの色です．既存の外観設定キーを引き継ぎます．
/// 静的な色参照とAppKitのウィンドウ外観を同じ設定に揃えます．
enum NeomorphicTheme {
    static let darkBaseDefaultsKey = "appearance.neomorphicDarkBase"

    static var isDarkBase: Bool {
        UserDefaults.standard.bool(forKey: darkBaseDefaultsKey)
    }

    static let glassBlurOpacity: CGFloat = 0.80
    static let lightGlassTintOpacity = 0.07
    static let darkGlassTintOpacity = 0.52

    static var background: Color {
        isDarkBase ? Color(red: 0.08, green: 0.085, blue: 0.09) : Color(red: 0.89, green: 0.92, blue: 0.93)
    }
    static var surface: Color {
        isDarkBase ? Color.white.opacity(0.08) : Color.white.opacity(0.45)
    }
    static var ink: Color {
        isDarkBase ? Color(red: 0.90, green: 0.92, blue: 0.93) : Color(red: 0.16, green: 0.18, blue: 0.19)
    }
    static var muted: Color {
        isDarkBase ? Color(red: 0.73, green: 0.77, blue: 0.82) : Color(red: 0.30, green: 0.35, blue: 0.42)
    }
    static var accent: Color {
        isDarkBase ? Color(red: 0.38, green: 0.66, blue: 1.0) : Color(red: 0.0, green: 0.38, blue: 0.88)
    }
    static var separator: Color {
      ink.opacity(isDarkBase ? 0.16 : 0.09)
    }
    static var selection: Color {
      accent.opacity(isDarkBase ? 0.25 : 0.12)
    }
    static var hover: Color {
      accent.opacity(0.06)
    }
    static var shadow: Color {
        isDarkBase ? Color(red: 0.0, green: 0.0, blue: 0.0) : Color(red: 0.62, green: 0.67, blue: 0.69)
    }
}

// MARK: - コマンドデッキ背景

/// ホームとライブラリに共通で使う背景です。
/// 背景を常時動かすと内容より演出が目立つため，ここは静的に保ちます。
/// 動きはカードへのホバーやサーバーの稼働状態など，意味のある箇所だけで見せます。
struct CommandDeckBackground: View {
  var body: some View {
    LinearGradient(
      colors: [NeomorphicTheme.accent.opacity(0.06), .clear],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }
}

/// デスクトップの色を取り込むmacOS標準のぼかしです．
/// OSの「透明度を下げる」にも標準マテリアルが追従します．
struct GlassWindowBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.blendingMode = .behindWindow
    view.material = .sidebar
    view.alphaValue = NeomorphicTheme.glassBlurOpacity
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    nsView.appearance = NSAppearance(named: NeomorphicTheme.isDarkBase ? .darkAqua : .aqua)
  }
}

/// ホーム・管理画面で共通の，控えめなガラス面です．
struct GlassCardSurface: View {
  var isHovering = false

  var body: some View {
    RoundedRectangle(cornerRadius: DS.cardCornerRadius, style: .continuous)
      .fill(.thinMaterial)
      .overlay {
        RoundedRectangle(cornerRadius: DS.cardCornerRadius, style: .continuous)
          .strokeBorder(NeomorphicTheme.separator, lineWidth: 1)
      }
      .shadow(color: .black.opacity(isHovering ? 0.07 : 0.035), radius: 12, x: 0, y: 4)
  }
}

/// どの一覧でも同じ位置と文字組みで，現在地と件数を示します．
struct LibraryPageHeader: View {
  let title: String
  let subtitle: String
  var count: Int? = nil

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Text(title)
          .font(.system(size: 26, weight: .bold))
          .foregroundStyle(NeomorphicTheme.ink)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(title)
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(NeomorphicTheme.muted)
          .lineLimit(2)
      }
      Spacer(minLength: 8)
      if let count {
        Text("\(count.formatted())件")
          .font(.callout.weight(.medium).monospacedDigit())
          .foregroundStyle(NeomorphicTheme.muted)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - カード

struct CardBackground: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(DS.cardPadding)
            .background(GlassCardSurface(isHovering: isHovering))
            .animation(.easeOut(duration: 0.18), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    func dashboardCard() -> some View {
        modifier(CardBackground())
    }
}

// MARK: - カードヘッダー（システム設定風のアイコンタイル付き）

struct CardHeader: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            IconTile(icon: icon, tint: NeomorphicTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NeomorphicTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(NeomorphicTheme.muted)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct IconTile: View {
    let icon: String
    let tint: Color
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(tint.opacity(0.10))
            .frame(width: size, height: size)
            .overlay(
                safeSystemImage(named: icon)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(tint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.opacity(0.12), lineWidth: 1)
            )
    }

    private func safeSystemImage(named name: String) -> Image {
        if let nsImage = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            return Image(nsImage: nsImage)
        }
        if let nsImage = NSImage(named: NSImage.Name(name)) {
            return Image(nsImage: nsImage)
        }
        return Image(nsImage: NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil) ?? NSImage())
    }
}

// MARK: - ステータスインジケーター（稼働中はパルスする）

struct StatusDot: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .fill(Color.green.opacity(0.35))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1.6 : 0.8)
                    .opacity(pulse ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 9, height: 9)
                .shadow(color: active ? .green.opacity(0.6) : .clear, radius: 3)
        }
        .frame(width: 18, height: 18)
        .onAppear { pulse = active }
        .onChange(of: active) { _, newValue in pulse = newValue }
    }
}

// MARK: - 設定行（ラベル + コントロール）

struct SettingRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
            Spacer()
            content
        }
    }
}

// MARK: - コピー可能なテキスト（クリックでコピー、フィードバック付き）

struct CopyableText: View {
    let text: String
    var font: Font = .system(.body, design: .monospaced)
    var tint: Color = .accentColor
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                Text(text)
                    .font(font)
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .help("クリックでコピー")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copied = false }
        }
    }
}

// MARK: - 大きな主要アクションボタン（開始/停止用）

struct ProminentActionButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: isEnabled
                                ? [tint, tint.opacity(0.75)]
                                : [Color.gray.opacity(0.45), Color.gray.opacity(0.35)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .shadow(color: isEnabled ? tint.opacity(0.55) : .clear, radius: 10, x: 0, y: 3)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - 統計表示（アイコン + 値 + ラベル）

struct StatPill: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(DS.cyan.opacity(0.1))
        )
    }
}
