import AppKit
import Foundation
import MediaServerKit
import Swifter

extension ServerViewModel {
    // MARK: - API Routes
    func setupRoutes() {

        server["/"] = { [weak self] request -> HttpResponse in
            self?.logAccess(request, authorized: true)
            return .ok(.html(WebClientHTML.page))
        }

        server["/manifest.webmanifest"] = { [weak self] request -> HttpResponse in
            self?.logAccess(request, authorized: true)
            let headers = [
                "Content-Type": "application/manifest+json; charset=utf-8",
                "Cache-Control": "no-cache"
            ]
            return .raw(200, "OK", headers, { writer in
                try? writer.write(Data(WebClientHTML.manifest.utf8))
            })
        }

        server["/pwa-icon.png"] = { [weak self] request -> HttpResponse in
            guard let self, !self.pwaIconData.isEmpty else { return .notFound }
            self.logAccess(request, authorized: true)
            let headers = [
                "Content-Type": "image/png",
                "Cache-Control": "public, max-age=86400"
            ]
            return .raw(200, "OK", headers, { writer in
                try? writer.write(self.pwaIconData)
            })
        }

        server["/albums"] = protected { [weak self] _ -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            // メインスレッドを経由せずスナップショットから応答する。
            // Mac UI が忙しくても応答が遅れず、リクエストラッシュが UI を乱すこともない。
            let snapshot = dataManager.snapshotLibrary.value
            let trashedIDs = Set(snapshot.videos.filter { $0.isInTrash }.map { $0.id })
            let allAlbums = snapshot.albums
            let albumInfos = allAlbums.map { album in
                let validVideos = album.videoIDs.filter { !trashedIDs.contains($0) }
                return RemoteAlbumInfo(id: album.id.uuidString, name: album.name, videoCount: validVideos.count, type: album.type.rawValue, coverVideoID: validVideos.first?.uuidString)
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
            // スナップショットから応答（メインスレッド非経由）
            let snapshot = dataManager.snapshotLibrary.value
            let albums = snapshot.albums
            guard let album = albums.first(where: { $0.id == albumID }) else { return .notFound }

            let memberIDs = Set(album.videoIDs)
            let videoItems = snapshot.videos.filter { memberIDs.contains($0.id) && !$0.isInTrash }

            // 動画ごとの「カスタムアルバム」を1回の走査で構築（各アルバム内で最初に見つかったものを優先＝albums の順序を保つ）
            var customAlbumByVideoID: [UUID: Album] = [:]
            for a in albums where a.name != LibraryViewModel.allVideosAlbumName && a.name != LibraryViewModel.allPhotosAlbumName {
                for vid in a.videoIDs where customAlbumByVideoID[vid] == nil {
                    customAlbumByVideoID[vid] = a
                }
            }

            // 並べ替え「サイズ/変更日/最後に開いた日」用に実ファイル属性を読む。
            // Mac 側の一覧と同じキャッシュ（LibraryViewModel.fileMetadata）を共有するので、
            // アルバムを開くたびにメディア全件を stat し直すことはない。
            let videoInfos = videoItems.map { video -> RemoteVideoInfo in
                let meta = dataManager.fileMetadata(for: video)
                return RemoteVideoInfo(
                    id: video.id.uuidString,
                    filename: video.originalFilename,
                    duration: video.duration,
                    importDate: video.importDate,
                    creationDate: video.creationDate,
                    mediaType: video.mediaType.rawValue,
                    parentAlbumID: customAlbumByVideoID[video.id]?.id.uuidString,
                    fileSize: meta.size,
                    modificationDate: meta.modificationDate,
                    accessDate: meta.accessDate
                )
            }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let jsonData = try encoder.encode(videoInfos)
                return .ok(.data(jsonData, contentType: "application/json"))
            } catch { return .internalServerError }
        }

        // 差分動画の探索。実ファイルを持っているのは Mac だけなので検出はここで行い、
        // クライアントには結果（どの動画が同じ束か）だけを渡す。
        // 指紋づくりに時間がかかるぶんは `/video/:id/prepare` と同じく、
        // 「いまわかっていること＋進み具合」を返して繰り返し尋ねてもらう。
        server["/albums/:id/variants"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let albumIDString = request.params[":id"], let albumID = UUID(uuidString: albumIDString) else {
                return .badRequest(.text("Invalid album ID"))
            }
            func number(_ name: String, _ fallback: Double) -> Double {
                guard let raw = request.queryParams.first(where: { $0.0 == name })?.1,
                      let value = Double(raw) else { return fallback }
                return value
            }

            // スナップショットから組み立てる（メインスレッド非経由）。
            let snapshot = dataManager.snapshotLibrary.value
            guard let album = snapshot.albums.first(where: { $0.id == albumID }) else { return .notFound }
            let memberIDs = Set(album.videoIDs)
            let videos = snapshot.videos.filter {
                memberIDs.contains($0.id) && !$0.isInTrash && $0.mediaType == .video
            }

            let targets: [VariantScanService.Target] = videos.compactMap { item in
                guard let url = LibraryViewModel.resolveFileURL(
                    for: item,
                    videoStorageURL: dataManager.videoStorageURL,
                    downloadStorageURL: dataManager.downloadStorageURL
                ) else { return nil }
                let meta = dataManager.fileMetadata(for: item)
                return VariantScanService.Target(
                    item: item,
                    url: url,
                    stamp: VariantSignatureStore.Stamp(size: meta.size, modified: meta.modificationDate)
                )
            }

            let result = self.variantScanner.result(
                albumID: albumID,
                targets: targets,
                tolerance: number("tolerance", 0.2),
                maxAverageDistance: number("distance", 10),
                titleInfluence: number("title", 4)
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(result) else { return .internalServerError }
            return .ok(.data(data, contentType: "application/json"))
        }

        server["/server/status"] = protected { [weak self] _ -> HttpResponse in
            var uptime = 0
            if let start = self?.snapshotServerStartTime.value {
                uptime = Int(Date().timeIntervalSince(start))
            }
            // Swifter はボディを全てメモリへ展開してからハンドラを呼ぶため、サーバー側の
            // サイズチェックはメモリ枯渇を防げない。クライアントがアップロード前に
            // 自分でサイズ判定できるよう、上限を公開しておく。
            struct StatusData: Codable { let uptime: Int; let maxUploadBytes: Int }
            let status = StatusData(uptime: uptime, maxUploadBytes: self?.maxUploadBytes ?? 0)
            if let data = try? JSONEncoder().encode(status) {
                return .ok(.data(data, contentType: "application/json"))
            }
            return .internalServerError
        }

        server["/remote/playback"] = protected { [weak self] _ -> HttpResponse in
            guard let self else { return .internalServerError }
            guard let data = try? JSONEncoder().encode(self.remotePlaybackSession.snapshot.value) else {
                return .internalServerError
            }
            return .ok(.data(data, contentType: "application/json"))
        }

        server.post["/remote/playback/open"] = protected { [weak self] request -> HttpResponse in
            guard let self, let dataManager = self.dataManager else { return .internalServerError }
            guard let openRequest = try? JSONDecoder().decode(
                RemotePlaybackOpenRequest.self,
                from: Data(request.body)
            ), let videoID = UUID(uuidString: openRequest.videoID) else {
                return .badRequest(.text("Invalid request body"))
            }

            let snapshot = dataManager.snapshotLibrary.value
            guard let current = snapshot.videos.first(where: {
                $0.id == videoID && !$0.isInTrash && $0.mediaType == .video
            }) else {
                return .notFound
            }

            let requestedAlbumID = openRequest.albumID.flatMap(UUID.init(uuidString:))
            let requestedAlbum = requestedAlbumID.flatMap { albumID in
                snapshot.albums.first(where: { $0.id == albumID })
            }
            let defaultAlbum = snapshot.albums.first(where: {
                $0.name == LibraryViewModel.allVideosAlbumName
            })
            let sourceAlbum = requestedAlbum ?? defaultAlbum
            let videosByID = Dictionary(uniqueKeysWithValues: snapshot.videos.map { ($0.id, $0) })
            var playlist = sourceAlbum?.videoIDs.compactMap { videosByID[$0] }.filter {
                !$0.isInTrash && $0.mediaType == .video
            } ?? []
            if !playlist.contains(current) {
                playlist.append(current)
            }

            DispatchQueue.main.sync {
                self.remotePlaybackSession.open(playlist: playlist, current: current)
            }
            return .ok(.text("Opened"))
        }

        server.post["/remote/playback/command"] = protected { [weak self] request -> HttpResponse in
            guard let self else { return .internalServerError }
            guard let command = try? JSONDecoder().decode(
                RemotePlaybackCommandRequest.self,
                from: Data(request.body)
            ) else {
                return .badRequest(.text("Invalid request body"))
            }

            let handled = DispatchQueue.main.sync {
                self.remotePlaybackSession.perform(command)
            }
            guard handled else {
                return .raw(409, "Conflict", ["Content-Type": "text/plain"], { writer in
                    try? writer.write(Data("No active player or invalid command".utf8))
                })
            }
            guard let data = try? JSONEncoder().encode(self.remotePlaybackSession.snapshot.value) else {
                return .internalServerError
            }
            return .ok(.data(data, contentType: "application/json"))
        }

        server.post["/server/shutdown"] = protectedDestructive { [weak self] _ -> HttpResponse in
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
                // 予約(async)だけして即OKを返すと、直後の一覧取得に反映前の状態が返る。
                // 変更系は低頻度なので、メインスレッドでの反映完了を待ってから応答する。
                _ = DispatchQueue.main.sync { dataManager.createAlbum(name: req.name, type: albumType) }
                return .ok(.text("Created"))
            } catch { return .badRequest(.text("Invalid request")) }
        }

        server.delete["/albums/:id"] = protectedDestructive { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let idStr = request.params[":id"], let id = UUID(uuidString: idStr) else { return .badRequest(.text("Invalid ID")) }
            let snapshot = dataManager.snapshotLibrary.value
            guard let album = snapshot.albums.first(where: { $0.id == id }) else { return .notFound }
            guard album.name != LibraryViewModel.allVideosAlbumName,
                  album.name != LibraryViewModel.allPhotosAlbumName else {
                return .badRequest(.text("System albums cannot be deleted"))
            }
            DispatchQueue.main.sync { dataManager.deleteAlbum(albumID: id) }
            return .ok(.text("Deleted"))
        }

        server.post["/albums/delete"] = protectedDestructive { [weak self] request -> HttpResponse in
            guard let self, let dataManager = self.dataManager else {
                return .internalServerError
            }
            struct DeleteAlbumsRequest: Codable {
                let albumIds: [String]
                let contentDisposal: String
            }
            struct DeleteAlbumsResponse: Codable {
                let deletedAlbumIDs: [UUID]
                let systemTrashResult: SystemTrashResult?
            }
            guard let deleteRequest = try? JSONDecoder().decode(
                DeleteAlbumsRequest.self,
                from: Data(request.body)
            ) else {
                return .badRequest(.text("Invalid request body"))
            }
            let albumIDs = deleteRequest.albumIds.compactMap(UUID.init(uuidString:))
            guard !albumIDs.isEmpty else {
                return .badRequest(.text("No valid album IDs"))
            }
            let contentDisposal: LibraryViewModel.AlbumContentDisposal
            switch deleteRequest.contentDisposal {
            case "keep": contentDisposal = .keep
            case "appTrash": contentDisposal = .trash
            case "complete": contentDisposal = .delete
            case "systemTrash": contentDisposal = .systemTrash
            default:
                return .badRequest(.text("Invalid content disposal"))
            }
            let response: DeleteAlbumsResponse
            if case .systemTrash = contentDisposal {
                let snapshot = dataManager.snapshotLibrary.value
                let targetIDs = Set(albumIDs)
                let mediaIDs = Array(Set(
                    snapshot.albums
                        .filter { targetIDs.contains($0.id) }
                        .flatMap(\.videoIDs)
                ))
                let trashResult = DispatchQueue.main.sync {
                    dataManager.moveMediaFilesToSystemTrash(videoIDs: mediaIDs)
                }
                if trashResult.failures.isEmpty {
                    DispatchQueue.main.sync {
                        dataManager.deleteAlbums(
                            albumIDs: albumIDs,
                            contentDisposal: .keep
                        )
                    }
                }
                response = DeleteAlbumsResponse(
                    deletedAlbumIDs: trashResult.failures.isEmpty ? albumIDs : [],
                    systemTrashResult: trashResult
                )
            } else {
                DispatchQueue.main.sync {
                    dataManager.deleteAlbums(
                        albumIDs: albumIDs,
                        contentDisposal: contentDisposal
                    )
                }
                response = DeleteAlbumsResponse(
                    deletedAlbumIDs: albumIDs,
                    systemTrashResult: nil
                )
            }
            guard let responseData = try? JSONEncoder().encode(response) else {
                return .internalServerError
            }
            return .ok(.data(responseData, contentType: "application/json"))
        }

        server.post["/albums/:id/rename"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let idString = request.params[":id"],
                  let albumID = UUID(uuidString: idString) else {
                return .badRequest(.text("Invalid album ID"))
            }
            struct RenameRequest: Codable { let name: String }
            guard let renameRequest = try? JSONDecoder().decode(RenameRequest.self, from: Data(request.body)) else {
                return .badRequest(.text("Invalid request body"))
            }
            let name = renameRequest.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80,
                  name != LibraryViewModel.allVideosAlbumName,
                  name != LibraryViewModel.allPhotosAlbumName else {
                return .badRequest(.text("Invalid album name"))
            }
            let snapshot = dataManager.snapshotLibrary.value
            guard let album = snapshot.albums.first(where: { $0.id == albumID }) else { return .notFound }
            guard album.name != LibraryViewModel.allVideosAlbumName,
                  album.name != LibraryViewModel.allPhotosAlbumName else {
                return .badRequest(.text("System albums cannot be renamed"))
            }
            guard !snapshot.albums.contains(where: { $0.id != albumID && $0.name == name }) else {
                return .raw(409, "Conflict", ["Content-Type": "text/plain"], { writer in
                    try? writer.write(Data("Album name already exists".utf8))
                })
            }
            DispatchQueue.main.sync { dataManager.renameAlbums([albumID: name]) }
            return .ok(.text("Renamed"))
        }

        server.post["/move"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            struct MoveRequest: Codable { let videoIds: [String]; let sourceAlbumId: String; let targetAlbumId: String }
            do {
                let moveRequest = try JSONDecoder().decode(MoveRequest.self, from: Data(request.body))
                let videoUUIDs = moveRequest.videoIds.compactMap { UUID(uuidString: $0) }
                guard let sourceUUID = UUID(uuidString: moveRequest.sourceAlbumId),
                      let targetUUID = UUID(uuidString: moveRequest.targetAlbumId) else { return .badRequest(.text("Invalid IDs")) }
                DispatchQueue.main.sync { dataManager.moveVideos(videoIDs: videoUUIDs, from: sourceUUID, to: targetUUID) }
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
                DispatchQueue.main.sync { dataManager.removeVideosFromAlbum(videoIDs: videoUUIDs, albumID: albumUUID) }
                return .ok(.text("Deleted successfully"))
            } catch { return .badRequest(.text("Invalid request body")) }
        }

        server.post["/deleteVideosCompletely"] = protectedDestructive { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            struct DelRequest: Codable { let videoIds: [String] }
            do {
                let req = try JSONDecoder().decode(DelRequest.self, from: Data(request.body))
                let videoUUIDs = req.videoIds.compactMap { UUID(uuidString: $0) }
                DispatchQueue.main.sync { dataManager.deleteVideos(videoIDs: videoUUIDs) }
                return .ok(.text("Deleted completely successfully"))
            } catch { return .badRequest(.text("Invalid request body")) }
        }

        server.post["/moveVideosToSystemTrash"] = protectedDestructive { [weak self] request -> HttpResponse in
            guard let self, let dataManager = self.dataManager else {
                return .internalServerError
            }
            struct MoveToSystemTrashRequest: Codable {
                let videoIds: [String]
            }
            guard let trashRequest = try? JSONDecoder().decode(
                MoveToSystemTrashRequest.self,
                from: Data(request.body)
            ) else {
                return .badRequest(.text("Invalid request body"))
            }
            let videoIDs = trashRequest.videoIds.compactMap(UUID.init(uuidString:))
            guard !videoIDs.isEmpty else {
                return .badRequest(.text("No valid video IDs"))
            }
            let result = DispatchQueue.main.sync {
                dataManager.moveMediaFilesToSystemTrash(videoIDs: videoIDs)
            }
            guard let responseData = try? JSONEncoder().encode(result) else {
                return .internalServerError
            }
            return .ok(.data(responseData, contentType: "application/json"))
        }

        server["/trash"] = protected { [weak self] _ -> HttpResponse in
            guard let self, let dataManager = self.dataManager else { return .internalServerError }
            let snapshot = dataManager.snapshotLibrary.value
            let albumByVideoID = snapshot.albums.reduce(into: [UUID: UUID]()) { result, album in
                guard album.name != LibraryViewModel.allVideosAlbumName,
                      album.name != LibraryViewModel.allPhotosAlbumName else { return }
                for videoID in album.videoIDs where result[videoID] == nil {
                    result[videoID] = album.id
                }
            }
            let infos = snapshot.videos.filter(\.isInTrash).map { video -> RemoteVideoInfo in
                let metadata = dataManager.fileMetadata(for: video)
                return RemoteVideoInfo(
                    id: video.id.uuidString,
                    filename: video.originalFilename,
                    duration: video.duration,
                    importDate: video.importDate,
                    creationDate: video.creationDate,
                    mediaType: video.mediaType.rawValue,
                    parentAlbumID: albumByVideoID[video.id]?.uuidString,
                    fileSize: metadata.size,
                    modificationDate: metadata.modificationDate,
                    accessDate: metadata.accessDate
                )
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(infos) else { return .internalServerError }
            return .ok(.data(data, contentType: "application/json"))
        }

        server.post["/trash/restore"] = protected { [weak self] request -> HttpResponse in
            guard let self, let dataManager = self.dataManager else { return .internalServerError }
            struct RestoreRequest: Codable { let videoIds: [String] }
            guard let restoreRequest = try? JSONDecoder().decode(RestoreRequest.self, from: Data(request.body)) else {
                return .badRequest(.text("Invalid request body"))
            }
            let videoIDs = restoreRequest.videoIds.compactMap(UUID.init(uuidString:))
            guard !videoIDs.isEmpty else { return .badRequest(.text("No valid video IDs")) }
            DispatchQueue.main.sync { dataManager.restoreFromTrash(videoIDs: videoIDs) }
            return .ok(.text("Restored"))
        }

        server.delete["/trash"] = protectedDestructive { [weak self] _ -> HttpResponse in
            guard let self, let dataManager = self.dataManager else { return .internalServerError }
            DispatchQueue.main.sync { dataManager.emptyTrash() }
            return .ok(.text("Trash emptied"))
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
                    guard let allVideos = dataManager.snapshotLibrary.value.albums.first(where: { $0.name == LibraryViewModel.allVideosAlbumName }) else {
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

            // スナップショットから解決（メインスレッド非経由）。再生開始が Mac UI の状態に左右されない。
            guard let videoItem = dataManager.snapshotLibrary.value.videos.first(where: { $0.id == videoID }) else { return .notFound }
            let extPath = videoItem.externalFilePath
            let internalFilename = videoItem.internalFilename
            let vURL = dataManager.videoStorageURL
            let dURL = dataManager.downloadStorageURL
            let pURL = dataManager.proxyStorageURL

            var videoURL: URL?
            if quality == "1080p" {
                // クライアントが小文字UUIDで送ってきても、Mac側で生成したファイル名（大文字）と
                // 一致するよう正規化したUUID文字列を使う（大文字小文字を区別するボリューム対策）。
                let proxyURL = pURL.appendingPathComponent("\(videoID.uuidString)_1080p.mp4")
                if FileManager.default.fileExists(atPath: proxyURL.path) { videoURL = proxyURL }
            } else if quality == "540p" {
                let proxyURL = pURL.appendingPathComponent("\(videoID.uuidString)_540p.mp4")
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
                  let rawIDStr = request.params[":id"], let parsedID = UUID(uuidString: rawIDStr) else { return .notFound }
            let idStr = parsedID.uuidString
            let quality = request.queryParams.first(where: { $0.0 == "q" })?.1 ?? "1080p"
            let shouldRetry = request.queryParams.contains(where: { $0.0 == "retry" && $0.1 == "true" })
            var state = "generating"
            var progress = 0.0
            var message: String?
            DispatchQueue.main.sync {
                if dataManager.isProxyReady(videoID: idStr, quality: quality) {
                    state = "ready"
                } else if let p = dataManager.proxyGenerationProgress(videoID: idStr, quality: quality) {
                    state = "generating"; progress = p
                } else if let failure = dataManager.proxyGenerationFailure(videoID: idStr, quality: quality), !shouldRetry {
                    state = "failed"; message = failure
                } else {
                    if shouldRetry {
                        dataManager.retryOnDemandProxy(videoID: idStr, quality: quality)
                    } else {
                        dataManager.startOnDemandProxy(videoID: idStr, quality: quality)
                    }
                    state = "generating"; progress = 0
                }
            }
            struct PrepareResp: Codable { let state: String; let progress: Double; let message: String? }
            if let data = try? JSONEncoder().encode(PrepareResp(state: state, progress: progress, message: message)) {
                return .ok(.data(data, contentType: "application/json"))
            }
            return .internalServerError
        }

        server.delete["/video/:id/proxy"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            DispatchQueue.main.sync { dataManager.deleteAllProxies() }
            return .ok(.text("Deleted"))
        }

        server["/thumbnail/:id"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let videoIDString = request.params[":id"],
                  let videoID = UUID(uuidString: videoIDString) else { return .notFound }

            let isOriginal = request.queryParams.contains(where: { $0.0 == "original" && $0.1 == "true" })
            let timeString = request.queryParams.first(where: { $0.0 == "time" })?.1
            let timeParam = timeString.flatMap { Double($0) }
            let maxPixelSize = self.thumbnailMaxPixelSize(from: request.queryParams, isOriginal: isOriginal)

            let fileName: String
            if let t = timeParam {
                let timeMilliseconds = Int((t * 1_000).rounded())
                fileName = "\(videoID.uuidString)_t\(timeMilliseconds).jpg"
            } else if isOriginal, let maxPixelSize {
                fileName = "\(videoID.uuidString)_fit\(maxPixelSize).jpg"
            } else {
                fileName = isOriginal ? "\(videoID.uuidString)_original.jpg" : "\(videoID.uuidString).jpg"
            }
            let thumbnailURL = dataManager.thumbnailStorageURL.appendingPathComponent(fileName)

            // サムネイルはID単位で実質不変なのでクライアント側キャッシュを許可する。
            // これがないと iOS はスクロールのたびに同じ画像を再取得する。
            let thumbnailCacheHeaders = [
                "Content-Type": "image/jpeg",
                "Cache-Control": "max-age=3600"
            ]

            if let cachedData = try? Data(contentsOf: thumbnailURL) {
                return .raw(200, "OK", thumbnailCacheHeaders, { writer in
                    try? writer.write(cachedData)
                })
            }

            // スナップショットから解決（メインスレッド非経由）。スクロール中のサムネイル要求
            // ラッシュが Mac UI をカクつかせず、Mac UI が忙しくてもサムネ応答が遅れない。
            guard let item = dataManager.snapshotLibrary.value.videos.first(where: { $0.id == videoID }),
                  let fileUrl = LibraryViewModel.resolveFileURL(
                    for: item,
                    videoStorageURL: dataManager.videoStorageURL,
                    downloadStorageURL: dataManager.downloadStorageURL
                  ) else { return .notFound }

            let semaphore = DispatchSemaphore(value: 0)
            var generatedData: Data? = nil

            Task {
                if let data = await self.generateThumbnailData(for: fileUrl, type: item.mediaType, quality: .high, isOriginal: isOriginal, requestedTime: timeParam, maxPixelSize: maxPixelSize) {
                    try? data.write(to: thumbnailURL, options: .atomic)
                    generatedData = data
                }
                semaphore.signal()
            }

            let result = semaphore.wait(timeout: .now() + 5.0)

            if result == .success, let data = generatedData {
                return .raw(200, "OK", thumbnailCacheHeaders, { writer in
                    try? writer.write(data)
                })
            } else {
                // 仮画像がキャッシュされると本物のサムネイルに置き換わらなくなるため no-store
                let headers = ["Content-Type": "image/jpeg", "Cache-Control": "no-store"]
                return .raw(202, "Accepted", headers, { writer in
                    try? writer.write(self.placeholderData)
                })
            }
        }

        setupSyncRoutes()

        print("✅ [SETUP] API routes configured.")
    }

}
