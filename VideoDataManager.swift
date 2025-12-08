import Foundation
import AppKit
import AVFoundation
import CryptoKit
import Combine
import UniformTypeIdentifiers

// ===================================
//  VideoDataManager.swift (厳密な選別・フォルダスキャン対応版)
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
    let thumbnailStorageURL: URL
    private let dataFileURL: URL
    
    private let allVideosAlbumName = "ALL VIDEOS"
    private let allPhotosAlbumName = "ALL PHOTOS"

    init() {
        guard let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory not found.")
        }
        let appDir = appSupportDir.appendingPathComponent("VideoServerForMac")
        self.videoStorageURL = appDir.appendingPathComponent("Videos")
        self.thumbnailStorageURL = appDir.appendingPathComponent("Thumbnails")
        self.dataFileURL = appDir.appendingPathComponent("library.json")
        
        try? FileManager.default.createDirectory(at: self.videoStorageURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.thumbnailStorageURL, withIntermediateDirectories: true)
        
        loadData()
    }
    
    // MARK: - ★追加: フォルダスキャン（事前の種類判定用）
    func scanFolder(folderURL: URL) -> (videoCount: Int, photoCount: Int) {
        let shouldStopAccessing = folderURL.startAccessingSecurityScopedResource()
        defer { if shouldStopAccessing { folderURL.stopAccessingSecurityScopedResource() } }
        
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return (0, 0)
        }
        
        var videoCount = 0
        var photoCount = 0
        
        for url in contents {
            let ext = url.pathExtension.lowercased()
            if let type = UTType(filenameExtension: ext) {
                if type.conforms(to: .movie) { videoCount += 1 }
                else if type.conforms(to: .image) { photoCount += 1 }
            }
        }
        return (videoCount, photoCount)
    }
    
    // MARK: - ★修正: フォルダインポート (アルバムタイプを指定してインポート)
    func importFolder(folderURL: URL, as albumType: AlbumType) async {
        let folderName = folderURL.lastPathComponent
        let fileManager = FileManager.default
        
        // 1. アルバム作成（既存があれば取得）
        var targetAlbumID: UUID
        if let existingAlbum = albums.first(where: { $0.name == folderName && $0.type == albumType }) {
            targetAlbumID = existingAlbum.id
        } else {
            // 同名のアルバムがあってもタイプが違う場合は、別アルバムとして新規作成する
            targetAlbumID = UUID()
            let newAlbum = Album(id: targetAlbumID, name: folderName, videoIDs: [], type: albumType)
            albums.append(newAlbum)
            saveData()
        }
        
        // 2. 中身をスキャン
        guard let contents = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }
        
        // 3. 各ファイルをインポート（importMedia内でタイプの選別が行われる）
        for url in contents {
            if !url.hasDirectoryPath {
                await importMedia(from: url, to: targetAlbumID)
            }
        }
    }

    // MARK: - インポート処理 (厳密な選別付き)
    func importMedia(from sourceURL: URL, to albumID: UUID) async {
        // アルバム情報の取得
        guard let targetAlbum = albums.first(where: { $0.id == albumID }) else { return }
        
        // ファイルタイプの事前判定（効率化のためコピー前に判定）
        let fileExtension = sourceURL.pathExtension
        let type = UTType(filenameExtension: fileExtension)
        let isImage = type?.conforms(to: .image) ?? ["jpg", "jpeg", "png", "heic", "webp", "gif", "tiff"].contains(fileExtension.lowercased())
        let isMovie = type?.conforms(to: .movie) ?? ["mp4", "mov", "m4v", "avi"].contains(fileExtension.lowercased())
        
        // ★ 選別ロジック: アルバムタイプとファイルの種類が一致しない場合はスキップ
        if targetAlbum.type == .video && isImage {
            print("⚠️ Skipped photo import to video album: \(sourceURL.lastPathComponent)")
            return
        }
        if targetAlbum.type == .photo && isMovie {
            print("⚠️ Skipped video import to photo album: \(sourceURL.lastPathComponent)")
            return
        }
        
        // ここから通常のインポート処理
        let shouldStopAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if shouldStopAccessing { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            let fileHash = try computeFileHash(for: sourceURL)
            
            // 重複チェック
            if let existingItem = videos.first(where: { $0.fileHash == fileHash }) {
                print("ℹ️ Media already exists. Adding to album.")
                if let albumIndex = albums.firstIndex(where: { $0.id == albumID }),
                   !albums[albumIndex].videoIDs.contains(existingItem.id) {
                    albums[albumIndex].videoIDs.append(existingItem.id)
                    saveData()
                }
                return
            }

            let newID = UUID()
            let internalFilename = "\(newID.uuidString).\(fileExtension)"
            let destinationURL = videoStorageURL.appendingPathComponent(internalFilename)
            
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            
            let mediaType: MediaType
            var duration: TimeInterval = 0
            var creationDate: Date? = nil
            
            if isImage {
                mediaType = .photo
                if let attributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path) {
                    creationDate = attributes[.creationDate] as? Date
                }
            } else if isMovie {
                mediaType = .video
                let asset = AVURLAsset(url: destinationURL)
                let durationTime = try? await asset.load(.duration)
                duration = durationTime?.seconds ?? 0
                
                if #available(macOS 13.0, *) {
                    if let creationDateItem = try? await asset.load(.creationDate) {
                        creationDate = try? await creationDateItem.load(.dateValue)
                    }
                } else {
                    let creationDateMetadata = try? await asset.load(.creationDate)
                    creationDate = creationDateMetadata?.dateValue
                }
            } else {
                try? FileManager.default.removeItem(at: destinationURL)
                return
            }
            
            let newItem = VideoItem(id: newID,
                                    originalFilename: sourceURL.lastPathComponent,
                                    internalFilename: internalFilename,
                                    duration: duration,
                                    importDate: Date(),
                                    creationDate: creationDate,
                                    fileHash: fileHash,
                                    mediaType: mediaType)
            
            videos.append(newItem)
            
            // 1. 指定されたアルバムに追加
            if let index = albums.firstIndex(where: { $0.id == albumID }) {
                albums[index].videoIDs.append(newID)
            }
            
            // 2. システムアルバムへの自動追加
            if mediaType == .photo {
                if let allPhotosIndex = albums.firstIndex(where: { $0.name == allPhotosAlbumName }) {
                    albums[allPhotosIndex].videoIDs.append(newID)
                }
            } else {
                if let allVideosIndex = albums.firstIndex(where: { $0.name == allVideosAlbumName }) {
                    albums[allVideosIndex].videoIDs.append(newID)
                }
            }
            
            saveData()
            print("✅ Successfully imported: \(newItem.originalFilename) as \(mediaType)")
            
        } catch {
            print("❌ Failed to import media: \(error.localizedDescription)")
        }
    }

    func deleteVideos(videoIDs: [UUID]) {
        for i in 0..<albums.count {
            albums[i].videoIDs.removeAll { videoIDs.contains($0) }
        }
        
        let idsToDelete = videoIDs.filter { videoID in
            !albums.contains { $0.videoIDs.contains(videoID) }
        }
        
        for id in idsToDelete {
            if let item = videos.first(where: { $0.id == id }) {
                let fileURL = videoStorageURL.appendingPathComponent(item.internalFilename)
                let thumbURL = thumbnailStorageURL.appendingPathComponent(item.id.uuidString).appendingPathExtension("jpg")
                try? FileManager.default.removeItem(at: fileURL)
                try? FileManager.default.removeItem(at: thumbURL)
            }
        }
        
        videos.removeAll { idsToDelete.contains($0.id) }
        saveData()
    }
    
    func createAlbum(name: String, type: AlbumType) {
        guard name != allVideosAlbumName && name != allPhotosAlbumName else { return }
        let newAlbum = Album(id: UUID(), name: name, videoIDs: [], type: type)
        albums.append(newAlbum)
        saveData()
    }
    
    func deleteAlbum(albumID: UUID) {
        guard let album = albums.first(where: { $0.id == albumID }),
              album.name != allVideosAlbumName,
              album.name != allPhotosAlbumName else { return }
        albums.removeAll { $0.id == albumID }
        saveData()
    }
    
    func moveVideos(videoIDs: [UUID], to targetAlbumID: UUID) {
        guard albums.contains(where: { $0.id == targetAlbumID }) else { return }
        if let targetIndex = albums.firstIndex(where: { $0.id == targetAlbumID }) {
            let existingIDs = Set(albums[targetIndex].videoIDs)
            let newIDs = videoIDs.filter { !existingIDs.contains($0) }
            albums[targetIndex].videoIDs.append(contentsOf: newIDs)
        }
        saveData()
    }

    private func saveData() {
        let container = DataContainer(videos: videos, albums: albums)
        do {
            let data = try JSONEncoder().encode(container)
            try data.write(to: dataFileURL, options: .atomic)
        } catch {
            print("❌ Failed to save data: \(error)")
        }
    }

    private func loadData() {
        do {
            guard FileManager.default.fileExists(atPath: dataFileURL.path),
                  let data = try? Data(contentsOf: dataFileURL), !data.isEmpty else {
                setupInitialAlbums()
                saveData()
                return
            }
            
            let container = try JSONDecoder().decode(DataContainer.self, from: data)
            self.videos = container.videos
            self.albums = container.albums
            setupInitialAlbums()
            
        } catch {
            print("❌ Failed to load data: \(error). Starting fresh.")
            setupInitialAlbums()
            saveData()
        }
    }
    
    private func setupInitialAlbums() {
        let allVideoIDs = Set(videos.filter { $0.mediaType == .video }.map { $0.id })
        let allPhotoIDs = Set(videos.filter { $0.mediaType == .photo }.map { $0.id })
        
        updateOrCreateSystemAlbum(name: allVideosAlbumName, type: .video, ids: allVideoIDs)
        updateOrCreateSystemAlbum(name: allPhotosAlbumName, type: .photo, ids: allPhotoIDs)
    }
    
    private func updateOrCreateSystemAlbum(name: String, type: AlbumType, ids: Set<UUID>) {
        if let index = albums.firstIndex(where: { $0.name == name }) {
            albums[index].videoIDs = Array(ids)
            albums[index].type = type
        } else {
            let newAlbum = Album(id: UUID(), name: name, videoIDs: Array(ids), type: type)
            albums.insert(newAlbum, at: 0)
        }
    }
    
    private func computeFileHash(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 8192)
            if !chunk.isEmpty {
                hasher.update(data: chunk)
                return true
            } else {
                return false
            }
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
