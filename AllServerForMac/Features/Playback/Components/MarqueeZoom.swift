import SwiftUI

// MARK: - マーキー（範囲ドラッグ）ズーム
//
// 動画再生中・画像閲覧中に、マウスで矩形をドラッグするとその範囲へズームインする仕組み。
// 動画プレイヤーと画像ビューアで共有する。
// 変換は対象ビューに `.scaleEffect(x: state.scaleX, y: state.scaleY, anchor: .topLeading)`
// と `.offset(state.offset)` を適用する前提で座標計算している（コンテナ左上原点＝表示座標）。

/// ズームの状態（縦横共通の拡大率と平行移動）。
/// `scaleEffect` へ渡しやすいように縦横の値を保持するが、常に同じ倍率を設定する。
struct MarqueeZoomState: Equatable {
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var offset: CGSize = .zero

    /// 何倍まで拡大できるかの上限（微小な選択での過剰ズーム防止）。
    private let maxScale: CGFloat = 200

    /// フィット表示（等倍）から拡大されているか。
    var isZoomed: Bool { scaleX > 1.01 || scaleY > 1.01 }

    /// フィット表示へ戻す。
    mutating func reset() {
        scaleX = 1
        scaleY = 1
        offset = .zero
    }

    /// コンテナ表示座標での矩形 `rect` を、縦横比を維持してズームインする。
    /// 選択範囲とコンテナの縦横比が異なる場合は、余白を残して範囲全体を表示する。
    /// 現在のズームに対して相対的に拡大するので、続けて何度でも絞り込める。
    mutating func zoom(into rect: CGRect, containerSize: CGSize) {
        guard rect.width > 8, rect.height > 8,
              containerSize.width > 0, containerSize.height > 0 else { return }
        // 選択範囲全体がコンテナ内に収まる共通倍率を使い、縦横比を維持する。
        let scaleMultiplier = min(
            containerSize.width / rect.width,
            containerSize.height / rect.height
        )
        let newScaleX = min(scaleX * scaleMultiplier, maxScale)
        let newScaleY = min(scaleY * scaleMultiplier, maxScale)
        let rx = newScaleX / scaleX
        let ry = newScaleY / scaleY
        // 選択矩形の中心が、ズーム後にコンテナ中心へ来るように offset を決める。
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let viewCenter = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        offset = CGSize(
            width: viewCenter.x - (center.x - offset.width) * rx,
            height: viewCenter.y - (center.y - offset.height) * ry
        )
        scaleX = newScaleX
        scaleY = newScaleY
    }
}

/// ドラッグ中に描く選択矩形。
struct MarqueeRectangleShape: View {
    let start: CGPoint
    let current: CGPoint

    private var rect: CGRect {
        CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
               width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.18))
            .overlay(
                Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }
}

/// マーキーズーム用のドラッグジェスチャ。ドラッグ中は `start`/`current` を更新して矩形を描かせ、
/// 離した時に選択矩形を `apply` へ渡す。
func marqueeZoomGesture(
    start: Binding<CGPoint?>,
    current: Binding<CGPoint?>,
    containerSize: CGSize,
    apply: @escaping (CGRect) -> Void
) -> some Gesture {
    DragGesture(minimumDistance: 6)
        .onChanged { value in
            if start.wrappedValue == nil { start.wrappedValue = value.startLocation }
            current.wrappedValue = value.location
        }
        .onEnded { value in
            let s = start.wrappedValue ?? value.startLocation
            let e = value.location
            let rect = CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                              width: abs(e.x - s.x), height: abs(e.y - s.y))
            start.wrappedValue = nil
            current.wrappedValue = nil
            apply(rect)
        }
}
