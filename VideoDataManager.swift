import Foundation
import AppKit
import AVFoundation
import CryptoKit
import Combine
import UniformTypeIdentifiers

// ===================================
//  VideoDataManager.swift (1080p/540pプロキシ生成版)
// ===================================

// MARK: - データモデル

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
    let internalFilename: String
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
    
    let videoStorageURL: URL
    let downloadStorageURL: URL
    let thumbnailStorageURL: URL
    let proxyStorageURL: URL // 軽量版（プロキシ）動画の保存場所
    private let dataFileURL: URL
    
    private let allVideosAlbumName = "ALL VIDEOS"
    private let allPhotosAlbumName = "ALL PHOTOS"

    init() {
        guard let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory not found.")
        }
        guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            fatalError("Downloads directory not found.")
        }
        
        let appDir = appSupportDir.appendingPathComponent("VideoServerForMac")
        self.videoStorageURL = appDir.appendingPathComponent("Videos")
        self.thumbnailStorageURL = appDir.appendingPathComponent("Thumbnails")
        self.proxyStorageURL = appDir.appendingPathComponent("Proxies")
        self.dataFileURL = appDir.appendingPathComponent("library.json")
        self.downloadStorageURL = downloadsDir.appendingPathComponent("VideoServerForMac_Media")
        
        try? FileManager.default.createDirectory(at: self.videoStorageURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.downloadStorageURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.thumbnailStorageURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.proxyStorageURL, withIntermediateDirectories: true)
        
        if FileManager.default.fileExists(atPath: self.downloadStorageURL.path) {
            if let contents = try? FileManager.default.contentsOfDirectory(at: self.downloadStorageURL, includingPropertiesForKeys: nil) {
                for url in contents {
                    let filenameWithoutExt = url.deletingPathExtension().lastPathComponent
                    if UUID(uuidString: filenameWithoutExt) != nil {
                        let destURL = self.videoStorageURL.appendingPathComponent(url.lastPathComponent)
                        if !FileManager.default.fileExists(atPath: destURL.path) {
                            try? FileManager.default.moveItem(at: url, to: destURL)
                        } else {
                            try? FileManager.default.removeItem(at: url)
                        }
                    }
                }
            }
        }
        
        loadData()
        
        // 起動時に軽量版(1080p / 540p)がまだ作られていない動画があれば裏で生成を開始
        Task {
            await generateMissingProxies()
        }
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
    
    // MARK: - 軽量版生成処理 (1080p & 540p)
    private func generateMissingProxies() async {
        let items = videos.filter { $0.mediaType == .video }
        for item in items {
            if let sourceURL = fileURL(for: item) {
                // 1080p の生成
                let proxy1080URL = proxyStorageURL.appendingPathComponent("\(item.id.uuidString)_1080p.mp4")
                if !FileManager.default.fileExists(atPath: proxy1080URL.path) {
                    await generateProxy(sourceURL: sourceURL, destinationURL: proxy1080URL, preset: AVAssetExportPreset1920x1080)
                }
                
                // 540p の生成
                let proxy540URL = proxyStorageURL.appendingPathComponent("\(item.id.uuidString)_540p.mp4")
                if !FileManager.default.fileExists(atPath: proxy540URL.path) {
                    await generateProxy(sourceURL: sourceURL, destinationURL: proxy540URL, preset: AVAssetExportPreset960x540)
                }
            }
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
        
        if exportSession.status == .completed {
            print("✅ 軽量版(\(preset))の生成完了: \(sourceURL.lastPathComponent)")
        } else {
            print("❌ 軽量版(\(preset))の生成失敗または不要: \(exportSession.error?.localizedDescription ?? "Unknown error")")
            try? FileManager.default.removeItem(at: destinationURL)
        }
    }
    
    // MARK: - データ集計・操作
    var recentItems: [VideoItem] {
        Array(videos.sorted { $0.importDate > $1.importDate }.prefix(10))
    }
    
    func calculateTotalStorageSize() -> String {
        let totalSize = videos.reduce(Int64(0)) { result, item in
            guard let url = fileURL(for: item) else { return result }
            let resources = try? url.resourceValues(forKeys: [.fileSizeKey])
            return result + Int64(resources?.fileSize ?? 0)
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
    
    func clearThumbnailCache() {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: thumbnailStorageURL, includingPropertiesForKeys: nil)
            for url in fileURLs { try FileManager.default.removeItem(at: url) }
        } catch {}
    }
    
    func scanFolder(folderURL: URL) -> (videoCount: Int, photoCount: Int) {
        let shouldStopAccessing = folderURL.startAccessingSecurityScopedResource()
        defer { if shouldStopAccessing { folderURL.stopAccessingSecurityScopedResource() } }
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return (0, 0) }
        
        var videoCount = 0; var photoCount = 0
        for url in contents {
            let ext = url.pathExtension.lowercased()
            if let type = UTType(filenameExtension: ext) {
                if type.conforms(to: .movie) { videoCount += 1 } else if type.conforms(to: .image) { photoCount += 1 }
            }
        }
        return (videoCount, photoCount)
    }
    
    func importFolder(folderURL: URL, as albumType: AlbumType) async {
        let folderName = folderURL.lastPathComponent
        let fileManager = FileManager.default
        var targetAlbumID: UUID
        if let existingAlbum = albums.first(where: { $0.name == folderName && $0.type == albumType }) {
            targetAlbumID = existingAlbum.id
        } else {
            targetAlbumID = UUID()
            let newAlbum = Album(id: targetAlbumID, name: folderName, videoIDs: [], type: albumType)
            albums.append(newAlbum)
            saveData()
        }
        guard let contents = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }
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
                if let albumIndex = albums.firstIndex(where: { $0.id == albumID }),
                   !albums[albumIndex].videoIDs.contains(existingItem.id) {
                    albums[albumIndex].videoIDs.append(existingItem.id)
                    saveData()
                }
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
            } else {
                externalPath = sourceURL.path
                urlForMetadata = sourceURL
            }
            
            let mediaType: MediaType
            var duration: TimeInterval = 0
            var creationDate: Date? = nil
            
            if isImage {
                mediaType = .photo
                if let attributes = try? FileManager.default.attributesOfItem(atPath: urlForMetadata.path) {
                    creationDate = attributes[.creationDate] as? Date
                }
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
            
            // ★ 新しくインポートした動画の軽量版を裏で作成
            if mediaType == .video {
                if let sourceForProxy = fileURL(for: newItem) {
                    let proxy1080URL = proxyStorageURL.appendingPathComponent("\(newID.uuidString)_1080p.mp4")
                    let proxy540URL = proxyStorageURL.appendingPathComponent("\(newID.uuidString)_540p.mp4")
                    Task {
                        await generateProxy(sourceURL: sourceForProxy, destinationURL: proxy1080URL, preset: AVAssetExportPreset1920x1080)
                        await generateProxy(sourceURL: sourceForProxy, destinationURL: proxy540URL, preset: AVAssetExportPreset960x540)
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
                if item.externalFilePath == nil {
                    if let fileURL = fileURL(for: item) { try? FileManager.default.removeItem(at: fileURL) }
                }
                let thumbURL = thumbnailStorageURL.appendingPathComponent(item.id.uuidString).appendingPathExtension("jpg")
                try? FileManager.default.removeItem(at: thumbURL)
                
                // ★ プロキシファイルも両方削除
                let proxy1080URL = proxyStorageURL.appendingPathComponent("\(item.id.uuidString)_1080p.mp4")
                try? FileManager.default.removeItem(at: proxy1080URL)
                let proxy540URL = proxyStorageURL.appendingPathComponent("\(item.id.uuidString)_540p.mp4")
                try? FileManager.default.removeItem(at: proxy540URL)
            }
        }
        videos.removeAll { idsToDelete.contains($0.id) }
        saveData()
    }
    
    func removeVideosFromAlbum(videoIDs: [UUID], albumID: UUID) {
        if let index = albums.firstIndex(where: { $0.id == albumID }) {
            let name = albums[index].name
            if name == allVideosAlbumName || name == allPhotosAlbumName { deleteVideos(videoIDs: videoIDs) } else { albums[index].videoIDs.removeAll { videoIDs.contains($0) }; saveData() }
        }
    }
    
    func createAlbum(name: String, type: AlbumType) { guard name != allVideosAlbumName && name != allPhotosAlbumName else { return }; albums.append(Album(id: UUID(), name: name, videoIDs: [], type: type)); saveData() }
    func deleteAlbum(albumID: UUID) { guard let album = albums.first(where: { $0.id == albumID }), album.name != allVideosAlbumName, album.name != allPhotosAlbumName else { return }; albums.removeAll { $0.id == albumID }; saveData() }
    func moveVideos(videoIDs: [UUID], from sourceAlbumID: UUID, to targetAlbumID: UUID) { guard albums.contains(where: { $0.id == targetAlbumID }) else { return }; if let sourceIndex = albums.firstIndex(where: { $0.id == sourceAlbumID }), albums[sourceIndex].name != allVideosAlbumName, albums[sourceIndex].name != allPhotosAlbumName { albums[sourceIndex].videoIDs.removeAll { videoIDs.contains($0) } }; if let targetIndex = albums.firstIndex(where: { $0.id == targetAlbumID }) { let existingIDs = Set(albums[targetIndex].videoIDs); let newIDs = videoIDs.filter { !existingIDs.contains($0) }; albums[targetIndex].videoIDs.append(contentsOf: newIDs) }; saveData() }

    private func saveData() { do { let data = try JSONEncoder().encode(DataContainer(videos: videos, albums: albums)); try data.write(to: dataFileURL, options: .atomic) } catch {} }
    private func loadData() { do { guard FileManager.default.fileExists(atPath: dataFileURL.path), let data = try? Data(contentsOf: dataFileURL), !data.isEmpty else { setupInitialAlbums(); saveData(); return }; let container = try JSONDecoder().decode(DataContainer.self, from: data); self.videos = container.videos; self.albums = container.albums; setupInitialAlbums() } catch { setupInitialAlbums(); saveData() } }
    private func setupInitialAlbums() { updateOrCreateSystemAlbum(name: allVideosAlbumName, type: .video, ids: Set(videos.filter { $0.mediaType == .video }.map { $0.id })); updateOrCreateSystemAlbum(name: allPhotosAlbumName, type: .photo, ids: Set(videos.filter { $0.mediaType == .photo }.map { $0.id })) }
    private func updateOrCreateSystemAlbum(name: String, type: AlbumType, ids: Set<UUID>) { if let index = albums.firstIndex(where: { $0.name == name }) { albums[index].videoIDs = Array(ids); albums[index].type = type } else { albums.insert(Album(id: UUID(), name: name, videoIDs: Array(ids), type: type), at: 0) } }
    private func computeFileHash(for url: URL) throws -> String { let handle = try FileHandle(forReadingFrom: url); var hasher = SHA256(); while autoreleasepool(invoking: { let chunk = handle.readData(ofLength: 8192); if !chunk.isEmpty { hasher.update(data: chunk); return true } else { return false } }) {}; return hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}
