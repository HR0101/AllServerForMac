import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - QR コード

/// 文字列から QR コードの画像を作る。
/// 1モジュールを整数ピクセルに拡大して最近傍で描くので、縁がにじまず、カメラに読み取られやすい。
enum QRCode {
    private static let cache = NSCache<NSString, NSImage>()
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func image(for text: String, moduleSize: Int = 12) -> NSImage? {
        let key = "\(moduleSize)|\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // 誤り訂正は M（約15%まで欠けても読める）。画面表示なら十分で、モジュールが大きく保てる。
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: CGFloat(moduleSize), y: CGFloat(moduleSize)))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key)
        return image
    }
}

/// 白地に黒の QR コード。
/// 読み取りの精度のため、黒基調の外観でも反転させず、常に白地・黒モジュール・周囲の余白つきで描く。
struct QRCodeView: View {
    let text: String
    var size: CGFloat = 96

    var body: some View {
        Group {
            if let image = QRCode.image(for: text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.black.opacity(0.3))
                    .frame(width: size, height: size)
            }
        }
        // QR コードの規格が求める「周囲の余白（クワイエットゾーン）」を白で確保する。
        .padding(8)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("接続先のQRコード")
    }
}
