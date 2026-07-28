import CoreGraphics

// MARK: - Shared Utilities

func isImagePredominantlyBlack(image: CGImage, threshold: CGFloat = 0.1) -> Bool {
    let size = 20
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var rawData = [UInt8](repeating: 0, count: size * size * 4)
    guard let context = CGContext(
        data: &rawData, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
    var darkPixelCount = 0
    for i in 0..<(size * size) {
        let offset = i * 4
        let luminance = 0.299 * CGFloat(rawData[offset]) / 255.0
                      + 0.587 * CGFloat(rawData[offset + 1]) / 255.0
                      + 0.114 * CGFloat(rawData[offset + 2]) / 255.0
        if luminance < threshold { darkPixelCount += 1 }
    }
    return Double(darkPixelCount) / Double(size * size) > 0.8
}
