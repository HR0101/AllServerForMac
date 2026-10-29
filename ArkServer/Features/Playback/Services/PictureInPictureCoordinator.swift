import AVFoundation
import AVKit
import Combine
import Foundation

/// ピクチャインピクチャ（他アプリの上に浮かぶ小窓）の開始・終了。
///
/// アプリ内で小さくたたむミニプレイヤー（I キー）とは別物で、
/// こちらはウィンドウの外・他アプリの前面に出る macOS 標準の小窓。
@MainActor
final class PictureInPictureCoordinator: NSObject, ObservableObject {

    /// いま PiP を開始できるか。対応していない Mac や、映像が準備できていない間は false。
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false

    private var controller: AVPictureInPictureController?
    private var attachedLayer: AVPlayerLayer?
    private var possibleObservation: NSKeyValueObservation?

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// 映像レイヤーが出来たら繋ぐ。同じレイヤーで二度呼ばれても作り直さない。
    func attach(playerLayer: AVPlayerLayer) {
        guard Self.isSupported else { return }
        guard attachedLayer !== playerLayer else { return }

        possibleObservation = nil
        attachedLayer = playerLayer
        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        controller?.delegate = self
        self.controller = controller

        // 「開始できるか」は映像が実際に流れ始めてから真になるので、KVO で追う。
        possibleObservation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] observed, _ in
            let possible = observed.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                self?.isPossible = possible
            }
        }
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    /// プレイヤーを閉じるときに呼ぶ。小窓だけ残ると、止める手段のない再生が居座る。
    func detach() {
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        possibleObservation = nil
        controller?.delegate = nil
        controller = nil
        attachedLayer = nil
        isPossible = false
        isActive = false
    }
}

extension PictureInPictureCoordinator: AVPictureInPictureControllerDelegate {

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.isActive = false }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak self] in self?.isActive = false }
        print("⚠️ [PIP] 開始に失敗しました: \(error.localizedDescription)")
    }
}
