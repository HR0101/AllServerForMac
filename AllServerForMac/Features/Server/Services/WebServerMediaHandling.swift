import AVFoundation
import AppKit
import Darwin
import Foundation
import MediaServerKit
import Swifter

nonisolated enum ThumbQuality: Sendable { case high, low }

actor ServerThumbnailGenerationCoordinator {
    static let shared = ServerThumbnailGenerationCoordinator()

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

extension ServerViewModel {
    func thumbnailMaxPixelSize(from queryParams: [(String, String)], isOriginal: Bool) -> Int? {
        guard isOriginal,
              let value = queryParams.first(where: { $0.0 == "max" })?.1,
              let requestedSize = Int(value) else {
            return nil
        }
        return min(max(requestedSize, 400), 3000)
    }

    func serveFile(at url: URL, request: HttpRequest) -> HttpResponse {
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attr[.size] as? UInt64 else { return .internalServerError }
            let mime = MimeType.forPath(url.path)

            if let rangeHeader = request.headers["range"], let range = RangeHeader.parse(rangeHeader, totalSize: size) {
                let (start, end) = range
                let length = end - start + 1
                return .raw(206, "Partial Content", [
                    "Content-Type": mime, "Content-Length": String(length),
                    "Content-Range": "bytes \(start)-\(end)/\(size)", "Accept-Ranges": "bytes"
                ], { writer in
                    let fd = open(url.path, O_RDONLY)
                    guard fd != -1 else { return }
                    defer { close(fd) }
                    lseek(fd, off_t(start), SEEK_SET)

                    var remaining = length
                    let chunkSize = 1024 * 1024 * 2 // 2MB chunks
                    var buffer = [UInt8](repeating: 0, count: chunkSize)

                    while remaining > 0 {
                        let toRead = min(Int(chunkSize), Int(remaining))
                        let bytesRead = read(fd, &buffer, toRead)
                        if bytesRead <= 0 { break }
                        let data = Data(bytes: &buffer, count: bytesRead)
                        do {
                            try writer.write(data)
                            remaining -= UInt64(bytesRead)
                        } catch {
                            break
                        }
                    }
                })
            } else {
                return .raw(200, "OK", [
                    "Content-Type": mime,
                    "Content-Length": String(size),
                    "Accept-Ranges": "bytes"
                ], { writer in
                    let fd = open(url.path, O_RDONLY)
                    guard fd != -1 else { return }
                    defer { close(fd) }

                    let chunkSize = 1024 * 1024 * 2 // 2MB chunks
                    var buffer = [UInt8](repeating: 0, count: chunkSize)

                    while true {
                        let bytesRead = read(fd, &buffer, chunkSize)
                        if bytesRead <= 0 { break }
                        let data = Data(bytes: &buffer, count: bytesRead)
                        do {
                            try writer.write(data)
                        } catch {
                            break
                        }
                    }
                })
            }
        } catch {
            return .internalServerError
        }
    }

    func getIPAddress() -> String? {
        // en* の「最初に見つかった」IPv4 を使うと、Parallels/Docker/インターネット共有が作る
        // 仮想ブリッジ（例: en5 = 192.168.64.1）が拾われ、表示URLに他デバイスから到達できない
        // ことがある。実LANに繋がっているのは通常 en0/en1 なので、候補を全部集めてから
        // 番号の小さい enX を優先し、リンクローカル(169.254.*)は除外する。
        var candidates: [(name: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    guard let name = interface.ifa_name, let cStringName = String(cString: name, encoding: .utf8) else { continue }
                    if cStringName.starts(with: "en") {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        let ip = String(cString: hostname)
                        if !ip.isEmpty && !ip.hasPrefix("169.254.") {
                            candidates.append((cStringName, ip))
                        }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }

        func interfaceNumber(_ name: String) -> Int {
            Int(name.dropFirst(2)) ?? Int.max
        }
        return candidates.min(by: { interfaceNumber($0.name) < interfaceNumber($1.name) })?.ip
    }

    func generateThumbnailData(for url: URL, type: MediaType, quality: ThumbQuality, isOriginal: Bool = false, requestedTime: Double? = nil, maxPixelSize: Int? = nil) async -> Data? {
        let qualityKey = quality == .high ? "high" : "low"
        let generationKey = [
            url.standardizedFileURL.path,
            type.rawValue,
            qualityKey,
            String(isOriginal),
            requestedTime.map { String($0) } ?? "default",
            maxPixelSize.map { String($0) } ?? "default",
        ].joined(separator: "|")

        return await ServerThumbnailGenerationCoordinator.shared.data(
            for: generationKey
        ) { [weak self] in
            guard let self else { return nil }
            return await self.generateThumbnailDataWithoutCoordination(
                for: url,
                type: type,
                quality: quality,
                isOriginal: isOriginal,
                requestedTime: requestedTime,
                maxPixelSize: maxPixelSize
            )
        }
    }

    private func generateThumbnailDataWithoutCoordination(
        for url: URL,
        type: MediaType,
        quality: ThumbQuality,
        isOriginal: Bool,
        requestedTime: Double?,
        maxPixelSize: Int?
    ) async -> Data? {
        let defaultSize: CGFloat = quality == .high ? 400 : 50
        let requestedSize = CGFloat(maxPixelSize ?? Int(defaultSize))
        let size = CGSize(width: requestedSize, height: requestedSize)
        let compression = quality == .high ? 0.8 : 0.1

        if type == .photo {
            // 元画像の読み込み・デコード・リサイズはメインスレッド（アプリ全体）をブロックしうる重い同期処理のため、
            // バックグラウンドで実行する。
            return await Task.detached(priority: .utility) {
                ServerViewModel.generateImageThumbnail(url: url, targetSize: size, compression: compression, isOriginal: isOriginal)
            }.value
        } else {
            return await generateVideoThumbnail(url: url, targetSize: size, compression: compression, isOriginal: isOriginal, requestedTime: requestedTime)
        }
    }

    nonisolated private static func generateImageThumbnail(url: URL, targetSize: CGSize, compression: Double, isOriginal: Bool) -> Data? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(targetSize.width, targetSize.height),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
        if isOriginal {
            guard let resized = resizedToFitCGImage(cgImage, maxSize: targetSize) else { return nil }
            return jpegData(from: resized, compression: compression)
        } else {
            guard let cropped = squareCroppedCGImage(cgImage, side: Int(max(targetSize.width, targetSize.height))) else { return nil }
            return jpegData(from: cropped, compression: compression)
        }
    }

    private func generateVideoThumbnail(url: URL, targetSize: CGSize, compression: Double, isOriginal: Bool, requestedTime: Double?) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let duration = (try? await asset.load(.duration).seconds) ?? 0

        var bestCGImage: CGImage? = nil
        var fallbackImage: CGImage? = nil

        if let requestedTime = requestedTime, requestedTime >= 0, requestedTime <= duration {
            let time = CMTime(seconds: requestedTime, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                bestCGImage = cgImage
            }
        } else {
            var attempts: [Double] = [1.0, 3.0, 5.0, 10.0, 20.0, 30.0, 60.0]

            if duration < 5 {
                attempts.insert(0.0, at: 0)
            }

            let validAttempts = attempts.filter { $0 < duration }

            for seconds in validAttempts {
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                if let cgImage = try? await generator.image(at: time).image {
                    if fallbackImage == nil { fallbackImage = cgImage }

                    if !isImagePredominantlyBlack(image: cgImage) {
                        bestCGImage = cgImage
                        break
                    }
                }
            }
        }

        guard let cgImage = bestCGImage ?? fallbackImage else { return nil }
        return await Task.detached(priority: .utility) {
            if isOriginal {
                guard let resized = resizedToFitCGImage(cgImage, maxSize: targetSize) else { return nil }
                return jpegData(from: resized, compression: compression)
            } else {
                guard let cropped = squareCroppedCGImage(cgImage, side: Int(max(targetSize.width, targetSize.height))) else { return nil }
                return jpegData(from: cropped, compression: compression)
            }
        }.value
    }

    var placeholderData: Data {
        let img = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!
        guard let tiffData = img.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            return Data()
        }
        return jpegData
    }
}
