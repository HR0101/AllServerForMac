import Foundation
import Swifter
import AVFoundation
import AppKit
import Darwin
import Combine

// ===================================
//  WebServerManager.swift (最終修正・安定版)
// ===================================
@MainActor
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
        guard let dataManager = dataManager else {
            print("❌ [FATAL] DataManager is nil during setupRoutes. This should not happen.")
            return
        }
        
        server["/albums"] = { _ in
            let albumInfos = dataManager.albums.map {
                RemoteAlbumInfo(id: $0.id.uuidString, name: $0.name, videoCount: $0.videoIDs.count)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                let jsonData = try encoder.encode(albumInfos)
                return .ok(.data(jsonData, contentType: "application/json"))
            } catch {
                return .internalServerError
            }
        }
        
        server["/albums/:id/videos"] = { request in
            guard let albumIDString = request.params[":id"], let albumID = UUID(uuidString: albumIDString) else {
                return .badRequest(.text("Invalid album ID"))
            }
            guard let album = dataManager.albums.first(where: { $0.id == albumID }) else {
                return .notFound
            }
            let videoItems = dataManager.videos.filter { album.videoIDs.contains($0.id) }
            let videoInfos = videoItems.map {
                RemoteVideoInfo(id: $0.id.uuidString,
                                filename: $0.originalFilename,
                                duration: $0.duration,
                                importDate: $0.importDate,
                                creationDate: $0.creationDate)
            }
            
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let jsonData = try encoder.encode(videoInfos)
                return .ok(.data(jsonData, contentType: "application/json"))
            } catch {
                print("❌ Failed to encode video list: \(error)")
                return .internalServerError
            }
        }
        
        server.post["/move"] = { request in
            struct MoveRequest: Codable {
                let videoIds: [String]
                let targetAlbumId: String
            }
            
            do {
                let moveRequest = try JSONDecoder().decode(MoveRequest.self, from: Data(request.body))
                let videoUUIDs = moveRequest.videoIds.compactMap { UUID(uuidString: $0) }
                guard let targetAlbumUUID = UUID(uuidString: moveRequest.targetAlbumId) else {
                    return .badRequest(.text("Invalid target album ID"))
                }
                
                DispatchQueue.main.async {
                    dataManager.moveVideos(videoIDs: videoUUIDs, to: targetAlbumUUID)
                }
                
                return .ok(.text("Move successful"))
            } catch {
                return .badRequest(.text("Invalid request body"))
            }
        }

        server["/video/:id"] = { [weak self] request in
            guard let self = self, let dataManager = self.dataManager,
                  let videoIDString = request.params[":id"],
                  let videoID = UUID(uuidString: videoIDString) else {
                return .notFound
            }
            
            guard let videoItem = dataManager.videos.first(where: { $0.id == videoID }) else {
                return .notFound
            }
            
            let videoURL = dataManager.videoStorageURL.appendingPathComponent(videoItem.internalFilename)
            
            do {
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: videoURL.path)
                guard let totalFileSize = fileAttributes[.size] as? UInt64 else {
                    return .internalServerError
                }
                
                let contentType = MimeType.forPath(videoURL.path)
                
                if let rangeHeader = request.headers["range"], let range = self.parseRangeHeader(rangeHeader, totalSize: totalFileSize) {
                    let (start, end) = range
                    let length = end - start + 1
                    
                    let fileHandle = try FileHandle(forReadingFrom: videoURL)
                    defer { fileHandle.closeFile() }
                    
                    try fileHandle.seek(toOffset: start)
                    let dataChunk = fileHandle.readData(ofLength: Int(length))
                    
                    let headers: [String: String] = [
                        "Content-Type": contentType, "Content-Length": String(length),
                        "Content-Range": "bytes \(start)-\(end)/\(totalFileSize)", "Accept-Ranges": "bytes"
                    ]
                    
                    return .raw(206, "Partial Content", headers, { writer in try? writer.write(dataChunk) })
                } else {
                    let headers: [String: String] = [
                        "Content-Type": contentType, "Content-Length": String(totalFileSize), "Accept-Ranges": "bytes"
                    ]
                    return .raw(200, "OK", headers, { writer in
                        if let file = try? videoURL.path.openForReading() {
                            try? writer.write(file)
                            file.close()
                        }
                    })
                }
            } catch {
                return .internalServerError
            }
        }
        
        server["/thumbnail/:id"] = { [weak self] request in
            guard let self = self, let dataManager = self.dataManager,
                  let videoIDString = request.params[":id"],
                  let videoID = UUID(uuidString: videoIDString) else { return .notFound }
            
            let thumbnailURL = dataManager.thumbnailStorageURL.appendingPathComponent(videoIDString).appendingPathExtension("jpg")

            if let cachedData = try? Data(contentsOf: thumbnailURL) {
                return .ok(.data(cachedData, contentType: "image/jpeg"))
            }
            
            guard let videoItem = dataManager.videos.first(where: { $0.id == videoID }) else { return .notFound }
            let videoURL = dataManager.videoStorageURL.appendingPathComponent(videoItem.internalFilename)
            
            Task {
                if let thumbnailData = await self.generateThumbnailData(for: videoURL, quality: .high) {
                    try? thumbnailData.write(to: thumbnailURL)
                }
            }
            
            let placeholderImage = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil)!
            if let tiff = placeholderImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                let data = bitmap.representation(using: .jpeg, properties: [:])!
                return .ok(.data(data, contentType: "image/jpeg"))
            }
            return .internalServerError
        }
        
        server["/placeholder/:id"] = { [weak self] request in
            guard let self = self, let dataManager = self.dataManager,
                  let videoIDString = request.params[":id"],
                  let videoID = UUID(uuidString: videoIDString) else { return .notFound }

            let placeholderURL = dataManager.thumbnailStorageURL.appendingPathComponent("\(videoIDString)_lq").appendingPathExtension("jpg")

            if let cachedData = try? Data(contentsOf: placeholderURL) {
                return .ok(.data(cachedData, contentType: "image/jpeg"))
            }

            guard let videoItem = dataManager.videos.first(where: { $0.id == videoID }) else { return .notFound }
            let videoURL = dataManager.videoStorageURL.appendingPathComponent(videoItem.internalFilename)

            Task {
                if let placeholderData = await self.generateThumbnailData(for: videoURL, quality: .low) {
                    try? placeholderData.write(to: placeholderURL)
                }
            }
            
            let placeholderImage = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil)!
            if let tiff = placeholderImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                let data = bitmap.representation(using: .jpeg, properties: [:])!
                return .ok(.data(data, contentType: "image/jpeg"))
            }
            return .internalServerError
        }
        print("✅ [SETUP] API routes configured.")
    }
    
    // MARK: - Server Control
    func startServer() {
        guard !server.operating else {
            print("⚠️ [WARN] Server is already running.")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                print("📝 [START] 1/3: Attempting to start HTTP server on a random port.")
                try self.server.start(0, forceIPv4: true)
                
                let actualPort = try self.server.port()
                print("✅ [START] 1/3: HTTP server started successfully on port \(actualPort).")
                
                DispatchQueue.main.async {
                    print("📝 [START] 2/3: Setting up Bonjour service on main thread.")
                    
                    guard let computerName = Host.current().localizedName else {
                        let errorMsg = "❌ [FATAL] Could not get computer name."
                        print(errorMsg)
                        self.statusMessage = errorMsg
                        self.server.stop()
                        return
                    }
                    
                    let userName = NSUserName()
                    let uniqueServiceName = "\(computerName) (\(userName))"
                    
                    self.netService = NetService(domain: "local.", type: "_myvideoserver._tcp.", name: uniqueServiceName, port: Int32(actualPort))
                    self.netService?.delegate = self
                    
                    print("📝 [START] 3/3: Publishing Bonjour service: \(uniqueServiceName)")
                    // ★ 修正: .listenForConnections オプションを削除
                    self.netService?.publish()
                }
                
            } catch {
                let errorMessage = "❌ [FATAL] Server start failed: \(error.localizedDescription)"
                print(errorMessage)
                DispatchQueue.main.async {
                    self.statusMessage = errorMessage
                }
            }
        }
    }

    func stopServer() {
        print("🛑 [STOP] 1/2: Stopping Bonjour service...")
        netService?.stop()
        netService = nil
        
        print("🛑 [STOP] 2/2: Stopping HTTP server...")
        server.stop()
        
        statusMessage = "🛑 サーバー停止"
        print("✅ [STOP] Server shutdown complete.")
    }
    
    @objc private func handleSessionOrAppTermination() {
        print("👋 [LIFECYCLE] Session/App is ending. Stopping server.")
        stopServer()
    }
    
    // MARK: - NetServiceDelegate
    func netServiceDidPublish(_ sender: NetService) {
        let ipAddress = getIPAddress() ?? "N/A"
        let successMessage = "✅ サーバー実行中 at http://\(ipAddress):\(sender.port)"
        print("✅ [SUCCESS] \(successMessage)")
        self.statusMessage = successMessage
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        let errorCode = errorDict[NetService.errorCode] ?? -1
        let errorDomain = errorDict[NetService.errorDomain] ?? -1
        let errorMessage = "❌ [FATAL] Bonjour publish failed. Code: \(errorCode), Domain: \(errorDomain). Check Multicast entitlement and Info.plist."
        print(errorMessage)
        self.statusMessage = errorMessage
        self.server.stop()
    }
    
    // (他のヘルパー関数やデータモデルは変更なし)
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
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        let ip = String(cString: hostname)
                        if !ip.isEmpty {
                            address = ip
                            break
                        }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
    
    private enum ThumbnailQuality { case high, low }
    private func parseRangeHeader(_ header: String, totalSize: UInt64) -> (UInt64, UInt64)? {
        guard header.hasPrefix("bytes="), totalSize > 0 else { return nil }
        let components = header.dropFirst(6).split(separator: "-")
        guard let startString = components.first, let start = UInt64(startString) else { return nil }
        let end = (components.count > 1 && !components[1].isEmpty) ? min(UInt64(components[1]) ?? 0, totalSize - 1) : totalSize - 1
        if start > end { return nil }
        return (start, end)
    }
    private func generateThumbnailData(for videoURL: URL, quality: ThumbnailQuality) async -> Data? {
        let asset = AVURLAsset(url: videoURL)
        let (targetSize, compression): (CGSize, CGFloat) = quality == .high ? (CGSize(width: 400, height: 400), 0.8) : (CGSize(width: 50, height: 50), 0.1)
        guard let cgImage = await generateBestCGImage(for: asset) else { return nil }
        let originalWidth = CGFloat(cgImage.width)
        let originalHeight = CGFloat(cgImage.height)
        let squareSize = min(originalWidth, originalHeight)
        let cropRect = CGRect(x: (originalWidth - squareSize) / 2.0, y: (originalHeight - squareSize) / 2.0, width: squareSize, height: squareSize)
        guard let croppedCgImage = cgImage.cropping(to: cropRect) else { return nil }
        guard let context = CGContext(data: nil, width: Int(targetSize.width), height: Int(targetSize.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(croppedCgImage, in: CGRect(origin: .zero, size: targetSize))
        guard let resizedCgImage = context.makeImage() else { return nil }
        let nsImage = NSImage(cgImage: resizedCgImage, size: targetSize)
        guard let tiffRepresentation = nsImage.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else { return nil }
        return bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }
    private func generateBestCGImage(for asset: AVAsset) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let maxAttempts = 5
        let retryTimeOffset: Double = 2.0
        let initialTime = CMTime(seconds: 1.0, preferredTimescale: 600)
        for attempt in 0..<maxAttempts {
            let attemptTime = CMTimeAdd(initialTime, CMTime(seconds: Double(attempt) * retryTimeOffset, preferredTimescale: 600))
            do {
                let cgImage = try await generator.image(at: attemptTime).image
                if !isImagePredominantlyBlack(image: cgImage) { return cgImage }
            } catch { print("Thumbnail generation failed at \(attemptTime.seconds)s: \(error.localizedDescription)") }
        }
        return try? await generator.image(at: initialTime).image
    }
    private func isImagePredominantlyBlack(image: CGImage, darknessThreshold: UInt8 = 30, percentageThreshold: Double = 0.95) -> Bool {
        guard let pixelData = image.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else { return false }
        let width = image.width
        let height = image.height
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return false }
        var darkPixelCount = 0
        let totalPixels = width * height
        let step = max(1, totalPixels / 10000)
        let sampleTotal = totalPixels / step
        for i in stride(from: 0, to: totalPixels, by: step) {
            let offset = (i / width * image.bytesPerRow) + (i % width * bytesPerPixel)
            if data[offset] < darknessThreshold && data[offset + 1] < darknessThreshold && data[offset + 2] < darknessThreshold {
                darkPixelCount += 1
            }
        }
        return Double(darkPixelCount) / Double(sampleTotal) >= percentageThreshold
    }
}

// MARK: - Shared Data Models & MimeType
struct RemoteAlbumInfo: Codable { let id: String; let name: String; let videoCount: Int }
struct RemoteVideoInfo: Codable {
    let id: String
    let filename: String
    let duration: TimeInterval
    let importDate: Date
    let creationDate: Date?
}
private struct MimeType {
    static func forPath(_ path: String) -> String {
        if path.hasSuffix(".mp4") { return "video/mp4" }
        if path.hasSuffix(".mov") { return "video/quicktime" }
        if path.hasSuffix(".m4v") { return "video/x-m4v" }
        return "application/octet-stream"
    }
}

