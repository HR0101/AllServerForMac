import SwiftUI
import AVFoundation
import AppKit

struct MacVideoThumbnailView: View {
    let videoItem: VideoItem
    let dataManager: VideoDataManager
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
                        LinearGradient(
                            gradient: Gradient(colors: [.black.opacity(0.6), .clear]),
                            startPoint: .bottom, endPoint: .top
                        )
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
        let nsImage = NSImage(cgImage: cgImage, size: .zero)
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
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            saveToCache(nsImage, url: cacheURL)
            thumbnail = nsImage
        }
    }

    private func saveToCache(_ image: NSImage, url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return }
        try? data.write(to: url)
    }
}
