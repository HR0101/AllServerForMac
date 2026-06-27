import Foundation
import AppKit
import AVFoundation
import CryptoKit
import Combine
import UniformTypeIdentifiers



// MARK: - Shared Utilities

func isImagePredominantlyBlack(image: CGImage, threshold: CGFloat = 0.1) -> Bool {
    let size = 20
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var rawData = [UInt8](repeating: 0, count: size * size * 4)
    guard let context = CGContext(
        data: &rawData, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
    var darkPixelCount = 0
    for i in 0..<(size * size) {
        let offset = i * 4
        let luminance = 0.299 * CGFloat(rawData[offset]) / 255.0
                      + 0.587 * CGFloat(rawData[offset + 1]) / 255.0
                      + 0.114 * CGFloat(rawData[offset + 2]) / 255.0
        if luminance < threshold { darkPixelCount += 1 }
    }
    return Double(darkPixelCount) / Double(size * size) > 0.8
}

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

    var isFavorite: Bool = false
    var isInTrash: Bool = false

    init(id: UUID, originalFilename: String, internalFilename: String, duration: TimeInterval, importDate: Date, creationDate: Date?, fileHash: String, mediaType: MediaType = .video, externalFilePath: String? = nil, isFavorite: Bool = false, isInTrash: Bool = false) {
        self.id = id
        self.originalFilename = originalFilename
        self.internalFilename = internalFilename
        self.duration = duration
        self.importDate = importDate
        self.creationDate = creationDate
        self.fileHash = fileHash
        self.mediaType = mediaType
        self.externalFilePath = externalFilePath
        self.isFavorite = isFavorite
        self.isInTrash = isInTrash
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
        self.isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        self.isInTrash = try container.decodeIfPresent(Bool.self, forKey: .isInTrash) ?? false
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
    
    let appRootURL: URL
    let videoStorageURL: URL
    let downloadStorageURL: URL
    let thumbnailStorageURL: URL
    let proxyStorageURL: URL
    private let dataFileURL: URL
    
    static let allVideosAlbumName = "ALL VIDEOS"
    static let allPhotosAlbumName = "ALL PHOTOS"

    private var proxyQueue: [(sourceURL: URL, preset: String, destinationURL: URL)] = []
    private var isGeneratingProxy = false

    // key: "<videoID>_<quality>", 値: 0...1 の進捗、nil = 生成していない
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
    
    nonisolated func getStorageUsage() async -> (videosSize: Int64, proxiesSize: Int64, downloadsSize: Int64, appTotalSize: Int64) {
        let videoStorageURL = self.videoStorageURL
        let proxyStorageURL = self.proxyStorageURL
        let downloadStorageURL = self.downloadStorageURL
        let appRootURL = self.appRootURL

        return await Task.detached(priority: .utility) {
            var vSize: Int64 = 0
            var pSize: Int64 = 0
            var dSize: Int64 = 0
            var totalSize: Int64 = 0

            if let urls = try? FileManager.default.contentsOfDirectory(at: videoStorageURL, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) {
                for url in urls {
                    let res = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                    if res?.isSymbolicLink == false { vSize += Int64(res?.fileSize ?? 0) }
                }
            }
            if let urls = try? FileManager.default.contentsOfDirectory(at: proxyStorageURL, includingPropertiesForKeys: [.fileSizeKey]) {
                for url in urls {
                    let res = try? url.resourceValues(forKeys: [.fileSizeKey])
                    pSize += Int64(res?.fileSize ?? 0)
                }
            }
            if let urls = try? FileManager.default.contentsOfDirectory(at: downloadStorageURL, includingPropertiesForKeys: [.fileSizeKey]) {
                for url in urls {
                    let res = try? url.resourceValues(forKeys: [.fileSizeKey])
                    dSize += Int64(res?.fileSize ?? 0)
                }
            }
            if let enumerator = FileManager.default.enumerator(at: appRootURL, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) {
                while let url = enumerator.nextObject() as? URL {
                    let res = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                    if res?.isSymbolicLink == false { totalSize += Int64(res?.fileSize ?? 0) }
                }
            }
            return (vSize, pSize, dSize, totalSize)
        }.value
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

    // MARK: - On-demand Proxy
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
        guard proxyProgressMap[key] == nil else { return }
        guard !isProxyReady(videoID: videoID, quality: quality) else { return }
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
            let urlForHash = sourceURL
            let fileHash = try await Task.detached(priority: .utility) {
                try VideoDataManager.computeFileHash(for: urlForHash)
            }.value
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
            if mediaType == .photo { if let idx = albums.firstIndex(where: { $0.name == VideoDataManager.allPhotosAlbumName }) { albums[idx].videoIDs.append(newID) } } else { if let idx = albums.firstIndex(where: { $0.name == VideoDataManager.allVideosAlbumName }) { albums[idx].videoIDs.append(newID) } }
            
            saveData()
            
            if mediaType == .video {
                if let url = self.fileURL(for: newItem) {
                    Task.detached(priority: .background) {
                        await FaceAnalyzer.analyze(videoID: newItem.id, url: url)
                    }
                }
            }
            
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
    
    func removeVideosFromAlbum(videoIDs: [UUID], albumID: UUID) { if let index = albums.firstIndex(where: { $0.id == albumID }) { let name = albums[index].name; if name == VideoDataManager.allVideosAlbumName || name == VideoDataManager.allPhotosAlbumName { deleteVideos(videoIDs: videoIDs) } else { albums[index].videoIDs.removeAll { videoIDs.contains($0) }; saveData() } } }
    @discardableResult
    func createAlbum(name: String, type: AlbumType) -> UUID? { guard name != VideoDataManager.allVideosAlbumName && name != VideoDataManager.allPhotosAlbumName else { return nil }; let id = UUID(); albums.append(Album(id: id, name: name, videoIDs: [], type: type)); saveData(); return id }

    /// 指定アルバムに動画を追加する（重複は無視）
    func addVideosToAlbum(videoIDs: [UUID], albumID: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        let existing = Set(albums[index].videoIDs)
        albums[index].videoIDs.append(contentsOf: videoIDs.filter { !existing.contains($0) })
        saveData()
    }
    func deleteAlbum(albumID: UUID) { guard let album = albums.first(where: { $0.id == albumID }), album.name != VideoDataManager.allVideosAlbumName, album.name != VideoDataManager.allPhotosAlbumName else { return }; albums.removeAll { $0.id == albumID }; saveData() }
    func moveVideos(videoIDs: [UUID], from sourceAlbumID: UUID, to targetAlbumID: UUID) { guard albums.contains(where: { $0.id == targetAlbumID }) else { return }; if let sourceIndex = albums.firstIndex(where: { $0.id == sourceAlbumID }), albums[sourceIndex].name != VideoDataManager.allVideosAlbumName, albums[sourceIndex].name != VideoDataManager.allPhotosAlbumName { albums[sourceIndex].videoIDs.removeAll { videoIDs.contains($0) } }; if let targetIndex = albums.firstIndex(where: { $0.id == targetAlbumID }) { let existingIDs = Set(albums[targetIndex].videoIDs); let newIDs = videoIDs.filter { !existingIDs.contains($0) }; albums[targetIndex].videoIDs.append(contentsOf: newIDs) }; saveData() }

    // MARK: - Favorites & Trash

    /// ゴミ箱を除いたお気に入り
    var favoriteVideos: [VideoItem] { videos.filter { $0.isFavorite && !$0.isInTrash } }
    /// ゴミ箱内のアイテム
    var trashedVideos: [VideoItem] { videos.filter { $0.isInTrash } }

    /// 指定アイテムのお気に入りを切り替える（1つでも未登録があれば全て登録、なければ全て解除）
    func toggleFavorite(videoIDs: [UUID]) {
        let ids = Set(videoIDs)
        let shouldFavorite = videos.contains { ids.contains($0.id) && !$0.isFavorite }
        for i in videos.indices where ids.contains(videos[i].id) {
            videos[i].isFavorite = shouldFavorite
        }
        saveData()
    }

    func moveToTrash(videoIDs: [UUID]) {
        let ids = Set(videoIDs)
        for i in videos.indices where ids.contains(videos[i].id) {
            videos[i].isInTrash = true
            videos[i].isFavorite = false
        }
        saveData()
    }

    func restoreFromTrash(videoIDs: [UUID]) {
        let ids = Set(videoIDs)
        for i in videos.indices where ids.contains(videos[i].id) {
            videos[i].isInTrash = false
        }
        saveData()
    }

    /// ゴミ箱を空にする（ファイルごと完全削除）
    func emptyTrash() {
        deleteVideos(videoIDs: trashedVideos.map { $0.id })
    }

    private func saveData() { do { let data = try JSONEncoder().encode(DataContainer(videos: videos, albums: albums)); try data.write(to: dataFileURL, options: .atomic) } catch {} }
    private func loadData() { do { guard FileManager.default.fileExists(atPath: dataFileURL.path), let data = try? Data(contentsOf: dataFileURL), !data.isEmpty else { setupInitialAlbums(); saveData(); return }; let container = try JSONDecoder().decode(DataContainer.self, from: data); self.videos = container.videos; self.albums = container.albums; setupInitialAlbums() } catch { setupInitialAlbums(); saveData() } }
    private func setupInitialAlbums() { updateOrCreateSystemAlbum(name: VideoDataManager.allVideosAlbumName, type: .video, ids: Set(videos.filter { $0.mediaType == .video }.map { $0.id })); updateOrCreateSystemAlbum(name: VideoDataManager.allPhotosAlbumName, type: .photo, ids: Set(videos.filter { $0.mediaType == .photo }.map { $0.id })) }
    private func updateOrCreateSystemAlbum(name: String, type: AlbumType, ids: Set<UUID>) { if let index = albums.firstIndex(where: { $0.name == name }) { albums[index].videoIDs = Array(ids); albums[index].type = type } else { albums.insert(Album(id: UUID(), name: name, videoIDs: Array(ids), type: type), at: 0) } }
    nonisolated private static func computeFileHash(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 65536)
            if !chunk.isEmpty { hasher.update(data: chunk); return true }
            return false
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Face Recognition Prototype

struct FaceAppearance: Codable, Hashable {
    let videoID: UUID
    let boundingBox: CGRect
}

struct FaceColor: Codable {
    var grid: [Float] // 8x8 RGB = 192 elements (L2 Normalized)
    
    init(grid: [Float]) {
        var sumSq: Float = 0
        for v in grid { sumSq += v * v }
        let norm = sqrt(sumSq) > 0.0001 ? sqrt(sumSq) : 1.0
        self.grid = grid.map { $0 / norm }
    }
    
    func distance(to other: FaceColor) -> Float {
        guard grid.count == other.grid.count, grid.count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<grid.count {
            let diff = grid[i] - other.grid[i]
            sum += diff * diff
        }
        return sqrt(sum) // Since it's L2 normalized, max distance is 2.0
    }
}

class PersonCluster: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var appearances: [FaceAppearance]
    var featurePrintData: Data
    var averageColor: FaceColor?
    
    init(name: String, appearances: [FaceAppearance], featurePrintData: Data, averageColor: FaceColor?) {
        self.name = name
        self.appearances = appearances
        self.featurePrintData = featurePrintData
        self.averageColor = averageColor
    }
}

class FaceDatabase: ObservableObject {
    static let shared = FaceDatabase()
    
    @Published var clusters: [PersonCluster] = []
    
    private let saveURL: URL
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        saveURL = docs.appendingPathComponent("FaceDatabase.json")
        load()
    }
    
    func load() {
        if let data = try? Data(contentsOf: saveURL),
           let decoded = try? JSONDecoder().decode([PersonCluster].self, from: data) {
            DispatchQueue.main.async {
                self.clusters = decoded
            }
        }
    }
    
    func save() {
        if let data = try? JSONEncoder().encode(clusters) {
            try? data.write(to: saveURL)
        }
    }
    
    func clear() {
        DispatchQueue.main.async {
            self.clusters = []
            self.save()
        }
    }
    
    func addFace(videoID: UUID, boundingBox: CGRect, featurePrint: VNFeaturePrintObservation, faceColor: FaceColor?) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: featurePrint, requiringSecureCoding: true) else { return }
        
        let appearance = FaceAppearance(videoID: videoID, boundingBox: boundingBox)
        
        var bestCluster: PersonCluster? = nil
        var bestDistance: Float = .infinity
        
        for cluster in clusters {
            if let clusterPrint = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: cluster.featurePrintData) {
                var distance: Float = 0
                do {
                    try featurePrint.computeDistance(&distance, to: clusterPrint)
                    
                    // 空間的色情報(8x8グリッド)の差をペナルティとして加算
                    if let c1 = faceColor, let c2 = cluster.averageColor {
                        let colorDist = c1.distance(to: c2)
                        // 正規化された色距離(最大2.0) × 4.0 = 最大8.0のペナルティ
                        distance += colorDist * 4.0
                    }
                    
                    if distance < bestDistance {
                        bestDistance = distance
                        bestCluster = cluster
                    }
                } catch {
                    print("Distance computation error: \(error)")
                }
            }
        }
        
        // 同一人物が別人に分かれてしまうのを防ぐため、しきい値を少し緩和(1.5 -> 7.0)
        // 色ペナルティ（最大8.0）が加算されるため、これでも十分別人は分かれます
        let distanceThreshold: Float = 7.0
        
        if let best = bestCluster, bestDistance < distanceThreshold {
            best.appearances.append(appearance)
            
            // 色の平均を更新
            if let newC = faceColor, let oldC = best.averageColor, newC.grid.count == oldC.grid.count {
                let n = Float(best.appearances.count)
                var blendedGrid = [Float]()
                for i in 0..<newC.grid.count {
                    blendedGrid.append(((oldC.grid[i] * (n - 1)) + newC.grid[i]) / n)
                }
                best.averageColor = FaceColor(grid: blendedGrid)
            } else if best.averageColor == nil {
                best.averageColor = faceColor
            }
            
        } else {
            let newCluster = PersonCluster(name: "人物 \(clusters.count + 1)", appearances: [appearance], featurePrintData: data, averageColor: faceColor)
            clusters.append(newCluster)
        }
        save()
    }
    
    func getAlbums() -> [Album] {
        return clusters.map { cluster in
            let videoIDs = Array(Set(cluster.appearances.map { $0.videoID }))
            return Album(id: cluster.id, name: "👤 " + cluster.name, videoIDs: videoIDs, type: .video)
        }
    }
}

import Vision

class FaceAnalyzer {
    static func analyze(videoID: UUID, url: URL) async {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        
        do {
            let duration = try await asset.load(.duration)
            let totalSeconds = duration.isValid && duration.isNumeric ? duration.seconds : 0.0
            // 複数人対応のため、最低でも100箇所以上サンプリングする。動画が長い場合は1秒に1回など更に増やす。
            var fractions: [Double] = [0.0]
            if totalSeconds > 0 {
                let count = max(100, Int(totalSeconds))
                fractions = (0..<count).map { Double($0) / Double(count) }
            }
            
            for fraction in fractions {
                let seconds = totalSeconds * fraction
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                let cgImage: CGImage
                do {
                    let (img, _) = try await generator.image(at: time)
                    cgImage = img
                } catch {
                    continue
                }
                
                autoreleasepool {
                    let request = VNDetectFaceRectanglesRequest()
                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try? handler.perform([request])
                    
                    guard let results = request.results else { return }
                    
                    for face in results {
                        let boundingBox = face.boundingBox
                        let width = boundingBox.width * CGFloat(cgImage.width)
                        let height = boundingBox.height * CGFloat(cgImage.height)
                        let x = boundingBox.origin.x * CGFloat(cgImage.width)
                        let y = (1.0 - boundingBox.origin.y - boundingBox.height) * CGFloat(cgImage.height)
                        let rect = CGRect(x: x, y: y, width: width, height: height)
                        
                        guard let faceImage = cgImage.cropping(to: rect) else { continue }
                        
                        let printRequest = VNGenerateImageFeaturePrintRequest()
                        let printHandler = VNImageRequestHandler(cgImage: faceImage, options: [:])
                        try? printHandler.perform([printRequest])
                        
                        if let prints = printRequest.results, let firstPrint = prints.first as? VNFeaturePrintObservation {
                            
                            // 顔画像の空間的色特徴（8x8グリッド）を取得（3Dキャラ判別用、高解像度化）
                            var faceColor: FaceColor? = nil
                            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                            if let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo) {
                                context.interpolationQuality = .high
                                context.draw(faceImage, in: CGRect(x: 0, y: 0, width: 8, height: 8))
                                if let data = context.data {
                                    let pointer = data.bindMemory(to: UInt8.self, capacity: 256)
                                    var grid = [Float]()
                                    for i in 0..<64 {
                                        let offset = i * 4
                                        grid.append(Float(pointer[offset]) / 255.0)     // R
                                        grid.append(Float(pointer[offset+1]) / 255.0)   // G
                                        grid.append(Float(pointer[offset+2]) / 255.0)   // B
                                    }
                                    faceColor = FaceColor(grid: grid)
                                }
                            }
                            
                            DispatchQueue.main.async {
                                FaceDatabase.shared.addFace(videoID: videoID, boundingBox: boundingBox, featurePrint: firstPrint, faceColor: faceColor)
                            }
                        }
                    }
                }
                
                // 他の処理をブロックしないようにタスクを譲る
                await Task.yield()
            }
        } catch {
            print("Face analysis error: \(error)")
        }
    }
}
