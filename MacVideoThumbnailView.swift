import SwiftUI
import AVFoundation

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
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // ★ 追加: 画像の場合はファイル名のみ表示（時間を隠す）
            if videoItem.mediaType == .video {
                Text(formatDuration(videoItem.duration))
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(4)
                    .background(.black.opacity(0.6))
                    .cornerRadius(4)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .bottomTrailing)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .cornerRadius(12)
        .task { await generateThumbnail() }
    }

    private func generateThumbnail() async {
        let fileURL = storageURL.appendingPathComponent(videoItem.internalFilename)
        
        // ★ 画像の場合の処理
        if videoItem.mediaType == .photo {
            if let image = NSImage(contentsOf: fileURL) {
                self.thumbnail = image
            }
            return
        }

        // 動画の場合の処理
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        do {
            let cgImage = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 60)).image
            await MainActor.run { self.thumbnail = NSImage(cgImage: cgImage, size: .zero) }
        } catch {
            print("Thumbnail failed")
        }
    }
    
    private func formatDuration(_ totalSeconds: TimeInterval) -> String {
        let seconds = Int(totalSeconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
