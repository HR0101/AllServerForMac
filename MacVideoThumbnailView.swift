import SwiftUI
import AVFoundation
import AppKit

// ===================================
//  MacVideoThumbnailView.swift (参照リンク・ダウンロードフォルダ対応版)
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

    // ★ 実際のファイルの場所を特定するメソッド（参照リンクやダウンロードフォルダに対応）
    private func getActualFileURL() -> URL? {
        // 1. Macから追加された参照リンクの場合
        if let extPath = videoItem.externalFilePath {
            let extURL = URL(fileURLWithPath: extPath)
            if FileManager.default.fileExists(atPath: extURL.path) {
                return extURL
            }
        }
        
        if videoItem.internalFilename.isEmpty { return nil }
        
        // 2. 隠しフォルダに存在する場合
        let hiddenURL = storageURL.appendingPathComponent(videoItem.internalFilename)
        if FileManager.default.fileExists(atPath: hiddenURL.path) {
            return hiddenURL
        }
        
        // 3. ダウンロードフォルダ（iOSからのアップロード）に存在する場合
        if let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            let downloadURL = downloadsDir.appendingPathComponent("VideoServerForMac_Media").appendingPathComponent(videoItem.internalFilename)
            if FileManager.default.fileExists(atPath: downloadURL.path) {
                return downloadURL
            }
        }
        
        return nil
    }

    private func generateThumbnail() async {
        guard let fileURL = getActualFileURL() else { return }
        
        if videoItem.mediaType == .photo {
            if let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) {
                let options: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 300,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                    await MainActor.run {
                        self.thumbnail = NSImage(cgImage: cgImage, size: .zero)
                    }
                }
            }
            return
        }

        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let maxAttempts: [Double] = [1.0, 3.0, 5.0, 10.0, 20.0, 30.0, 60.0].filter { $0 < duration }
        var attempts = maxAttempts
        if duration < 5 { attempts.insert(0.0, at: 0) }
        if attempts.isEmpty { attempts.append(0.0) }

        var bestImage: CGImage? = nil
        var fallbackImage: CGImage? = nil
        
        for seconds in attempts {
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
