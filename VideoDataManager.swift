import Foundation
import AppKit
import AVFoundation
import CryptoKit
import Combine
import UniformTypeIdentifiers



// データモデル

enum MediaType: String, Codable, Hashable {
    case video
    case photo
}

enum AlbumType: String, Codable, Hashable {
    case video
    case photo
    case mixed
    
    var displayName: String {
        switch self {
        case .video: return "動画アルバム"
        case .photo: return "画像アルバム"
        case .mixed: return "すべて"
        }
    }
}

struct VideoItem: Identifiable, Codable, Hashable {
    let id: UUID
    let originalFilename: String
    var internalFilename: String
    let duration: TimeInterval
    let importDate: Date
    let creationDate: Date?
    let fileHash: String
    var mediaType: MediaType = .video
    
    var externalFilePath: String?
    
    init(id: UUID, originalFilename: String, internalFilename: String, duration: TimeInterval, importDate: Date, creationDate: Date?, fileHash: String, mediaType: MediaType = .video, externalFilePath: String? = nil) {
        self.id = id
        self.originalFilename = originalFilename
        self.internalFilename = internalFilename
        self.duration = duration
        self.importDate = importDate
        self.creationDate = creationDate
        self.fileHash = fileHash
        self.mediaType = mediaType
        self.externalFilePath = externalFilePath
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.originalFilename = try container.decode(String.self, forKey: .originalFilename)
        self.internalFilename = try container.decode(String.self, forKey: .internalFilename)
        self.duration = try container.decode(TimeInterval.self, forKey: .duration)
        self.importDate = try container.decode(Date.self, forKey: .importDate)
        self.creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate)
        self.fileHash = try container.decode(String.self, forKey: .fileHash)
        self.mediaType = try container.decodeIfPresent(MediaType.self, forKey: .mediaType) ?? .video
        self.externalFilePath = try container.decodeIfPresent(String.self, forKey: .externalFilePath)
    }
}

struct Album: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var videoIDs: [UUID]
    var type: AlbumType
    
    init(id: UUID, name: String, videoIDs: [UUID], type: AlbumType) {
        self.id = id
        self.name = name
        self.videoIDs = videoIDs
        self.type = type
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.videoIDs = try container.decode([UUID].self, forKey: .videoIDs)
        self.type = try container.decodeIfPresent(AlbumType.self, forKey: .type) ?? .video
    }
}

private struct DataContainer: Codable {
    var videos: [VideoItem]
    var albums: [Album]
}

@MainActor
class VideoDataManager: ObservableObject {
    @Published var videos: [VideoItem] = []
    @Published var albums: [Album] = []
    
    let appRootURL: URL // アプリのルートディレクトリ
    let videoStorageURL: URL
    let downloadStorageURL: URL
    let thumbnailStorageURL: URL
    let proxyStorageURL: URL
    private let dataFileURL: URL
    
    private let allVideosAlbumName = "ALL VIDEOS"
    private let allPhotosAlbumName = "ALL PHOTOS"

    private var proxyQueue: [(sourceURL: URL, preset: String, destinationURL: URL)] = []
    private var isGeneratingProxy = false

    // ★ オンデマンド・プロキシ生成の進捗 (key: "<id>_<quality>" / 値: 0...1 / nil=非生成中)
    private var proxyProgressMap: [String: Double] = [:]

    init() {
        guard let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            fatalError("Movies directory not found.")
        }
        guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            fatalError("Downloads directory not found.")
        }
        
        self.appRootURL = moviesDir.appendingPathComponent("MacVideoServerData")
        self.videoStorageURL = self.appRootURL.appendingPathComponent("Videos")
        self.thumbnailStorageURL = self.appRootURL.appendingPathComponent("Thumbnails")
        self.proxyStorageURL = self.appRootURL.appendingPathComponent("Proxies")
        self.dataFileURL = self.appRootURL.appendingPathComponent("library.json")
        self.downloadStorageURL = downloadsDir.appendingPathComponent("VideoServerForMac_Media")
        
        try? FileManager.default.createDirectory(at: self.videoStorageURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.downloadStorageURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.thumbnailStorageURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.proxyStorageURL, withIntermediateDirectories: true)
        
        loadData()
        repairMissingSymlinks()
    }
    
    // ストレージ管理
    
    func getStorageUsage() -> (videosSize: Int64, proxiesSize: Int64, downloadsSize: Int64, appTotalSize: Int64) {
        var vSize: Int64 = 0
        var pSize: Int64 = 0
        var dSize: Int64 = 0
        var totalSize: Int64 = 0
        
        if let videoURLs = try? FileManager.default.contentsOfDirectory(at: videoStorageURL, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) {
            for url in videoURLs {
                let resources = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                if resources?.isSymbolicLink == false {
                    vSize += Int64(resources?.fileSize ?? 0)
                }
            }
        }
        
        if let proxyURLs = try? FileManager.default.contentsOfDirectory(at: proxyStorageURL, includingPropertiesForKeys: [.fileSizeKey]) {
            for url in proxyURLs {
                let resources = try? url.resourceValues(forKeys: [.fileSizeKey])
                pSize += Int64(resources?.fileSize ?? 0)
            }
        }
        
        if let downloadURLs = try? FileManager.default.contentsOfDirectory(at: downloadStorageURL, includingPropertiesForKeys: [.fileSizeKey]) {
            for url in downloadURLs {
                let resources = try? url.resourceValues(forKeys: [.fileSizeKey])
                dSize += Int64(resources?.fileSize ?? 0)
            }
        }
        
        if let enumerator = FileManager.default.enumerator(at: appRootURL, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) {
            for case let url as URL in enumerator {
                let resources = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                if resources?.isSymbolicLink == false {
                    totalSize += Int64(resources?.fileSize ?? 0)
                }
            }
        }
        
        return (vSize, pSize, dSize, totalSize)
    }
    
    func openDownloadsFolderInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: downloadStorageURL.path)
    }
    
    func openHiddenVideoFolderInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: videoStorageURL.path)
    }
    
    func openProxyFolderInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: proxyStorageURL.path)
    }
    
    func openAppRootFolderInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: appRootURL.path)
    }
    
    func openTempFolderInFinder() {
        let tempDir = FileManager.default.temporaryDirectory
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: tempDir.path)
    }
    
    func removeDuplicateVideos() -> Int {
        var seenHashes = Set<String>()
        var idsToRemove = [UUID]()
        
        for item in videos {
            guard !item.fileHash.isEmpty else { continue }
            
            if seenHashes.contains(item.fileHash) {
                idsToRemove.append(item.id)
            } else {
                seenHashes.insert(item.fileHash)
            }
        }
        
        let removedCount = idsToRemove.count
        
        if removedCount > 0 {
            deleteVideos(videoIDs: idsToRemove)
        }
        
        cleanUpOrphanedFiles()
        
        return removedCount
    }
    
    func clearAllProxies() {
        if let proxyURLs = try? FileManager.default.contentsOfDirectory(at: proxyStorageURL, includingPropertiesForKeys: nil) {
            for url in proxyURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        proxyQueue.removeAll()
        isGeneratingProxy = false
    }
    
    func cleanUpOrphanedFiles() {
        let validInternalNames = Set(videos.map { $0.internalFilename })
        if let videoURLs = try? FileManager.default.contentsOfDirectory(at: videoStorageURL, includingPropertiesForKeys: nil) {
            for url in videoURLs {
                if !validInternalNames.contains(url.lastPathComponent) && url.lastPathComponent != ".DS_Store" {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        
        let validProxyPrefixes = Set(videos.map { $0.id.uuidString })
        if let proxyURLs = try? FileManager.default.contentsOfDirectory(at: proxyStorageURL, includingPropertiesForKeys: nil) {
            for url in proxyURLs {
                let filename = url.lastPathComponent
                let isOrphan = !validProxyPrefixes.contains(where: { filename.hasPrefix($0) })
                if isOrphan {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
    
    func optimizeStorage() async {
        var needsSave = false
        
        for i in 0..<videos.count {
            let item = videos[i]
            if !item.internalFilename.isEmpty {
                let hiddenURL = videoStorageURL.appendingPathComponent(item.internalFilename)
                
                if FileManager.default.fileExists(atPath: hiddenURL.path) {
                    let resources = try? hiddenURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                    if resources?.isSymbolicLink == false {
                        
                        var canJustDelete = false
                        var targetExtURL: URL? = nil
                        
                        if let extPath = item.externalFilePath, FileManager.default.fileExists(atPath: extPath) {
                            canJustDelete = true
                            targetExtURL = URL(fileURLWithPath: extPath)
                        } else {
                            let possibleDownloadURL = downloadStorageURL.appendingPathComponent(item.internalFilename)
                            if FileManager.default.fileExists(atPath: possibleDownloadURL.path) {
                                canJustDelete = true
                                targetExtURL = possibleDownloadURL
                            }
                        }
                        
                        if canJustDelete, let validExtURL = targetExtURL {
                            do {
                                try FileManager.default.removeItem(at: hiddenURL)
                                await MainActor.run {
                                    videos[i].externalFilePath = validExtURL.path
                                    videos[i].internalFilename = "" // 完全参照方式にするため空にする
                                    needsSave = true
                                }
                            } catch {
                                print("重複削除エラー: \(error)")
                            }
                        } else {
                            var destinationURL = downloadStorageURL.appendingPathComponent(item.originalFilename)
                            var counter = 2
                            let nameWithoutExt = destinationURL.deletingPathExtension().lastPathComponent
                            let fileExt = destinationURL.pathExtension
                            while FileManager.default.fileExists(atPath: destinationURL.path) {
                                destinationURL = downloadStorageURL.appendingPathComponent("\(nameWithoutExt) (\(counter)).\(fileExt)")
                                counter += 1
                            }
                            
                            do {
                                try FileManager.default.moveItem(at: hiddenURL, to: destinationURL)
                                await MainActor.run {
                                    videos[i].externalFilePath = destinationURL.path
                                    videos[i].internalFilename = "" // 完全参照方式にするため空にする
                                    needsSave = true
                                }
                            } catch {
                                print("移動エラー: \(error)")
                            }
                        }
                    } else if resources?.isSymbolicLink == true {
                        if item.externalFilePath != nil {
                            try? FileManager.default.removeItem(at: hiddenURL)
                            await MainActor.run {
                                videos[i].internalFilename = ""
                                needsSave = true
                            }
                        }
                    }
                }
            }
        }
        if needsSave { saveData() }
    }
    
    private func repairMissingSymlinks() {
        var needsSave = false
        for i in 0..<videos.count {
            if videos[i].internalFilename.isEmpty, let extPath = videos[i].externalFilePath {
                let sourceURL = URL(fileURLWithPath: extPath)
                let ext = sourceURL.pathExtension
                let newInternal = "\(videos[i].id.uuidString).\(ext)"
                let symlinkURL = videoStorageURL.appendingPathComponent(newInternal)
                
                if !FileManager.default.fileExists(atPath: symlinkURL.path) {
                    try? FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: sourceURL)
                }
                videos[i].internalFilename = newInternal
                needsSave = true
            }
        }
        if needsSave { saveData() }
    }
    
    func fileURL(for item: VideoItem) -> URL? {
        if let extPath = item.externalFilePath {
            let extURL = URL(fileURLWithPath: extPath)
            if FileManager.default.fileExists(atPath: extURL.path) {
                return extURL
            }
        }
        
        if !item.internalFilename.isEmpty {
            let hiddenURL = videoStorageURL.appendingPathComponent(item.internalFilename)
            if FileManager.default.fileExists(atPath: hiddenURL.path) {
                return hiddenURL
            }
            let downloadURL = downloadStorageURL.appendingPathComponent(item.internalFilename)
            if FileManager.default.fileExists(atPath: downloadURL.path) {
                return downloadURL
            }
        }
        return nil
    }
    
    private func generateMissingProxies() {

    }
    
    private func enqueueProxyTask(sourceURL: URL, preset: String, destinationURL: URL) {
        proxyQueue.append((sourceURL: sourceURL, preset: preset, destinationURL: destinationURL))
        processNextProxyTask()
    }
    
    private func processNextProxyTask() {
        guard !isGeneratingProxy, !proxyQueue.isEmpty else { return }
        isGeneratingProxy = true
        
        let nextTask = proxyQueue.removeFirst()
        
        Task {
            await generateProxy(sourceURL: nextTask.sourceURL, destinationURL: nextTask.destinationURL, preset: nextTask.preset)
            self.isGeneratingProxy = false
            self.processNextProxyTask()
        }
    }
    
    private func generateProxy(sourceURL: URL, destinationURL: URL, preset: String) async {
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else { return }
        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        
        await withCheckedContinuation { continuation in
            exportSession.exportAsynchronously {
                continuation.resume()
            }
        }
        
        if exportSession.status != .completed {
            try? FileManager.default.removeItem(at: destinationURL)
        }
    }

    // MARK: - オンデマンド・プロキシ生成 (視聴時のみ生成し、視聴後に削除)
    func proxyFileURL(videoID: String, quality: String) -> URL {
        proxyStorageURL.appendingPathComponent("\(videoID)_\(quality).mp4")
    }

    func isProxyReady(videoID: String, quality: String) -> Bool {
        FileManager.default.fileExists(atPath: proxyFileURL(videoID: videoID, quality: quality).path)
    }

    /// 生成中なら 0...1 の進捗、生成していなければ nil を返す
    func proxyGenerationProgress(videoID: String, quality: String) -> Double? {
        proxyProgressMap["\(videoID)_\(quality)"]
    }

    /// オンデマンドでプロキシ生成を開始する (既に生成済み/生成中なら何もしない)
    func startOnDemandProxy(videoID: String, quality: String) {
        let key = "\(videoID)_\(quality)"
        guard proxyProgressMap[key] == nil else { return }          // 生成中
        guard !isProxyReady(videoID: videoID, quality: quality) else { return } // 生成済み
        guard let item = videos.first(where: { $0.id.uuidString == videoID }),
              item.mediaType == .video,
              let sourceURL = fileURL(for: item) else { return }

        let preset = (quality == "540p") ? AVAssetExportPreset960x540 : AVAssetExportPreset1920x1080
        let dest = proxyFileURL(videoID: videoID, quality: quality)

        // 視聴後に溜まらないよう、生成前に他のプロキシを削除し常に1本だけ保持する
        sweepProxies(except: dest)

        proxyProgressMap[key] = 0.0
        Task { await generateOnDemandProxy(sourceURL: sourceURL, destinationURL: dest, preset: preset, key: key) }
    }

    private func generateOnDemandProxy(sourceURL: URL, destinationURL: URL, preset: String, key: String) async {
        try? FileManager.default.removeItem(at: destinationURL)
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            await MainActor.run { self.proxyProgressMap[key] = nil }
            return
        }
        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        // 変換の進捗を定期的に反映する
        let progressTimer = Task { @MainActor in
            while !Task.isCancelled {
                self.proxyProgressMap[key] = Double(exportSession.progress)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        await withCheckedContinuation { continuation in
            exportSession.exportAsynchronously { continuation.resume() }
        }
        progressTimer.cancel()

        await MainActor.run {
            if exportSession.status != .completed {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            self.proxyProgressMap[key] = nil   // 完了/失敗で生成中フラグを解除
        }
    }

    /// 指定URL以外のプロキシを全削除する (常に1本だけ保持するため)
    private func sweepProxies(except keepURL: URL?) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: proxyStorageURL, includingPropertiesForKeys: nil) else { return }
        for url in urls {
            if let keep = keepURL, url.lastPathComponent == keep.lastPathComponent { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 視聴終了時に呼ぶ: すべてのオンデマンドプロキシを削除する
    func deleteAllProxies() {
        sweepProxies(except: nil)
    }

    // データ集計・操作
    var recentItems: [VideoItem] { Array(videos.sorted { $0.importDate > $1.importDate }.prefix(10)) }
    
    func calculateTotalStorageSize() -> String {
        let totalSize = videos.reduce(Int64(0)) { result, item in
            guard let url = fileURL(for: item) else { return result }
            let resources = try? url.resourceValues(forKeys: [.fileSizeKey])
            return result + Int64(resources?.fileSize ?? 0)
        }
        let formatter = ByteCountFormatter(); formatter.allowedUnits = [.useGB, .useMB, .useKB]; formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
    
    func clearThumbnailCache() {
        do { let fileURLs = try FileManager.default.contentsOfDirectory(at: thumbnailStorageURL, includingPropertiesForKeys: nil); for url in fileURLs { try FileManager.default.removeItem(at: url) } } catch {}
    }
    
    func scanFolder(folderURL: URL) -> (videoCount: Int, photoCount: Int) {
        let shouldStopAccessing = folderURL.startAccessingSecurityScopedResource()
        defer { if shouldStopAccessing { folderURL.stopAccessingSecurityScopedResource() } }
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return (0, 0) }
        var videoCount = 0; var photoCount = 0
        for url in contents { let ext = url.pathExtension.lowercased(); if let type = UTType(filenameExtension: ext) { if type.conforms(to: .movie) { videoCount += 1 } else if type.conforms(to: .image) { photoCount += 1 } } }
        return (videoCount, photoCount)
    }
    
    func importFolder(folderURL: URL, as albumType: AlbumType) async {
        let folderName = folderURL.lastPathComponent
        var targetAlbumID: UUID
        if let existingAlbum = albums.first(where: { $0.name == folderName && $0.type == albumType }) { targetAlbumID = existingAlbum.id } else { targetAlbumID = UUID(); albums.append(Album(id: targetAlbumID, name: folderName, videoIDs: [], type: albumType)); saveData() }
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }
        for url in contents { if !url.hasDirectoryPath { await importMedia(from: url, to: targetAlbumID) } }
    }

    func importMedia(from sourceURL: URL, to albumID: UUID, customFilename: String? = nil) async {
        guard let targetAlbum = albums.first(where: { $0.id == albumID }) else { return }
        let fileExtension = sourceURL.pathExtension
        let type = UTType(filenameExtension: fileExtension)
        let isImage = type?.conforms(to: .image) ?? ["jpg", "jpeg", "png", "heic", "webp", "gif", "tiff"].contains(fileExtension.lowercased())
        let isMovie = type?.conforms(to: .movie) ?? ["mp4", "mov", "m4v", "avi"].contains(fileExtension.lowercased())
        if targetAlbum.type == .video && isImage { return }
        if targetAlbum.type == .photo && isMovie { return }
        
        let shouldStopAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if shouldStopAccessing { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            let fileHash = try computeFileHash(for: sourceURL)
            if let existingItem = videos.first(where: { $0.fileHash == fileHash }) {
                if let albumIndex = albums.firstIndex(where: { $0.id == albumID }), !albums[albumIndex].videoIDs.contains(existingItem.id) { albums[albumIndex].videoIDs.append(existingItem.id); saveData() }
                return
            }

            let newID = UUID()
            var internalFilename = ""
            var externalPath: String? = nil
            let originalName = sourceURL.lastPathComponent
            let urlForMetadata: URL
            
            if let customName = customFilename {
                internalFilename = customName
                var destinationURL = downloadStorageURL.appendingPathComponent(internalFilename)
                var counter = 2
                let nameWithoutExt = destinationURL.deletingPathExtension().lastPathComponent
                let fileExt = destinationURL.pathExtension
                while FileManager.default.fileExists(atPath: destinationURL.path) {
                    internalFilename = "\(nameWithoutExt) (\(counter)).\(fileExt)"
                    destinationURL = downloadStorageURL.appendingPathComponent(internalFilename)
                    counter += 1
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                urlForMetadata = destinationURL
                externalPath = destinationURL.path
            } else {
                externalPath = sourceURL.path
                urlForMetadata = sourceURL
                internalFilename = ""
            }
            
            let mediaType: MediaType
            var duration: TimeInterval = 0
            var creationDate: Date? = nil
            
            if isImage {
                mediaType = .photo
                if let attributes = try? FileManager.default.attributesOfItem(atPath: urlForMetadata.path) { creationDate = attributes[.creationDate] as? Date }
            } else if isMovie {
                mediaType = .video
                let asset = AVURLAsset(url: urlForMetadata)
                duration = (try? await asset.load(.duration))?.seconds ?? 0
                if #available(macOS 13.0, *) { creationDate = try? await asset.load(.creationDate)?.load(.dateValue) } else { creationDate = (try? await asset.load(.creationDate))?.dateValue }
            } else {
                if customFilename != nil { try? FileManager.default.removeItem(at: urlForMetadata) }
                return
            }
            
            let newItem = VideoItem(id: newID, originalFilename: customFilename ?? originalName, internalFilename: internalFilename, duration: duration, importDate: Date(), creationDate: creationDate, fileHash: fileHash, mediaType: mediaType, externalFilePath: externalPath)
            
            videos.append(newItem)
            if let index = albums.firstIndex(where: { $0.id == albumID }) { albums[index].videoIDs.append(newID) }
            if mediaType == .photo { if let idx = albums.firstIndex(where: { $0.name == allPhotosAlbumName }) { albums[idx].videoIDs.append(newID) } } else { if let idx = albums.firstIndex(where: { $0.name == allVideosAlbumName }) { albums[idx].videoIDs.append(newID) } }
            
            saveData()
            

            
        } catch {}
    }

    func deleteVideos(videoIDs: [UUID]) {
        for i in 0..<albums.count { albums[i].videoIDs.removeAll { videoIDs.contains($0) } }
        let idsToDelete = videoIDs.filter { videoID in !albums.contains { $0.videoIDs.contains(videoID) } }
        
        for id in idsToDelete {
            if let item = videos.first(where: { $0.id == id }) {
                if let extPath = item.externalFilePath {
                    let extURL = URL(fileURLWithPath: extPath)
                    if extURL.path.hasPrefix(downloadStorageURL.path) || extURL.path.hasPrefix(videoStorageURL.path) {
                        try? FileManager.default.removeItem(at: extURL)
                    }
                } else if !item.internalFilename.isEmpty {
                    if let fileURL = fileURL(for: item) {
                         if fileURL.path.hasPrefix(videoStorageURL.path) || fileURL.path.hasPrefix(downloadStorageURL.path) {
                             try? FileManager.default.removeItem(at: fileURL)
                         }
                    }
                }
                
                let thumbURL = thumbnailStorageURL.appendingPathComponent(item.id.uuidString).appendingPathExtension("jpg")
                try? FileManager.default.removeItem(at: thumbURL)
                
                let proxy1080URL = proxyStorageURL.appendingPathComponent("\(item.id.uuidString)_1080p.mp4")
                try? FileManager.default.removeItem(at: proxy1080URL)
                let proxy540URL = proxyStorageURL.appendingPathComponent("\(item.id.uuidString)_540p.mp4")
                try? FileManager.default.removeItem(at: proxy540URL)
            }
        }
        videos.removeAll { idsToDelete.contains($0.id) }
        saveData()
    }
    
    func removeVideosFromAlbum(videoIDs: [UUID], albumID: UUID) { if let index = albums.firstIndex(where: { $0.id == albumID }) { let name = albums[index].name; if name == allVideosAlbumName || name == allPhotosAlbumName { deleteVideos(videoIDs: videoIDs) } else { albums[index].videoIDs.removeAll { videoIDs.contains($0) }; saveData() } } }
    func createAlbum(name: String, type: AlbumType) { guard name != allVideosAlbumName && name != allPhotosAlbumName else { return }; albums.append(Album(id: UUID(), name: name, videoIDs: [], type: type)); saveData() }
    func deleteAlbum(albumID: UUID) { guard let album = albums.first(where: { $0.id == albumID }), album.name != allVideosAlbumName, album.name != allPhotosAlbumName else { return }; albums.removeAll { $0.id == albumID }; saveData() }
    func moveVideos(videoIDs: [UUID], from sourceAlbumID: UUID, to targetAlbumID: UUID) { guard albums.contains(where: { $0.id == targetAlbumID }) else { return }; if let sourceIndex = albums.firstIndex(where: { $0.id == sourceAlbumID }), albums[sourceIndex].name != allVideosAlbumName, albums[sourceIndex].name != allPhotosAlbumName { albums[sourceIndex].videoIDs.removeAll { videoIDs.contains($0) } }; if let targetIndex = albums.firstIndex(where: { $0.id == targetAlbumID }) { let existingIDs = Set(albums[targetIndex].videoIDs); let newIDs = videoIDs.filter { !existingIDs.contains($0) }; albums[targetIndex].videoIDs.append(contentsOf: newIDs) }; saveData() }

    private func saveData() { do { let data = try JSONEncoder().encode(DataContainer(videos: videos, albums: albums)); try data.write(to: dataFileURL, options: .atomic) } catch {} }
    private func loadData() { do { guard FileManager.default.fileExists(atPath: dataFileURL.path), let data = try? Data(contentsOf: dataFileURL), !data.isEmpty else { setupInitialAlbums(); saveData(); return }; let container = try JSONDecoder().decode(DataContainer.self, from: data); self.videos = container.videos; self.albums = container.albums; setupInitialAlbums() } catch { setupInitialAlbums(); saveData() } }
    private func setupInitialAlbums() { updateOrCreateSystemAlbum(name: allVideosAlbumName, type: .video, ids: Set(videos.filter { $0.mediaType == .video }.map { $0.id })); updateOrCreateSystemAlbum(name: allPhotosAlbumName, type: .photo, ids: Set(videos.filter { $0.mediaType == .photo }.map { $0.id })) }
    private func updateOrCreateSystemAlbum(name: String, type: AlbumType, ids: Set<UUID>) { if let index = albums.firstIndex(where: { $0.name == name }) { albums[index].videoIDs = Array(ids); albums[index].type = type } else { albums.insert(Album(id: UUID(), name: name, videoIDs: Array(ids), type: type), at: 0) } }
    private func computeFileHash(for url: URL) throws -> String { let handle = try FileHandle(forReadingFrom: url); var hasher = SHA256(); while autoreleasepool(invoking: { let chunk = handle.readData(ofLength: 8192); if !chunk.isEmpty { hasher.update(data: chunk); return true } else { return false } }) {}; return hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}
