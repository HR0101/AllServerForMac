import SwiftUI
import AVFoundation
import AppKit

// ===================================
//  MacVideoThumbnailView.swift (黒サムネイル回避・順次探索版)
// ===================================

struct MacVideoThumbnailView: View {
    let videoItem: VideoItem
    let storageURL: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            
            if let thumbnail = thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.black.opacity(0.2))
                    .overlay(ProgressView())
            }
            
            if videoItem.mediaType == .video {
                Text(videoItem.originalFilename)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(gradient: Gradient(colors: [.black.opacity(0.6), .clear]), startPoint: .bottom, endPoint: .top)
                    )
            }
        }
        .clipped()
        .aspectRatio(1, contentMode: .fit)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 2)
        .task { await generateThumbnail() }
    }

    private func generateThumbnail() async {
        let fileURL = storageURL.appendingPathComponent(videoItem.internalFilename)
        
        if videoItem.mediaType == .photo {
            if let image = NSImage(contentsOf: fileURL) {
                self.thumbnail = image
            }
            return
        }

        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        
        // 探索候補 (WebServerManagerと同じロジック)
        var attempts: [Double] = [1.0, 3.0, 5.0, 10.0, 20.0, 30.0, 60.0]
        if duration < 5 { attempts.insert(0.0, at: 0) }
        let validAttempts = attempts.filter { $0 < duration }
        
        var bestImage: CGImage?
        var fallbackImage: CGImage?
        
        for seconds in validAttempts {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                if fallbackImage == nil { fallbackImage = cgImage }
                if !isImagePredominantlyBlack(image: cgImage) {
                    bestImage = cgImage
                    break
                }
            }
        }
        
        if let cgImage = bestImage ?? fallbackImage {
            await MainActor.run {
                self.thumbnail = NSImage(cgImage: cgImage, size: .zero)
            }
        }
    }
    
    private func isImagePredominantlyBlack(image: CGImage, threshold: CGFloat = 0.1) -> Bool {
        let size = 20
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawData = [UInt8](repeating: 0, count: size * size * 4)
        
        guard let context = CGContext(data: &rawData, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
        
        var darkPixelCount = 0
        let totalPixels = size * size
        
        for i in 0..<totalPixels {
            let offset = i * 4
            let r = CGFloat(rawData[offset]) / 255.0
            let g = CGFloat(rawData[offset+1]) / 255.0
            let b = CGFloat(rawData[offset+2]) / 255.0
            let luminance = 0.299 * r + 0.587 * g + 0.114 * b
            if luminance < threshold { darkPixelCount += 1 }
        }
        return Double(darkPixelCount) / Double(totalPixels) > 0.8
    }
}
