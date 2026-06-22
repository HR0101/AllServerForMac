import SwiftUI
import AVFoundation
import AppKit

struct MacVideoThumbnailView: View {
    let videoItem: VideoItem
    let dataManager: VideoDataManager
    @State private var thumbnail: NSImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.16)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .overlay {
                if videoItem.mediaType == .video && thumbnail != nil {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
            .animation(.easeOut(duration: 0.25), value: thumbnail != nil)
            .task { await generateThumbnail() }
    }

    private func generateThumbnail() async {
        let cacheURL = dataManager.thumbnailStorageURL
            .appendingPathComponent(videoItem.id.uuidString)
            .appendingPathExtension("jpg")

        let cached: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: cacheURL) else { return nil }
            return NSImage(data: data)
        }.value

        if let img = cached {
            thumbnail = img
            return
        }

        guard let fileURL = dataManager.fileURL(for: videoItem) else { return }

        if videoItem.mediaType == .photo {
            await generatePhotoThumbnail(fileURL: fileURL, cacheURL: cacheURL)
        } else {
            await generateVideoThumbnail(fileURL: fileURL, cacheURL: cacheURL)
        }
    }

    private func generatePhotoThumbnail(fileURL: URL, cacheURL: URL) async {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 300,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return }
        let nsImage = squareCropped(NSImage(cgImage: cgImage, size: .zero))
        saveToCache(nsImage, url: cacheURL)
        thumbnail = nsImage
    }

    private func generateVideoThumbnail(fileURL: URL, cacheURL: URL) async {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let duration = (try? await asset.load(.duration).seconds) ?? 0
        var attempts = [1.0, 3.0, 5.0, 10.0, 20.0, 30.0, 60.0].filter { $0 < duration }
        if duration < 5 { attempts.insert(0.0, at: 0) }
        if attempts.isEmpty { attempts.append(0.0) }

        var bestImage: CGImage?
        var fallbackImage: CGImage?

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
            let nsImage = squareCropped(NSImage(cgImage: cgImage, size: .zero))
            saveToCache(nsImage, url: cacheURL)
            thumbnail = nsImage
        }
    }

    /// 中央を正方形に切り抜いて指定サイズへリサイズする。
    /// Web サーバー（WebServerManager.cropAndResize）と共有のキャッシュへ書き込むため、
    /// クライアントに配信される .jpg が常に正方形になるよう揃える。
    private func squareCropped(_ nsImage: NSImage, side: CGFloat = 400) -> NSImage {
        let targetSize = CGSize(width: side, height: side)
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        let originalSize = nsImage.size
        let dim = min(originalSize.width, originalSize.height)
        let x = (originalSize.width - dim) / 2
        let y = (originalSize.height - dim) / 2
        let cropRect = CGRect(x: x, y: y, width: dim, height: dim)
        nsImage.draw(in: CGRect(origin: .zero, size: targetSize), from: cropRect, operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    private func saveToCache(_ image: NSImage, url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return }
        try? data.write(to: url)
    }
}
