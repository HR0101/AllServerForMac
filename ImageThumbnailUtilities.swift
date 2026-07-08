import AppKit
import CoreGraphics

/// サムネイル用の画像処理ユーティリティ。
///
/// `NSImage.lockFocus()/unlockFocus()` はプロセス全体で共有される「カレントの描画コンテキスト」に
/// 依存するため、複数スレッドから同時に呼び出すと安全ではない（画像が壊れる／クラッシュしうる）。
/// ここでは CGContext だけで完結させることで、バックグラウンドスレッドから並行して
/// 呼び出しても安全なようにしている。`nonisolated` を明示し、MainActor をブロックせずに
/// `Task.detached` から直接呼べるようにする。

/// 中央を正方形に切り抜いてから指定サイズへリサイズする。
nonisolated func squareCroppedCGImage(_ cgImage: CGImage, side: Int) -> CGImage? {
    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0, side > 0 else { return nil }

    let dim = min(width, height)
    let x = (width - dim) / 2
    let y = (height - dim) / 2
    let cropped = cgImage.cropping(to: CGRect(x: x, y: y, width: dim, height: dim)) ?? cgImage

    guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
    return context.makeImage()
}

/// アスペクト比を保ったまま指定サイズに収まるようリサイズする（拡大もありうる。元実装の挙動を踏襲）。
nonisolated func resizedToFitCGImage(_ cgImage: CGImage, maxSize: CGSize) -> CGImage? {
    let originalSize = CGSize(width: cgImage.width, height: cgImage.height)
    guard originalSize.width > 0, originalSize.height > 0 else { return nil }

    let ratio = min(maxSize.width / originalSize.width, maxSize.height / originalSize.height)
    let targetWidth = max(1, Int((originalSize.width * ratio).rounded()))
    let targetHeight = max(1, Int((originalSize.height * ratio).rounded()))

    guard let context = CGContext(
        data: nil,
        width: targetWidth,
        height: targetHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    return context.makeImage()
}

nonisolated func jpegData(from cgImage: CGImage, compression: CGFloat) -> Data? {
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
}
