import Foundation
import Swifter
import AVFoundation
import AppKit
import Darwin
import Combine

// ===================================
//  WebServerManager.swift (アルバムタイプ配信対応)
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
        
        // --- 1. アルバム一覧 ---
        server["/albums"] = { [weak self] _ -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else {
                return .internalServerError
            }
            
            var albumInfos: [RemoteAlbumInfo] = []
            DispatchQueue.main.sync {
                albumInfos = dataManager.albums.map {
                    // ★ 修正: アルバムタイプを含める
                    RemoteAlbumInfo(id: $0.id.uuidString,
                                    name: $0.name,
                                    videoCount: $0.videoIDs.count,
                                    type: $0.type.rawValue)
                }
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
        
        // --- 2. アルバム内のビデオ一覧 ---
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
            } catch {
                return .internalServerError
            }
        }
        
        // --- 3. ビデオの移動 ---
        server.post["/move"] = { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            
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

        // --- 4. ビデオ/画像のストリーミング・ダウンロード ---
        server["/video/:id"] = { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let videoIDString = request.params[":id"],
                  let videoID = UUID(uuidString: videoIDString) else {
                return .notFound
            }
            
            var videoURL: URL?
            DispatchQueue.main.sync {
                if let videoItem = dataManager.videos.first(where: { $0.id == videoID }) {
                    videoURL = dataManager.videoStorageURL.appendingPathComponent(videoItem.internalFilename)
                }
            }
            
            guard let url = videoURL else { return .notFound }
            
            return self.serveFile(at: url, request: request)
        }
        
        // --- 5. サムネイル取得 ---
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
            
            Task {
                if let thumbnailData = await self.generateThumbnailData(for: fileUrl, type: item.mediaType, quality: .high) {
                    try? thumbnailData.write(to: thumbnailURL)
                }
            }
            
            return .ok(.data(self.placeholderData, contentType: "image/jpeg"))
        }
        
        print("✅ [SETUP] API routes configured.")
    }
    
    // MARK: - Server Control
    func startServer() {
        guard !server.operating else {
            print("⚠️ [WARN] Server is already running.")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
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

    @objc func stopServer() {
        stopServerInternal()
    }
    
    private func stopServerInternal() {
        print("🛑 [STOP] 1/2: Stopping Bonjour service...")
        netService?.stop()
        netService = nil
        
        print("🛑 [STOP] 2/2: Stopping HTTP server...")
        server.stop()
        
        if Thread.isMainThread {
            statusMessage = "🛑 サーバー停止"
        } else {
            DispatchQueue.main.async {
                self.statusMessage = "🛑 サーバー停止"
            }
        }
        print("✅ [STOP] Server shutdown complete.")
    }
    
    @objc private func handleSessionOrAppTermination() {
        print("👋 [LIFECYCLE] Session/App is ending. Stopping server.")
        stopServerInternal()
    }
    
    // MARK: - NetServiceDelegate
    func netServiceDidPublish(_ sender: NetService) {
        let ipAddress = getIPAddress() ?? "N/A"
        let successMessage = "✅ 実行中: http://\(ipAddress):\(sender.port)"
        print("✅ [SUCCESS] \(successMessage)")
        self.statusMessage = successMessage
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        let errorCode = errorDict[NetService.errorCode] ?? -1
        let errorMessage = "❌ Bonjour publish failed. Code: \(errorCode)"
        print(errorMessage)
        self.statusMessage = errorMessage
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
                ], { writer in
                    try? writer.write(data)
                })
            } else {
                // 画像などの一括ダウンロード
                let data = try Data(contentsOf: url)
                return .ok(.data(data, contentType: mime))
            }
        } catch {
            print("Server Error during file serve: \(error)")
            return .internalServerError
        }
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
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        
        if let cgImage = try? await generator.image(at: time).image {
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            return cropAndResize(nsImage: nsImage, targetSize: targetSize, compression: compression)
        }
        return nil
    }
    
    private func cropAndResize(nsImage: NSImage, targetSize: CGSize, compression: Double) -> Data? {
        let originalSize = nsImage.size
        let dim = min(originalSize.width, originalSize.height)
        let x = (originalSize.width - dim) / 2
        let y = (originalSize.height - dim) / 2
        let cropRect = CGRect(x: x, y: y, width: dim, height: dim)
        
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
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

// ★ 修正: アルバムタイプを受け渡しするための構造体更新
struct RemoteAlbumInfo: Codable {
    let id: String
    let name: String
    let videoCount: Int
    // ★ 追加
    let type: String?
}

struct RemoteVideoInfo: Codable {
    let id: String
    let filename: String
    let duration: TimeInterval
    let importDate: Date
    let creationDate: Date?
    let mediaType: String?
}

private struct MimeType {
    static func forPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}
