import AppKit
import SwiftUI

/// macOS標準のタイトルバーをコンテンツと同じ背景に重ねるためのViewです．
struct WindowChromeConfigurator: NSViewRepresentable {
  let isToolbarHidden: Bool

  func makeNSView(context: Context) -> WindowChromeView {
    let view = WindowChromeView()
    view.isToolbarHidden = isToolbarHidden
    return view
  }

  func updateNSView(_ nsView: WindowChromeView, context: Context) {
    nsView.isToolbarHidden = isToolbarHidden
    nsView.applyWindowChrome()
  }
}

final class WindowChromeView: NSView {
  var isToolbarHidden = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyWindowChrome()
  }

  func applyWindowChrome() {
    guard let window else { return }
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.titlebarSeparatorStyle = .none
    window.appearance = NSAppearance(
      named: NeomorphicTheme.isDarkBase ? .darkAqua : .aqua
    )
    window.backgroundColor = NeomorphicTheme.isDarkBase
      ? NSColor(red: 0.08, green: 0.085, blue: 0.09, alpha: 1.0)
      : NSColor(red: 0.89, green: 0.92, blue: 0.93, alpha: 1.0)
    window.toolbarStyle = .unifiedCompact
    window.toolbar?.isVisible = !isToolbarHidden
  }
}
