import AppKit
import Foundation
import MediaServerKit
import Swifter

extension WebServerManager {
    // MARK: - API Routes
    func setupRoutes() {
        
        server["/"] = { [weak self] request -> HttpResponse in
            self?.logAccess(request, authorized: true)
            return .ok(.html(WebClientHTML.page))
        }
        
        server["/albums"] = protected { [weak self] _ -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            var albumInfos: [RemoteAlbumInfo] = []
            DispatchQueue.main.sync {
                let trashedIDs = Set(dataManager.videos.filter { $0.isInTrash }.map { $0.id })
                albumInfos = dataManager.albums.map { album in
                    let validVideos = album.videoIDs.filter { !trashedIDs.contains($0) }
                    return RemoteAlbumInfo(id: album.id.uuidString, name: album.name, videoCount: validVideos.count, type: album.type.rawValue, coverVideoID: validVideos.first?.uuidString)
                }
                
                let faceAlbums = FaceDatabase.shared.getAlbums()
                albumInfos += faceAlbums.map { album in
                    let validVideos = album.videoIDs.filter { !trashedIDs.contains($0) }
                    return RemoteAlbumInfo(id: album.id.uuidString, name: album.name, videoCount: validVideos.count, type: album.type.rawValue, coverVideoID: validVideos.first?.uuidString)
                }
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                let jsonData = try encoder.encode(albumInfos)
                return .ok(.data(jsonData, contentType: "application/json"))
            } catch { return .internalServerError }
        }
        
        server["/albums/:id/videos"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            guard let albumIDString = request.params[":id"], let albumID = UUID(uuidString: albumIDString) else {
                return .badRequest(.text("Invalid album ID"))
            }
            var videoInfos: [RemoteVideoInfo] = []
            var found = false
            DispatchQueue.main.sync {
                let allAlbums = dataManager.albums + FaceDatabase.shared.getAlbums()
                if let album = allAlbums.first(where: { $0.id == albumID }) {
                    found = true
                    let videoItems = dataManager.videos.filter { album.videoIDs.contains($0.id) && !$0.isInTrash }
                    videoInfos = videoItems.map { video in
                        let customAlbum = dataManager.albums.first { a in
                            a.name != VideoDataManager.allVideosAlbumName &&
                            a.name != VideoDataManager.allPhotosAlbumName &&
                            a.videoIDs.contains(video.id)
                        }
                        return RemoteVideoInfo(
                            id: video.id.uuidString,
                            filename: video.originalFilename,
                            duration: video.duration,
                            importDate: video.importDate,
                            creationDate: video.creationDate,
                            mediaType: video.mediaType.rawValue,
                            parentAlbumID: customAlbum?.id.uuidString
                        )
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
        
        server["/server/status"] = protected { [weak self] _ -> HttpResponse in
            var uptime = 0
            DispatchQueue.main.sync {
                if let start = self?.serverStartTime {
                    uptime = Int(Date().timeIntervalSince(start))
                }
            }
            struct StatusData: Codable { let uptime: Int }
            if let data = try? JSONEncoder().encode(StatusData(uptime: uptime)) {
                return .ok(.data(data, contentType: "application/json"))
            }
            return .internalServerError
        }

        server.post["/server/shutdown"] = protected { [weak self] _ -> HttpResponse in
            DispatchQueue.main.async {
                self?.stopServerInternal()
                NSApplication.shared.terminate(nil)
            }
            return .ok(.text("Shutdown initiated"))
        }
        
        server.post["/albums/create"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            struct CreateReq: Codable { let name: String; let type: String }
            do {
                let req = try JSONDecoder().decode(CreateReq.self, from: Data(request.body))
                let albumType = AlbumType(rawValue: req.type) ?? .video
                DispatchQueue.main.async { dataManager.createAlbum(name: req.name, type: albumType) }
                return .ok(.text("Created"))
            } catch { return .badRequest(.text("Invalid request")) }
        }

        server.delete["/albums/:id"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let idStr = request.params[":id"], let id = UUID(uuidString: idStr) else { return .badRequest(.text("Invalid ID")) }
            DispatchQueue.main.async { dataManager.deleteAlbum(albumID: id) }
            return .ok(.text("Deleted"))
        }

        server.post["/move"] = protected { [weak self] request -> HttpResponse in
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

        server.post["/deleteVideos"] = protected { [weak self] request -> HttpResponse in
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

        server.post["/upload"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            
            // サイズ上限の確認（Swifter はボディを全展開済みなので、ここではディスク書き込みを防ぐ）
            guard request.body.count <= self.maxUploadBytes else {
                return .raw(413, "Payload Too Large", ["Content-Type": "text/plain"], { try? $0.write(Array("File too large".utf8)) })
            }

            // X-Filename をサニタイズ（パストラバーサル・不正拡張子を排除）
            let encodedFilename = request.headers["x-filename"] ?? ""
            let rawFilename = encodedFilename.removingPercentEncoding ?? encodedFilename
            guard let filename = UploadFilename.sanitize(rawFilename) else {
                return .badRequest(.text("Invalid filename"))
            }
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
                    guard let allVideos = dataManager.albums.first(where: { $0.name == VideoDataManager.allVideosAlbumName }) else {
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

        server["/video/:id"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let videoIDString = request.params[":id"],
                  let videoID = UUID(uuidString: videoIDString) else { return .notFound }
            
            let quality = request.queryParams.first(where: { $0.0 == "q" })?.1 ?? "original"
            
            var extPath: String?
            var internalFilename = ""
            var videoStorageURL: URL?
            var downloadStorageURL: URL?
            var proxyStorageURL: URL?
            
            DispatchQueue.main.sync {
                if let videoItem = dataManager.videos.first(where: { $0.id == videoID }) {
                    extPath = videoItem.externalFilePath
                    internalFilename = videoItem.internalFilename
                    videoStorageURL = dataManager.videoStorageURL
                    downloadStorageURL = dataManager.downloadStorageURL
                    proxyStorageURL = dataManager.proxyStorageURL
                }
            }
            
            guard let vURL = videoStorageURL, let dURL = downloadStorageURL, let pURL = proxyStorageURL else { return .notFound }
            
            var videoURL: URL?
            if quality == "1080p" {
                let proxyURL = pURL.appendingPathComponent("\(videoIDString)_1080p.mp4")
                if FileManager.default.fileExists(atPath: proxyURL.path) { videoURL = proxyURL }
            } else if quality == "540p" {
                let proxyURL = pURL.appendingPathComponent("\(videoIDString)_540p.mp4")
                if FileManager.default.fileExists(atPath: proxyURL.path) { videoURL = proxyURL }
            }
            
            if videoURL == nil {
                if let path = extPath {
                    let extURL = URL(fileURLWithPath: path)
                    if FileManager.default.fileExists(atPath: extURL.path) { videoURL = extURL }
                }
                if videoURL == nil && !internalFilename.isEmpty {
                    let hiddenURL = vURL.appendingPathComponent(internalFilename)
                    if FileManager.default.fileExists(atPath: hiddenURL.path) { videoURL = hiddenURL }
                    else {
                        let downloadURL = dURL.appendingPathComponent(internalFilename)
                        if FileManager.default.fileExists(atPath: downloadURL.path) { videoURL = downloadURL }
                    }
                }
            }
            guard let url = videoURL else { return .notFound }
            return self.serveFile(at: url, request: request)
        }

        server["/video/:id/prepare"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let idStr = request.params[":id"] else { return .notFound }
            let quality = request.queryParams.first(where: { $0.0 == "q" })?.1 ?? "1080p"
            var state = "generating"
            var progress = 0.0
            DispatchQueue.main.sync {
                if dataManager.isProxyReady(videoID: idStr, quality: quality) {
                    state = "ready"
                } else if let p = dataManager.proxyGenerationProgress(videoID: idStr, quality: quality) {
                    state = "generating"; progress = p
                } else {
                    dataManager.startOnDemandProxy(videoID: idStr, quality: quality)
                    state = "generating"; progress = 0
                }
            }
            struct PrepareResp: Codable { let state: String; let progress: Double }
            if let data = try? JSONEncoder().encode(PrepareResp(state: state, progress: progress)) {
                return .ok(.data(data, contentType: "application/json"))
            }
            return .internalServerError
        }

        server.delete["/video/:id/proxy"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            DispatchQueue.main.async { dataManager.deleteAllProxies() }
            return .ok(.text("Deleted"))
        }

        server["/thumbnail/:id"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let videoIDString = request.params[":id"],
                  let videoID = UUID(uuidString: videoIDString) else { return .notFound }
            
            let isOriginal = request.queryParams.contains(where: { $0.0 == "original" && $0.1 == "true" })
            let timeString = request.queryParams.first(where: { $0.0 == "time" })?.1
            let timeParam = timeString.flatMap { Double($0) }
            
            let fileName: String
            if let t = timeParam {
                fileName = "\(videoIDString)_t\(Int(t)).jpg"
            } else {
                fileName = isOriginal ? "\(videoIDString)_original.jpg" : "\(videoIDString).jpg"
            }
            let thumbnailURL = dataManager.thumbnailStorageURL.appendingPathComponent(fileName)

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
                if let data = await self.generateThumbnailData(for: fileUrl, type: item.mediaType, quality: .high, isOriginal: isOriginal, requestedTime: timeParam) {
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
    
}
