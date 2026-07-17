import AppKit
import SwiftUI

// MARK: - デザイントークン

enum DS {
    static let cardCornerRadius: CGFloat = 8
    static let cardPadding: CGFloat = 18
    static let cardSpacing: CGFloat = 18
    static let cyan = Color(red: 0.18, green: 0.86, blue: 1.0)
    static let violet = Color(red: 0.52, green: 0.42, blue: 1.0)
    static let lime = Color(red: 0.42, green: 1.0, blue: 0.63)
    static let signalRed = Color(red: 1.0, green: 0.19, blue: 0.18)
    static let signalAmber = Color(red: 1.0, green: 0.65, blue: 0.16)
    static let tallyGreen = Color(red: 0.49, green: 0.9, blue: 0.13)
    static let surface = Color.black
    static let surfaceRaised = Color(white: 0.028)
}

enum NeomorphicTheme {
    static let background = Color(red: 0.89, green: 0.92, blue: 0.93)
    static let surface = Color(red: 0.91, green: 0.93, blue: 0.93)
    static let ink = Color(red: 0.16, green: 0.18, blue: 0.19)
    static let muted = Color(red: 0.48, green: 0.52, blue: 0.54)
    static let accent = Color(red: 0.14, green: 0.59, blue: 0.66)
    static let shadow = Color(red: 0.62, green: 0.67, blue: 0.69)
}

struct NeomorphicWavePattern: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let lineCount = 22
        for index in 0..<lineCount {
            let progress = CGFloat(index) / CGFloat(max(lineCount - 1, 1))
            let baseY = rect.minY + rect.height * progress
            path.move(to: CGPoint(x: rect.minX, y: baseY))
            for step in 0...64 {
                let xProgress = CGFloat(step) / 64
                let x = rect.minX + rect.width * xProgress
                let wave = sin((xProgress * 2.2 + progress * 0.7) * .pi * 2)
                let y = baseY + wave * 18
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

// MARK: - コマンドデッキ背景

/// ホームとライブラリに共通で使う背景です。
/// 背景を常時動かすと内容より演出が目立つため，ここは静的に保ちます。
/// 動きはカードへのホバーやサーバーの稼働状態など，意味のある箇所だけで見せます。
struct CommandDeckBackground: View {
    var body: some View {
        ZStack {
            NeomorphicTheme.background

            NeomorphicWavePattern()
                .stroke(Color.white.opacity(0.48), lineWidth: 1)
                .frame(width: 540, height: 260)
                .offset(x: -300, y: -240)

            NeomorphicWavePattern()
                .stroke(Color(red: 0.72, green: 0.79, blue: 0.83).opacity(0.38), lineWidth: 1)
                .frame(width: 700, height: 340)
                .rotationEffect(.degrees(8))
                .offset(x: 330, y: 270)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - カード

struct CardBackground: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(DS.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: DS.cardCornerRadius, style: .continuous)
                    .fill(NeomorphicTheme.surface)
                    .shadow(color: .white.opacity(0.9), radius: isHovering ? 10 : 7, x: -6, y: -6)
                    .shadow(color: NeomorphicTheme.shadow.opacity(isHovering ? 0.36 : 0.28), radius: isHovering ? 16 : 11, x: 8, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.cardCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(isHovering ? 0.76 : 0.58), lineWidth: 1)
            )
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
            IconTile(icon: icon, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(NeomorphicTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
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
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(NeomorphicTheme.surface)
            .frame(width: size, height: size)
            .shadow(color: .white.opacity(0.9), radius: 3, x: -2, y: -2)
            .shadow(color: NeomorphicTheme.shadow.opacity(0.24), radius: 5, x: 3, y: 3)
            .overlay(
                safeSystemImage(named: icon)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(tint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.white.opacity(0.64), lineWidth: 1)
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
            .font(.system(size: 13, weight: .bold, design: .rounded))
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
