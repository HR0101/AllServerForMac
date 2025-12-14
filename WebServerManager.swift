import Foundation
import Swifter
import AVFoundation
import AppKit
import Darwin
import Combine

// ===================================
//  WebServerManager.swift (順次探索サムネイル生成版)
// ===================================

class WebServerManager: NSObject, ObservableObject, NetServiceDelegate {
    private let server = HttpServer()
    private var netService: NetService?
    
    private weak var dataManager: VideoDataManager?
    
    @Published var statusMessage: String = "停止中"
    
    init(dataManager: VideoDataManager) {
        self.dataManager = dataManager
        super.init()
        print("✅ [LIFECYCLE] WebServerManager initialized.")
        setupRoutes()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionOrAppTermination),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionOrAppTermination),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
    }
    
    deinit {
        print("🛑 [LIFECYCLE] WebServerManager deinitialized.")
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - API Routes
    private func setupRoutes() {
        
        server["/albums"] = { [weak self] _ -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            var albumInfos: [RemoteAlbumInfo] = []
            DispatchQueue.main.sync {
                albumInfos = dataManager.albums.map {
                    RemoteAlbumInfo(id: $0.id.uuidString, name: $0.name, videoCount: $0.videoIDs.count, type: $0.type.rawValue)
                }
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                let jsonData = try encoder.encode(albumInfos)
                return .ok(.data(jsonData, contentType: "application/json"))
            } catch { return .internalServerError }
        }
        
        server["/albums/:id/videos"] = { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            guard let albumIDString = request.params[":id"], let albumID = UUID(uuidString: albumIDString) else {
                return .badRequest(.text("Invalid album ID"))
            }
            var videoInfos: [RemoteVideoInfo] = []
            var found = false
            DispatchQueue.main.sync {
                if let album = dataManager.albums.first(where: { $0.id == albumID }) {
                    found = true
                    let videoItems = dataManager.videos.filter { album.videoIDs.contains($0.id) }
                    videoInfos = videoItems.map {
                        RemoteVideoInfo(id: $0.id.uuidString,
                                        filename: $0.originalFilename,
                                        duration: $0.duration,
                                        importDate: $0.importDate,
                                        creationDate: $0.creationDate,
                                        mediaType: $0.mediaType.rawValue)
                    }
                }
            }
            guard found else { return .notFound }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let jsonData = try encoder.encode(videoInfos)
                return .ok(.data(jsonData, contentType: "application/json"))
            } catch { return .internalServerError }
        }
        
        server.post["/move"] = { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            struct MoveRequest: Codable { let videoIds: [String]; let targetAlbumId: String }
            do {
                let moveRequest = try JSONDecoder().decode(MoveRequest.self, from: Data(request.body))
                let videoUUIDs = moveRequest.videoIds.compactMap { UUID(uuidString: $0) }
                guard let targetAlbumUUID = UUID(uuidString: moveRequest.targetAlbumId) else { return .badRequest(.text("Invalid target album ID")) }
                DispatchQueue.main.async { dataManager.moveVideos(videoIDs: videoUUIDs, to: targetAlbumUUID) }
                return .ok(.text("Move successful"))
            } catch { return .badRequest(.text("Invalid request body")) }
        }

        server["/video/:id"] = { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let videoIDString = request.params[":id"],
                  let videoID = UUID(uuidString: videoIDString) else { return .notFound }
            var videoURL: URL?
            DispatchQueue.main.sync {
                if let videoItem = dataManager.videos.first(where: { $0.id == videoID }) {
                    videoURL = dataManager.videoStorageURL.appendingPathComponent(videoItem.internalFilename)
                }
            }
            guard let url = videoURL else { return .notFound }
            return self.serveFile(at: url, request: request)
        }
        
        server["/thumbnail/:id"] = { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let videoIDString = request.params[":id"],
                  let videoID = UUID(uuidString: videoIDString) else { return .notFound }
            
            let thumbnailURL = dataManager.thumbnailStorageURL.appendingPathComponent(videoIDString).appendingPathExtension("jpg")

            if let cachedData = try? Data(contentsOf: thumbnailURL) {
                return .ok(.data(cachedData, contentType: "image/jpeg"))
            }
            
            var targetItem: VideoItem?
            var videoFileUrl: URL?
            DispatchQueue.main.sync {
                if let item = dataManager.videos.first(where: { $0.id == videoID }) {
                    targetItem = item
                    videoFileUrl = dataManager.videoStorageURL.appendingPathComponent(item.internalFilename)
                }
            }
            guard let item = targetItem, let fileUrl = videoFileUrl else { return .notFound }
            
            let semaphore = DispatchSemaphore(value: 0)
            var generatedData: Data? = nil
            
            Task {
                if let data = await self.generateThumbnailData(for: fileUrl, type: item.mediaType, quality: .high) {
                    try? data.write(to: thumbnailURL)
                    generatedData = data
                }
                semaphore.signal()
            }
            
            let result = semaphore.wait(timeout: .now() + 5.0)
            
            if result == .success, let data = generatedData {
                return .ok(.data(data, contentType: "image/jpeg"))
            } else {
                let headers = ["Content-Type": "image/jpeg"]
                return .raw(202, "Accepted", headers, { writer in
                    try? writer.write(self.placeholderData)
                })
            }
        }
        
        print("✅ [SETUP] API routes configured.")
    }
    
    // MARK: - Server Control
    func startServer() {
        guard !server.operating else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.server.start(0, forceIPv4: true)
                let actualPort = try self.server.port()
                DispatchQueue.main.async {
                    guard let computerName = Host.current().localizedName else {
                        self.statusMessage = "❌ [FATAL] Could not get computer name."; self.server.stop(); return
                    }
                    let userName = NSUserName()
                    let uniqueServiceName = "\(computerName) (\(userName))"
                    self.netService = NetService(domain: "local.", type: "_myvideoserver._tcp.", name: uniqueServiceName, port: Int32(actualPort))
                    self.netService?.delegate = self
                    self.netService?.publish()
                }
            } catch {
                DispatchQueue.main.async { self.statusMessage = "❌ Server start failed: \(error.localizedDescription)" }
            }
        }
    }

    @objc func stopServer() { stopServerInternal() }
    
    private func stopServerInternal() {
        netService?.stop(); netService = nil
        server.stop()
        if Thread.isMainThread { statusMessage = "🛑 サーバー停止" } else { DispatchQueue.main.async { self.statusMessage = "🛑 サーバー停止" } }
    }
    
    @objc private func handleSessionOrAppTermination() { stopServerInternal() }
    
    func netServiceDidPublish(_ sender: NetService) {
        let ipAddress = getIPAddress() ?? "N/A"
        self.statusMessage = "✅ 実行中: http://\(ipAddress):\(sender.port)"
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        self.statusMessage = "❌ Bonjour publish failed."
        self.server.stop()
    }
    
    // MARK: - Helpers
    private func serveFile(at url: URL, request: HttpRequest) -> HttpResponse {
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attr[.size] as? UInt64 else { return .internalServerError }
            let mime = MimeType.forPath(url.path)
            
            if let rangeHeader = request.headers["range"], let range = parseRangeHeader(rangeHeader, totalSize: size) {
                let (start, end) = range
                let length = end - start + 1
                let file = try FileHandle(forReadingFrom: url)
                defer { file.closeFile() }
                try file.seek(toOffset: start)
                let data = file.readData(ofLength: Int(length))
                return .raw(206, "Partial Content", [
                    "Content-Type": mime, "Content-Length": String(length),
                    "Content-Range": "bytes \(start)-\(end)/\(size)", "Accept-Ranges": "bytes"
                ], { writer in try? writer.write(data) })
            } else {
                let data = try Data(contentsOf: url)
                return .ok(.data(data, contentType: mime))
            }
        } catch { return .internalServerError }
    }

    private func getIPAddress() -> String? {
        var address: String?
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
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST)); getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        let ip = String(cString: hostname); if !ip.isEmpty { address = ip; break }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
    
    private func parseRangeHeader(_ header: String, totalSize: UInt64) -> (UInt64, UInt64)? {
        guard header.hasPrefix("bytes="), totalSize > 0 else { return nil }
        let components = header.dropFirst(6).split(separator: "-")
        guard let startStr = components.first, let start = UInt64(startStr) else { return nil }
        let end = (components.count > 1 && !components[1].isEmpty) ? min(UInt64(components[1]) ?? 0, totalSize - 1) : totalSize - 1
        return start <= end ? (start, end) : nil
    }

    private enum ThumbQuality { case high, low }
    
    private func generateThumbnailData(for url: URL, type: MediaType, quality: ThumbQuality) async -> Data? {
        let size: CGSize = quality == .high ? CGSize(width: 400, height: 400) : CGSize(width: 50, height: 50)
        let compression = quality == .high ? 0.8 : 0.1
        
        if type == .photo {
            return generateImageThumbnail(url: url, targetSize: size, compression: compression)
        } else {
            return await generateVideoThumbnail(url: url, targetSize: size, compression: compression)
        }
    }
    
    private func generateImageThumbnail(url: URL, targetSize: CGSize, compression: Double) -> Data? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(targetSize.width, targetSize.height),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: .zero)
        return cropAndResize(nsImage: nsImage, targetSize: targetSize, compression: compression)
    }

    // ★ 修正: 動画サムネイル生成（順次探索ロジック）
    private func generateVideoThumbnail(url: URL, targetSize: CGSize, compression: Double) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        
        // 探索候補: 1秒, 3秒, 5秒, 10秒, 30秒, 60秒... と順に見ていく
        // 動画の中間地点などをいきなり見に行くとネタバレになる可能性があるため、冒頭から順に「使える画」を探す
        var attempts: [Double] = [1.0, 3.0, 5.0, 10.0, 20.0, 30.0, 60.0]
        
        // 動画が短い場合は、0秒地点も候補に入れる
        if duration < 5 {
            attempts.insert(0.0, at: 0)
        }
        
        // 動画の長さを超える候補は除外
        let validAttempts = attempts.filter { $0 < duration }
        
        var bestCGImage: CGImage? = nil
        var fallbackImage: CGImage? = nil
        
        for seconds in validAttempts {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                // とりあえず最初の生成画像を確保（全部黒だった場合の最終手段）
                if fallbackImage == nil { fallbackImage = cgImage }
                
                // 黒くない画像が見つかったら、それを採用して探索終了
                if !isImagePredominantlyBlack(image: cgImage) {
                    bestCGImage = cgImage
                    break
                }
            }
        }
        
        // 見つかったベスト画像、なければ最初の画像を使用
        if let cgImage = bestCGImage ?? fallbackImage {
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            return cropAndResize(nsImage: nsImage, targetSize: targetSize, compression: compression)
        }
        return nil
    }
    
    // 黒判定ロジック
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
        // 80%以上が暗ければ黒とみなす
        return Double(darkPixelCount) / Double(totalPixels) > 0.8
    }
    
    private func cropAndResize(nsImage: NSImage, targetSize: CGSize, compression: Double) -> Data? {
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        let originalSize = nsImage.size
        let dim = min(originalSize.width, originalSize.height)
        let x = (originalSize.width - dim) / 2
        let y = (originalSize.height - dim) / 2
        let cropRect = CGRect(x: x, y: y, width: dim, height: dim)
        nsImage.draw(in: CGRect(origin: .zero, size: targetSize), from: cropRect, operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        
        guard let tiff = newImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }
    
    private var placeholderData: Data {
        let img = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!
        return img.tiffRepresentation!
    }
}

// MARK: - Shared Data Models & MimeType
struct RemoteAlbumInfo: Codable { let id: String; let name: String; let videoCount: Int; let type: String? }
struct RemoteVideoInfo: Codable { let id: String; let filename: String; let duration: TimeInterval; let importDate: Date; let creationDate: Date?; let mediaType: String? }
private struct MimeType {
    static func forPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4": return "video/mp4"; case "mov": return "video/quicktime"; case "m4v": return "video/x-m4v"
        case "jpg", "jpeg": return "image/jpeg"; case "png": return "image/png"; case "heic": return "image/heic"; case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}
