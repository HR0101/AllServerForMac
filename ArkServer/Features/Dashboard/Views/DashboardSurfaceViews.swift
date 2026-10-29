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
            .padding(padding)
            .background(GlassCardSurface())
    }
}
