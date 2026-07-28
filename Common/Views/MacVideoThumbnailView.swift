import SwiftUI
import AVFoundation
import AppKit

actor ThumbnailDecodeLimiter {
    static let shared = ThumbnailDecodeLimiter(limit: 3)

    private let limit: Int
    private var runningCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if runningCount < limit {
            runningCount += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            runningCount = max(0, runningCount - 1)
        } else {
            let continuation = waiters.removeFirst()
            continuation.resume()
        }
    }
}

actor ThumbnailGenerationCoordinator {
    static let shared = ThumbnailGenerationCoordinator()

    private var inFlightTasks: [String: Task<Data?, Never>] = [:]

    func data(
        for key: String,
        operation: @escaping @Sendable () async -> Data?
    ) async -> Data? {
        if let existingTask = inFlightTasks[key] {
            return await existingTask.value
        }

        let task = Task {
            await ThumbnailDecodeLimiter.shared.acquire()
            let data = await operation()
            await ThumbnailDecodeLimiter.shared.release()
            return data
        }
        inFlightTasks[key] = task
        let data = await task.value
        inFlightTasks[key] = nil
        return data
    }
}

nonisolated struct DecodedThumbnail: @unchecked Sendable {
    let image: NSImage
}

struct MacVideoThumbnailView: View {
    let videoItem: VideoItem
    let dataManager: LibraryViewModel
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
        let thumbnailOption = appSettings.thumbnailOption
        let customThumbnailTime = appSettings.customThumbnailTime
        let mediaType = videoItem.mediaType

        if !forceRegenerate {
            if let cached = Self.memoryCache.object(forKey: cacheKey) {
                thumbnail = cached
                return
            }
        }

        guard let fileURL = dataManager.fileURL(for: videoItem) else { return }
        let generationKey = [
            videoItem.id.uuidString,
            videoItem.mediaType.rawValue,
            thumbnailOption.rawValue,
            String(customThumbnailTime),
        ].joined(separator: "|")

        let data = await ThumbnailGenerationCoordinator.shared.data(
            for: generationKey
        ) {
            await Self.thumbnailData(
                fileURL: fileURL,
                cacheURL: cacheURL,
                mediaType: mediaType,
                thumbnailOption: thumbnailOption,
                customThumbnailTime: customThumbnailTime,
                forceRegenerate: forceRegenerate
            )
        }
        guard !Task.isCancelled,
              let data,
              let decoded = await Self.decodeThumbnail(data) else {
            return
        }
        Self.memoryCache.setObject(decoded.image, forKey: cacheKey)
        thumbnail = decoded.image
    }

    nonisolated private static func thumbnailData(
        fileURL: URL,
        cacheURL: URL,
        mediaType: MediaType,
        thumbnailOption: ThumbnailOption,
        customThumbnailTime: TimeInterval,
        forceRegenerate: Bool
    ) async -> Data? {
        if !forceRegenerate {
            let cachedData = await Task.detached(priority: .utility) {
                try? Data(contentsOf: cacheURL)
            }.value
            if let cachedData {
                return cachedData
            }
        }

        let data: Data?
        switch mediaType {
        case .photo:
            data = await generatePhotoThumbnailData(fileURL: fileURL)
        case .video:
            data = await generateVideoThumbnailData(
                fileURL: fileURL,
                thumbnailOption: thumbnailOption,
                customThumbnailTime: customThumbnailTime
            )
        }

        if let data {
            await Task.detached(priority: .utility) {
                try? data.write(to: cacheURL, options: .atomic)
            }.value
        }
        return data
    }

    nonisolated private static func generatePhotoThumbnailData(
        fileURL: URL
    ) async -> Data? {
        await Task.detached(priority: .utility) {
            let sourceOptions: [CFString: Any] = [
                kCGImageSourceShouldCache: false
            ]
            guard let imageSource = CGImageSourceCreateWithURL(
                fileURL as CFURL,
                sourceOptions as CFDictionary
            ) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 300,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                options as CFDictionary
            ),
            let cropped = squareCroppedCGImage(cgImage, side: 400) else {
                return nil
            }
            return jpegData(from: cropped, compression: 0.7)
        }.value
    }

    nonisolated private static func generateVideoThumbnailData(
        fileURL: URL,
        thumbnailOption: ThumbnailOption,
        customThumbnailTime: TimeInterval
    ) async -> Data? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let duration = (try? await asset.load(.duration).seconds) ?? 0

        // 設定で選ばれた抽出位置を先頭に、黒フレーム時のフォールバックを後ろに並べる
        let preferred = thumbnailOption.seconds(
            forDuration: duration,
            customTime: customThumbnailTime
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

        guard let cgImage = bestImage ?? fallbackImage else { return nil }

        // 切り抜き・JPEG書き出しはバックグラウンドで実行する（AVAssetImageGenerator 自体は非同期だが、
        // その後の後処理は同期処理でメインスレッドをブロックしうるため）。
        return await Task.detached(priority: .utility) {
            guard let cropped = squareCroppedCGImage(cgImage, side: 400) else { return nil }
            return jpegData(from: cropped, compression: 0.7)
        }.value
    }

    nonisolated private static func decodeThumbnail(
        _ data: Data
    ) async -> DecodedThumbnail? {
        await ThumbnailDecodeLimiter.shared.acquire()
        let decoded: DecodedThumbnail? = await Task.detached(priority: .utility) {
            () -> DecodedThumbnail? in
            guard let image = NSImage(data: data) else { return nil }
            return DecodedThumbnail(image: image)
        }.value
        await ThumbnailDecodeLimiter.shared.release()
        return decoded
    }
}
