import Foundation
import AppKit
import AVFoundation
import CryptoKit
import Combine

// ===================================
//  VideoDataManager.swift (撮影日時・重複防止対応版)
// ===================================

// MARK: - データモデル
struct VideoItem: Identifiable, Codable, Hashable {
    let id: UUID
    let originalFilename: String
    let internalFilename: String
    let duration: TimeInterval
    let importDate: Date
    // ★ 追加: 動画の撮影日時
    let creationDate: Date?
    // ★ 追加: 動画ファイルのハッシュ値
    let fileHash: String
}

struct Album: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var videoIDs: [UUID]
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

    // MARK: - 初期化
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

    // MARK: - 動画操作
    func importVideo(from sourceURL: URL, to albumID: UUID) async {
        guard albums.contains(where: { $0.id == albumID }) else {
            print("❌ Import failed: Album with ID \(albumID) not found.")
            return
        }
        
        let shouldStopAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if shouldStopAccessing { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            // ★ 追加: ファイルハッシュを計算して、重複をチェック
            let fileHash = try computeFileHash(for: sourceURL)
            if let existingVideo = videos.first(where: { $0.fileHash == fileHash }) {
                print("ℹ️ Video already exists. Adding to album.")
                if let albumIndex = albums.firstIndex(where: { $0.id == albumID }),
                   !albums[albumIndex].videoIDs.contains(existingVideo.id) {
                    albums[albumIndex].videoIDs.append(existingVideo.id)
                    saveData()
                }
                return
            }

            let newVideoID = UUID()
            let fileExtension = sourceURL.pathExtension
            let internalFilename = "\(newVideoID.uuidString).\(fileExtension)"
            let destinationURL = videoStorageURL.appendingPathComponent(internalFilename)
            
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            
            let asset = AVURLAsset(url: destinationURL)
            let duration = try? await asset.load(.duration).seconds
            
            // ★ 追加: 動画の撮影日時を取得
            var creationDate: Date? = nil
            if #available(macOS 13.0, *) {
                creationDate = try? await asset.load(.creationDate)?.load(.dateValue)
            } else if #available(macOS 12.0, *) {
                let creationDateMetadata = try? await asset.load(.creationDate)
                creationDate = creationDateMetadata?.dateValue
            }
            
            // ★ 修正: 撮影日時とハッシュ値を含めて新しいビデオを作成
            let newVideo = VideoItem(id: newVideoID,
                                     originalFilename: sourceURL.lastPathComponent,
                                     internalFilename: internalFilename,
                                     duration: duration ?? 0,
                                     importDate: Date(),
                                     creationDate: creationDate,
                                     fileHash: fileHash)
            
            videos.append(newVideo)
            if let index = albums.firstIndex(where: { $0.id == albumID }) {
                albums[index].videoIDs.append(newVideoID)
            }
            
            // "ALL VIDEOS" にも追加
            if let allVideosIndex = albums.firstIndex(where: { $0.name == allVideosAlbumName }) {
                albums[allVideosIndex].videoIDs.append(newVideoID)
            }
            
            saveData()
        } catch {
            print("❌ Failed to import video: \(error.localizedDescription)")
        }
    }

    func deleteVideos(videoIDs: [UUID]) {
        // まず、どのアルバムからもビデオIDを削除する
        for i in 0..<albums.count {
            albums[i].videoIDs.removeAll { videoIDs.contains($0) }
        }
        
        // 次に、ビデオが他のどのアルバムにも属していないことを確認する
        let videoIDsToDelete = videoIDs.filter { videoID in
            !albums.contains { $0.videoIDs.contains(videoID) }
        }
        
        // どのアルバムにも属さなくなったビデオファイルのみを削除
        for videoID in videoIDsToDelete {
            if let videoItem = videos.first(where: { $0.id == videoID }) {
                let videoURL = videoStorageURL.appendingPathComponent(videoItem.internalFilename)
                let thumbnailURL = thumbnailStorageURL.appendingPathComponent(videoItem.id.uuidString).appendingPathExtension("jpg")
                try? FileManager.default.removeItem(at: videoURL)
                try? FileManager.default.removeItem(at: thumbnailURL)
            }
        }
        
        // 最後に、ビデオのメタデータを削除
        videos.removeAll { videoIDsToDelete.contains($0.id) }
        
        saveData()
    }
    
    // MARK: - アルバム操作
    func createAlbum(name: String) {
        // "ALL VIDEOS" という名前のアルバムは作成できないようにする
        guard name != allVideosAlbumName else { return }
        let newAlbum = Album(id: UUID(), name: name, videoIDs: [])
        albums.append(newAlbum)
        saveData()
    }
    
    func deleteAlbum(albumID: UUID) {
        guard let albumToDelete = albums.first(where: { $0.id == albumID }),
              albumToDelete.name != allVideosAlbumName else { return }
        
        // アルバムを削除しても、中のビデオは削除しない
        albums.removeAll { $0.id == albumID }
        saveData()
    }
    
    func moveVideos(videoIDs: [UUID], to targetAlbumID: UUID) {
        guard albums.contains(where: { $0.id == targetAlbumID }) else { return }
        
        // 移動元アルバムからは削除しない（移動というよりコピー/追加に近い挙動）
        if let targetIndex = albums.firstIndex(where: { $0.id == targetAlbumID }) {
            let existingIDs = Set(albums[targetIndex].videoIDs)
            let newIDs = videoIDs.filter { !existingIDs.contains($0) }
            albums[targetIndex].videoIDs.append(contentsOf: newIDs)
        }
        
        saveData()
    }

    // MARK: - データ永続化
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
                setupInitialAlbum()
                saveData()
                return
            }
            
            let container = try JSONDecoder().decode(DataContainer.self, from: data)
            self.videos = container.videos
            self.albums = container.albums
            
            // 起動時に必ず "ALL VIDEOS" が存在するようにし、内容を同期する
            setupInitialAlbum()
            
        } catch {
            print("❌ Failed to load data: \(error). Starting fresh.")
            setupInitialAlbum()
            saveData()
        }
    }
    
    private func setupInitialAlbum() {
        let allVideoIDs = Set(videos.map { $0.id })
        
        if var allVideosAlbum = albums.first(where: { $0.name == allVideosAlbumName }) {
            // "ALL VIDEOS" がすでにある場合は、内容を更新
            if Set(allVideosAlbum.videoIDs) != allVideoIDs {
                if let index = albums.firstIndex(where: { $0.id == allVideosAlbum.id }) {
                    albums[index].videoIDs = Array(allVideoIDs)
                }
            }
        } else {
            // "ALL VIDEOS" がない場合は、新規作成して先頭に追加
            let newAllVideosAlbum = Album(id: UUID(), name: allVideosAlbumName, videoIDs: Array(allVideoIDs))
            albums.insert(newAllVideosAlbum, at: 0)
        }
    }
    
    // MARK: - ヘルパー関数
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
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

