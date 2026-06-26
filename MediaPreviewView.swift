import SwiftUI
import AVKit

// アプリ内でのメディア再生・表示ビュー（動画: AVPlayer / 画像: NSImage）
struct MediaPreviewView: View {
    let item: VideoItem
    let dataManager: VideoDataManager
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var photo: NSImage?
    @State private var fileMissing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 760, idealWidth: 920, minHeight: 500, idealHeight: 640)
        .onAppear(perform: load)
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: item.mediaType == .video ? "play.rectangle.fill" : "photo.fill")
                .foregroundStyle(.secondary)
            Text(item.originalFilename)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            if item.mediaType == .video, item.duration > 0 {
                Text(formatDuration(item.duration))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                if let url = dataManager.fileURL(for: item) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("外部プレイヤーで開く", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)

            Button("閉じる") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if fileMissing {
            ContentUnavailableView(
                "ファイルが見つかりません",
                systemImage: "questionmark.video",
                description: Text("メディアファイルが移動または削除された可能性があります")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.mediaType == .video {
            PlayerContainerView(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else {
            ZStack {
                Color.black
                if let photo = photo {
                    Image(nsImage: photo)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() {
        guard let url = dataManager.fileURL(for: item) else {
            fileMissing = true
            return
        }
        if item.mediaType == .video {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        } else {
            Task.detached(priority: .userInitiated) {
                let image = NSImage(contentsOf: url)
                await MainActor.run {
                    if let image = image {
                        photo = image
                    } else {
                        fileMissing = true
                    }
                }
            }
        }
    }

    private func formatDuration(_ totalSeconds: TimeInterval) -> String {
        let s = Int(totalSeconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
