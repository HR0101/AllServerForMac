import SwiftUI
import AVFoundation
import AppKit

// ===================================
//  MacVideoThumbnailView.swift
// ===================================
// Mac上で動画のサムネイルを非同期に生成して表示します。

struct MacVideoThumbnailView: View {
    let videoItem: VideoItem
    let storageURL: URL
    
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // ★ 追加: サムネイル画像の背景を黒で塗りつぶします。
            Color.black
            
            if let thumbnail = thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    // ★ 修正: .fillから.fitに変更し、画像全体が表示されるようにします。
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.black.opacity(0.2))
                    .overlay(ProgressView())
            }
            Text(videoItem.originalFilename)
                .font(.caption)
                .foregroundColor(.white)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(gradient: Gradient(colors: [.black.opacity(0.6), .clear]), startPoint: .bottom, endPoint: .top)
                )
        }
        .clipped()
        // ★ 追加: ここでアスペクト比、角丸、影のスタイルを適用します。
        .aspectRatio(1, contentMode: .fit)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 2)
        .task { await generateThumbnail() }
    }

    private func generateThumbnail() async {
        let videoURL = storageURL.appendingPathComponent(videoItem.internalFilename)
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        do {
            let cgImage = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 60)).image
            await MainActor.run {
                self.thumbnail = NSImage(cgImage: cgImage, size: .zero)
            }
        } catch {
            print("❌ Failed to generate thumbnail: \(error)")
        }
    }
}
