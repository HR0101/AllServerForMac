import SwiftUI
import AVFoundation
import AppKit

struct MacVideoThumbnailView: View {
    let videoItem: VideoItem
    let dataManager: VideoDataManager
    @EnvironmentObject private var appSettings: AppSettings
    @State private var thumbnail: NSImage?

    /// ディスクキャッシュの前段のプロセス共有メモリキャッシュ。
    /// LazyVGrid でセルが画面外に出て戻るたびにディスクから再読込・再デコードするのを防ぐ。
    private static let memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = UserDefaults.standard.object(forKey: "thumbnailMemoryCacheLimit") as? Int ?? 600
        return cache
    }()

    /// 詳細設定からキャッシュ上限を変更したときに即時反映するための入口。
    static func updateMemoryCacheLimit(_ limit: Int) {
        memoryCache.countLimit = max(100, limit)
    }

    /// 指定した動画IDのデコード済みサムネイルをメモリキャッシュから解放する。
    /// アルバム画面を離れるときに呼び、他のアルバムを見ている間はそのアルバムの
    /// デコード済み画像をメモリに残さないようにする（ディスクキャッシュ自体は消さないので、
    /// 同じアルバムに戻ればすぐ再表示できる）。
    static func evictFromMemoryCache<S: Sequence>(videoIDs: S) where S.Element == UUID {
        for id in videoIDs {
            memoryCache.removeObject(forKey: id.uuidString as NSString)
        }
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
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
            // 影とフェードインアニメーションはセルごとにオフスクリーン描画・アニメーショントランザクションを発生させ、
            // 大量枚数のグリッドではスクロールのカクつきに直結するため外している。
            .task { await generateThumbnail(forceRegenerate: false) }
            .onChange(of: appSettings.thumbnailOption) { _, _ in
                guard videoItem.mediaType == .video else { return }
                Task { await generateThumbnail(forceRegenerate: true) }
            }
            .onChange(of: appSettings.customThumbnailTime) { _, _ in
                guard videoItem.mediaType == .video, appSettings.thumbnailOption == .custom else { return }
                Task { await generateThumbnail(forceRegenerate: true) }
            }
    }

    private func generateThumbnail(forceRegenerate: Bool) async {
        let cacheKey = videoItem.id.uuidString as NSString
        let cacheURL = dataManager.thumbnailStorageURL
            .appendingPathComponent(videoItem.id.uuidString)
            .appendingPathExtension("jpg")

        if !forceRegenerate {
            if let cached = Self.memoryCache.object(forKey: cacheKey) {
                thumbnail = cached
                return
            }

            let cached: NSImage? = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: cacheURL) else { return nil }
                return NSImage(data: data)
            }.value
            if let img = cached {
                Self.memoryCache.setObject(img, forKey: cacheKey)
                thumbnail = img
                return
            }
        }

        guard let fileURL = dataManager.fileURL(for: videoItem) else { return }

        if videoItem.mediaType == .photo {
            await generatePhotoThumbnail(fileURL: fileURL, cacheURL: cacheURL)
        } else {
            await generateVideoThumbnail(fileURL: fileURL, cacheURL: cacheURL)
        }
    }

    private func generatePhotoThumbnail(fileURL: URL, cacheURL: URL) async {
        // 元画像の読み込み・デコード・切り抜き・JPEG書き出しは重い同期処理のため、
        // メインスレッド（UIスレッド）をブロックしないようバックグラウンドで実行する。
        let nsImage: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let imageData = try? Data(contentsOf: fileURL),
                  let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 300,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
                  let cropped = squareCroppedCGImage(cgImage, side: 400) else { return nil }
            if let data = jpegData(from: cropped, compression: 0.7) {
                try? data.write(to: cacheURL)
            }
            return NSImage(cgImage: cropped, size: .zero)
        }.value

        guard let nsImage else { return }
        Self.memoryCache.setObject(nsImage, forKey: videoItem.id.uuidString as NSString)
        thumbnail = nsImage
    }

    private func generateVideoThumbnail(fileURL: URL, cacheURL: URL) async {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let duration = (try? await asset.load(.duration).seconds) ?? 0

        // 設定で選ばれた抽出位置を先頭に、黒フレーム時のフォールバックを後ろに並べる
        let preferred = appSettings.thumbnailOption.seconds(
            forDuration: duration,
            customTime: appSettings.customThumbnailTime
        )
        var attempts = [preferred]
        attempts.append(contentsOf: [1.0, 3.0, 5.0, 10.0, 20.0, 30.0, 60.0].filter { $0 < duration && $0 != preferred })
        if duration < 5 { attempts.append(0.0) }
        attempts = attempts.map { min(max(0, $0), max(0, duration - 0.05)) }
        if attempts.isEmpty { attempts = [0.0] }

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

        guard let cgImage = bestImage ?? fallbackImage else { return }

        // 切り抜き・JPEG書き出しはバックグラウンドで実行する（AVAssetImageGenerator 自体は非同期だが、
        // その後の後処理は同期処理でメインスレッドをブロックしうるため）。
        let nsImage: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let cropped = squareCroppedCGImage(cgImage, side: 400) else { return nil }
            if let data = jpegData(from: cropped, compression: 0.7) {
                try? data.write(to: cacheURL)
            }
            return NSImage(cgImage: cropped, size: .zero)
        }.value

        guard let nsImage else { return }
        Self.memoryCache.setObject(nsImage, forKey: videoItem.id.uuidString as NSString)
        thumbnail = nsImage
    }
}
