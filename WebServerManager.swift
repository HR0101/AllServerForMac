import Foundation
import Swifter
import AVFoundation
import AppKit
import Darwin
import Combine

// ===================================
//  WebServerManager.swift (画質リクエスト対応版)
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
        
        server.post["/albums/create"] = { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            struct CreateReq: Codable { let name: String; let type: String }
            do {
                let req = try JSONDecoder().decode(CreateReq.self, from: Data(request.body))
                let albumType = AlbumType(rawValue: req.type) ?? .video
                DispatchQueue.main.async { dataManager.createAlbum(name: req.name, type: albumType) }
                return .ok(.text("Created"))
            } catch { return .badRequest(.text("Invalid request")) }
        }

        server.delete["/albums/:id"] = { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let idStr = request.params[":id"], let id = UUID(uuidString: idStr) else { return .badRequest(.text("Invalid ID")) }
            DispatchQueue.main.async { dataManager.deleteAlbum(albumID: id) }
            return .ok(.text("Deleted"))
        }

        server.post["/move"] = { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            struct MoveRequest: Codable { let videoIds: [String]; let sourceAlbumId: String; let targetAlbumId: String }
            do {
                let moveRequest = try JSONDecoder().decode(MoveRequest.self, from: Data(request.body))
                let videoUUIDs = moveRequest.videoIds.compactMap { UUID(uuidString: $0) }
                guard let sourceUUID = UUID(uuidString: moveRequest.sourceAlbumId),
                      let targetUUID = UUID(uuidString: moveRequest.targetAlbumId) else { return .badRequest(.text("Invalid IDs")) }
                DispatchQueue.main.async { dataManager.moveVideos(videoIDs: videoUUIDs, from: sourceUUID, to: targetUUID) }
                return .ok(.text("Moved successfully"))
            } catch { return .badRequest(.text("Invalid request body")) }
        }

        server.post["/deleteVideos"] = { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            struct DelRequest: Codable { let videoIds: [String]; let albumId: String }
            do {
                let req = try JSONDecoder().decode(DelRequest.self, from: Data(request.body))
                let videoUUIDs = req.videoIds.compactMap { UUID(uuidString: $0) }
                guard let albumUUID = UUID(uuidString: req.albumId) else { return .badRequest(.text("Invalid Album ID")) }
                DispatchQueue.main.async { dataManager.removeVideosFromAlbum(videoIDs: videoUUIDs, albumID: albumUUID) }
                return .ok(.text("Deleted successfully"))
            } catch { return .badRequest(.text("Invalid request body")) }
        }

        server.post["/upload"] = { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            
            let encodedFilename = request.headers["x-filename"] ?? "uploaded_media"
            let filename = encodedFilename.removingPercentEncoding ?? encodedFilename
            let albumIdStr = request.headers["x-album-id"] ?? ""
            
            let tempDir = FileManager.default.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + filename)
            
            let data = Data(request.body)
            do {
                try data.write(to: tempURL)
                
                let targetAlbumID: UUID
                if let aid = UUID(uuidString: albumIdStr) {
                    targetAlbumID = aid
                } else {
                    guard let allVideos = dataManager.albums.first(where: { $0.name == "ALL VIDEOS" }) else {
                        return .internalServerError
                    }
                    targetAlbumID = allVideos.id
                }
                
                DispatchQueue.main.async {
                    Task {
                        await dataManager.importMedia(from: tempURL, to: targetAlbumID, customFilename: filename)
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                }
                return .ok(.text("Upload successful"))
            } catch {
                return .internalServerError
            }
        }

        // ★ 動画再生ルート (iOSから指定された画質の動画を返す)
        server["/video/:id"] = { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let videoIDString = request.params[":id"],
                  let videoID = UUID(uuidString: videoIDString) else { return .notFound }
            
            // iOSから送られてくるクエリパラメータ "q" (画質) を取得。無ければ original
            let quality = request.queryParams.first(where: { $0.0 == "q" })?.1 ?? "original"
            
            var videoURL: URL?
            DispatchQueue.main.sync {
                if let videoItem = dataManager.videos.first(where: { $0.id == videoID }) {
                    // 要求された画質に応じてプロキシを探す
                    if quality == "1080p" {
                        let proxyURL = dataManager.proxyStorageURL.appendingPathComponent("\(videoIDString)_1080p.mp4")
                        if FileManager.default.fileExists(atPath: proxyURL.path) {
                            videoURL = proxyURL
                        }
                    } else if quality == "540p" {
                        let proxyURL = dataManager.proxyStorageURL.appendingPathComponent("\(videoIDString)_540p.mp4")
                        if FileManager.default.fileExists(atPath: proxyURL.path) {
                            videoURL = proxyURL
                        }
                    }
                    
                    // 指定の画質が存在しない、または original の場合は元ファイルを返す
                    if videoURL == nil {
                        videoURL = dataManager.fileURL(for: videoItem)
                    }
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
                    videoFileUrl = dataManager.fileURL(for: item)
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

    private func generateVideoThumbnail(url: URL, targetSize: CGSize, compression: Double) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        
        var attempts: [Double] = [1.0, 3.0, 5.0, 10.0, 20.0, 30.0, 60.0]
        
        if duration < 5 {
            attempts.insert(0.0, at: 0)
        }
        
        let validAttempts = attempts.filter { $0 < duration }
        
        var bestCGImage: CGImage? = nil
        var fallbackImage: CGImage? = nil
        
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
        
        if let cgImage = bestCGImage ?? fallbackImage {
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            return cropAndResize(nsImage: nsImage, targetSize: targetSize, compression: compression)
        }
        return nil
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
