import AppKit
import Charts
import SwiftUI

// MARK: - Neomorphism Theme

struct NeomorphicHomeBackground: View {
    var body: some View {
        CommandDeckBackground()
    }
}

struct NeomorphicTile<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            // カードと同じく、与えられた高さいっぱいに広がる（横並びの列の下端がそろう）。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(NeomorphicTheme.surface)
                    .shadow(color: .white.opacity(0.92), radius: 8, x: -7, y: -7)
                    .shadow(color: NeomorphicTheme.shadow.opacity(0.32), radius: 16, x: 9, y: 9)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.65), lineWidth: 1)
            )
    }
}
