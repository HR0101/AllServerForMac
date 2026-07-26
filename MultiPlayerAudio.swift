import AVFoundation
import Foundation
import MediaToolbox

// MARK: - 同時再生の音声処理（音量・ミュート・定位）
//
// AVPlayer には定位（左右のどちらから鳴らすか）を指定する仕組みが無く、
// AVAudioMix で調整できるのも音量だけ。左右へ振り分けるにはサンプルを直接触るしかないので、
// 音声トラックへ MTAudioProcessingTap を挟み、チャンネルごとのゲインを掛ける。

/// 1タイルぶんの音声パラメータ。処理タップ（リアルタイムの音声スレッド）から毎回読まれる。
///
/// 音声スレッドはブロックしてはいけないためロックを取らない。
/// 受け渡すのは整列済みの Float 2つだけで、これらの読み書きは分割されない。
/// 更新の反映が数ミリ秒遅れても、音量つまみの操作としては問題にならない。
final class AudioTapSettings: @unchecked Sendable {
    private var leftGain: Float = 1
    private var rightGain: Float = 1

    var gains: (left: Float, right: Float) { (leftGain, rightGain) }

    /// `pan` は -1（完全に左）〜 0（中央）〜 +1（完全に右）。
    func update(volume: Float, isMuted: Bool, pan: Float) {
        let base = isMuted ? 0 : min(max(volume, 0), 1)
        let clampedPan = min(max(pan, -1), 1)
        leftGain = base * min(1, 1 - clampedPan)
        rightGain = base * min(1, 1 + clampedPan)
    }
}

enum MultiPlayerAudio {
    /// `track` に処理タップを挟んだ audioMix を作る。`settings` の変更は即座に音へ反映される。
    static func makeAudioMix(for track: AVAssetTrack, settings: AudioTapSettings) -> AVAudioMix? {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let clientInfo = UnsafeMutableRawPointer(Unmanaged.passRetained(settings).toOpaque())

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: tapInit,
            finalize: tapFinalize,
            prepare: nil,
            unprepare: nil,
            process: tapProcess
        )

        var tap: MTAudioProcessingTap?
        // 音を書き換える用途なので PreEffects（audioMix 自身の音量処理より前）に挟む。
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tap
        )
        guard status == noErr, let tap else {
            // 生成に失敗したら finalize が呼ばれないので、ここで retain を戻す。
            Unmanaged<AudioTapSettings>.fromOpaque(clientInfo).release()
            return nil
        }

        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    // clientInfo で渡された retain 済みの参照をそのままタップの保管領域へ移す。
    tapStorageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    guard let storage = MTAudioProcessingTapGetStorage(tap) as UnsafeMutableRawPointer? else { return }
    Unmanaged<AudioTapSettings>.fromOpaque(storage).release()
}

private let tapProcess: MTAudioProcessingTapProcessCallback = {
    tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in

    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
    )
    guard status == noErr else { return }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let settings = Unmanaged<AudioTapSettings>.fromOpaque(storage).takeUnretainedValue()
    let gains = settings.gains

    let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    let frameCount = Int(numberFramesOut.pointee)

    if buffers.count >= 2 {
        // 非インターリーブ（チャンネルごとに別バッファ）。AVFoundation の既定はこちら。
        applyGain(gains.left, to: buffers[0], frameCount: frameCount)
        applyGain(gains.right, to: buffers[1], frameCount: frameCount)
    } else if let buffer = buffers.first {
        if buffer.mNumberChannels == 2 {
            applyInterleavedStereoGain(gains, to: buffer, frameCount: frameCount)
        } else {
            // モノラル音声は左右へ分けようがないので、音量だけ反映する。
            applyGain((gains.left + gains.right) / 2, to: buffer, frameCount: frameCount)
        }
    }
}

private func applyGain(_ gain: Float, to buffer: AudioBuffer, frameCount: Int) {
    guard let data = buffer.mData else { return }
    let samples = data.assumingMemoryBound(to: Float.self)
    let count = min(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
    for i in 0..<count {
        samples[i] *= gain
    }
}

private func applyInterleavedStereoGain(_ gains: (left: Float, right: Float), to buffer: AudioBuffer, frameCount: Int) {
    guard let data = buffer.mData else { return }
    let samples = data.assumingMemoryBound(to: Float.self)
    let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
    let count = min(frameCount * 2, available)
    var i = 0
    while i + 1 < count {
        samples[i] *= gains.left
        samples[i + 1] *= gains.right
        i += 2
    }
}
