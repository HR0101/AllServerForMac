import AVFoundation
import AppKit
import SwiftUI

/// `AVPlayerLayer` を直に載せるだけの映像面。
///
/// 通常再生は AVKit のコントロールを使わない（`controlsStyle = .none`）ので、
/// `AVPlayerView` は実質レイヤーの入れ物でしかない。そこを自前のレイヤーに置き換えると、
/// ピクチャインピクチャの `AVPictureInPictureController(playerLayer:)` にそのまま渡せる。
/// `AVPlayerView` にはプログラムから PiP を開始する公開 API がなく（あるのは
/// `allowsPictureInPicturePlayback` と delegate だけ）、標準コントロールを出さない限り
/// PiP ボタンも現れないため、この形にしている。
final class PlayerLayerHostView: NSView {

    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // 暗黙アニメーションを切る。切らないとウィンドウのリサイズ中に映像が遅れて追ってくる。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

struct PlayerLayerContainerView: NSViewRepresentable {

    let player: AVPlayer?
    /// レイヤーが出来たときに一度だけ呼ばれる。PiP コントローラーの作成に使う。
    var onLayerReady: ((AVPlayerLayer) -> Void)?

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.player = player
        if let onLayerReady {
            // View 生成の最中に呼ぶと SwiftUI の状態更新と重なるため、次のループへ回す。
            let layer = view.playerLayer
            DispatchQueue.main.async { onLayerReady(layer) }
        }
        return view
    }

    func updateNSView(_ nsView: PlayerLayerHostView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}
