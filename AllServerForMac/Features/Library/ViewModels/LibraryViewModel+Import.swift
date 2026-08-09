import AppKit
import AVFoundation
import Combine
import CryptoKit
import Darwin
import Dispatch
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

extension LibraryViewModel {
    func scanFolder(folderURL: URL) -> (videoCount: Int, photoCount: Int) {
        let shouldStopAccessing = folderURL.startAccessingSecurityScopedResource()
        defer { if shouldStopAccessing { folderURL.stopAccessingSecurityScopedResource() } }

        var videoCount = 0
        var photoCount = 0
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }

        for case let url as URL in enumerator {
            guard let resourceValues = try? url.resourceValues(forKeys: keys),
                  resourceValues.isRegularFile == true else {
                continue
            }

            if isSupportedPhoto(url) {
                photoCount += 1
            } else if isSupportedVideo(url) {
                videoCount += 1
            }
        }

        return (videoCount, photoCount)
    }

    func importFolder(folderURL: URL, as albumType: AlbumType, parentAlbumName: String? = nil, onItemProcessed: @MainActor @escaping () -> Void = {}) async {
        let shouldStopAccessing = folderURL.startAccessingSecurityScopedResource()
        defer { if shouldStopAccessing { folderURL.stopAccessingSecurityScopedResource() } }

        await importFolderContents(folderURL: folderURL, as: albumType, parentAlbumName: parentAlbumName, onItemProcessed: onItemProcessed)
        reconcileLinkedFoldersFromExistingPaths()
    }

    func importFolderContents(folderURL: URL, as albumType: AlbumType, parentAlbumName: String?, onItemProcessed: @MainActor @escaping () -> Void) async {
        let folderName = folderURL.lastPathComponent
        let albumName = parentAlbumName.map { "\($0)/\(folderName)" } ?? folderName

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let sortedContents = contents.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let mediaFiles = sortedContents.filter { url in
            !isDirectory(url) && isSupportedMedia(url, for: albumType)
        }

        var targetAlbumID: UUID?
        if !mediaFiles.isEmpty {
            if let existingAlbum = albums.first(where: { $0.name == albumName && $0.type == albumType }) {
                targetAlbumID = existingAlbum.id
            } else {
                let newID = UUID()
                targetAlbumID = newID
                albums.append(Album(id: newID, name: albumName, videoIDs: [], type: albumType))
                saveData()
            }
        }

        if let targetAlbumID {
            await importMediaBatch(urls: mediaFiles, to: targetAlbumID, onItemProcessed: onItemProcessed)
        }

        // 以前は画像のときだけサブフォルダを再帰していたため、動画がサブフォルダに
        // まとまっているフォルダ構成だとトップ階層に対象ファイルが1件も見つからず、
        // アルバムそのものが作られない（＝インポートが何も起きないように見える）ことがあった。
        // 動画・混在でも同様に再帰する。
        for url in sortedContents where isDirectory(url) && !isExcludedFromImport(url) {
            await importFolderContents(folderURL: url, as: albumType, parentAlbumName: albumName, onItemProcessed: onItemProcessed)
        }
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// フォルダ再帰インポート時に無視するディレクトリ名。
    /// Python の venv や node_modules 等は写真フォルダの隣に置かれがちで、
    /// 中には各パッケージのテスト用画像が大量かつ深く（8階層超）ネストされている。
    /// これをそのまま再帰すると、数百件の無関係なネストされたアルバムが自動生成され、
    /// サイドバーのフォルダツリー描画がSwiftUIのレイアウト再帰上限を超えてクラッシュする
    /// （フォルダ紐づけ候補の自動リンクで実際に発生した障害）。
    static let importExcludedDirectoryNames: Set<String> = [
        "venv", ".venv", "env", ".env",
        "node_modules", "site-packages",
        "__pycache__", ".git", ".svn", ".hg",
        "dist", "build", "Pods", "DerivedData"
    ]

    func isExcludedFromImport(_ url: URL) -> Bool {
        Self.importExcludedDirectoryNames.contains(url.lastPathComponent)
    }

    func isSupportedMedia(_ url: URL, for albumType: AlbumType) -> Bool {
        switch albumType {
        case .photo:
            return isSupportedPhoto(url)
        case .video:
            return isSupportedVideo(url)
        case .mixed:
            return isSupportedPhoto(url) || isSupportedVideo(url)
        }
    }

    func isSupportedPhoto(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        let fallbackExtensions = Set(["jpg", "jpeg", "png", "heic", "webp", "gif", "tiff"])
        return UTType(filenameExtension: fileExtension)?.conforms(to: .image) == true || fallbackExtensions.contains(fileExtension)
    }

    func isSupportedVideo(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        let fallbackExtensions = Set(["mp4", "mov", "m4v", "avi"])
        return UTType(filenameExtension: fileExtension)?.conforms(to: .movie) == true || fallbackExtensions.contains(fileExtension)
    }

    func importMediaFiles(from sourceURLs: [URL], to albumID: UUID, onItemProcessed: @MainActor @escaping () -> Void = {}) async {
        guard !sourceURLs.isEmpty else { return }
        await importMediaBatch(urls: sourceURLs, to: albumID, onItemProcessed: onItemProcessed)
    }

    /// 大量ファイルの一括インポート用。
    /// - videos/albums への反映（＝ @Published 発火）を1件ごとに行うと、件数の分だけギャラリー・
    ///   サイドバー等のビュー全体が再描画され致命的に重くなるため、一定件数ごと・最後にまとめて反映する。
    /// - 動画1本ごとの尺・撮影日時の読み込み（AVAsset）を直列に1件ずつ行うと、動画が多いフォルダは
    ///   ファイル数に比例して時間がかかり「固まって進まない」ように見える。そのため同時実行数を
    ///   制限しつつ複数ファイルを並行処理する（ファイル記述子・メモリを使い切らないよう上限を設ける）。
    func importMediaBatch(
        urls: [URL],
        to albumID: UUID,
        onItemProcessed: @MainActor @escaping () -> Void = {},
        forceReferenceOriginals: Bool = false
    ) async {
        guard let targetAlbum = albums.first(where: { $0.id == albumID }) else { return }
        let targetAlbumType = targetAlbum.type
        let downloadStorageURL = self.downloadStorageURL
        let managedCopyURL: URL? = forceReferenceOriginals ? nil : (importCopiesFiles ? videoStorageURL : nil)

        var pendingItems: [VideoItem] = []
        var failedCount = 0
        var completedSinceFlush = 0

        func flushPending() {
            guard !pendingItems.isEmpty else { return }
            videos.append(contentsOf: pendingItems)

            let allIDs = pendingItems.map { $0.id }
            if let index = albums.firstIndex(where: { $0.id == albumID }) {
                albums[index].videoIDs.append(contentsOf: allIDs)
            }
            let photoIDs = pendingItems.filter { $0.mediaType == .photo }.map { $0.id }
            let videoIDs = pendingItems.filter { $0.mediaType == .video }.map { $0.id }
            if !photoIDs.isEmpty, let idx = albums.firstIndex(where: { $0.name == LibraryViewModel.allPhotosAlbumName }) {
                albums[idx].videoIDs.append(contentsOf: photoIDs)
            }
            if !videoIDs.isEmpty, let idx = albums.firstIndex(where: { $0.name == LibraryViewModel.allVideosAlbumName }) {
                albums[idx].videoIDs.append(contentsOf: videoIDs)
            }
            pendingItems.removeAll(keepingCapacity: true)
        }

        let maxConcurrent = max(1, min(importConcurrency, 8))
        var nextIndex = 0

        await withTaskGroup(of: VideoItem?.self) { group in
            func addNextTask() {
                guard nextIndex < urls.count else { return }
                let url = urls[nextIndex]
                nextIndex += 1
                group.addTask {
                    await LibraryViewModel.buildImportedItem(from: url, targetAlbumType: targetAlbumType, downloadStorageURL: downloadStorageURL, copyIntoManagedStorage: managedCopyURL)
                }
            }

            for _ in 0..<maxConcurrent { addNextTask() }

            while let result = await group.next() {
                if let item = result {
                    pendingItems.append(item)
                } else {
                    failedCount += 1
                }
                completedSinceFlush += 1
                onItemProcessed()
                addNextTask()

                // 貯め続けるとメモリ・保存間隔が伸びすぎるため、一定件数ごとにも反映＋保存する
                if completedSinceFlush >= 200 {
                    flushPending()
                    saveData()
                    completedSinceFlush = 0
                }
            }
        }

        flushPending()
        saveData()

        if failedCount > 0 {
            print("⚠️ [IMPORT] \(failedCount)件のメディアをインポートできませんでした。")
        }
    }

    @discardableResult
    func importMedia(from sourceURL: URL, to albumID: UUID, customFilename: String? = nil, saveImmediately: Bool = true) async -> Bool {
        guard let targetAlbum = albums.first(where: { $0.id == albumID }) else { return false }
        guard let newItem = await LibraryViewModel.buildImportedItem(from: sourceURL, targetAlbumType: targetAlbum.type, downloadStorageURL: downloadStorageURL, customFilename: customFilename, copyIntoManagedStorage: (customFilename == nil && importCopiesFiles) ? videoStorageURL : nil) else {
            return false
        }

        videos.append(newItem)
        if let index = albums.firstIndex(where: { $0.id == albumID }) { albums[index].videoIDs.append(newItem.id) }
        if newItem.mediaType == .photo {
            if let idx = albums.firstIndex(where: { $0.name == LibraryViewModel.allPhotosAlbumName }) { albums[idx].videoIDs.append(newItem.id) }
        } else {
            if let idx = albums.firstIndex(where: { $0.name == LibraryViewModel.allVideosAlbumName }) { albums[idx].videoIDs.append(newItem.id) }
        }

        if saveImmediately { saveData() }
        return true
    }

    /// ファイルのコピー・メタデータ抽出だけを行い、videos/albums には一切触れない。MainActor に一切
    /// 依存しない（nonisolated）ため、一括インポート側は複数ファイルを本当に並行して処理できる。
    nonisolated static func buildImportedItem(from sourceURL: URL, targetAlbumType: AlbumType, downloadStorageURL: URL, customFilename: String? = nil, copyIntoManagedStorage: URL? = nil) async -> VideoItem? {
        let fileExtension = sourceURL.pathExtension
        let type = UTType(filenameExtension: fileExtension)
        let isImage = type?.conforms(to: .image) ?? ["jpg", "jpeg", "png", "heic", "webp", "gif", "tiff"].contains(fileExtension.lowercased())
        let isMovie = type?.conforms(to: .movie) ?? ["mp4", "mov", "m4v", "avi"].contains(fileExtension.lowercased())
        if targetAlbumType == .video && isImage { return nil }
        if targetAlbumType == .photo && isMovie { return nil }

        let shouldStopAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if shouldStopAccessing { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
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
            } else if let managedStorageURL = copyIntoManagedStorage {
                // 設定「インポート時にファイルをアプリ内へコピー」が有効な場合。
                // 元フォルダが後で消えてもサーバー内に実体が残る（アプリ管理ファイルなので
                // ライブラリから完全削除すればファイルも一緒に消える）。
                internalFilename = fileExtension.isEmpty ? newID.uuidString : "\(newID.uuidString).\(fileExtension)"
                let destinationURL = managedStorageURL.appendingPathComponent(internalFilename)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                urlForMetadata = destinationURL
                externalPath = nil
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
                return nil
            }

            return await MainActor.run {
                VideoItem(id: newID, originalFilename: customFilename ?? originalName, internalFilename: internalFilename, duration: duration, importDate: Date(), creationDate: creationDate, fileHash: "", mediaType: mediaType, externalFilePath: externalPath)
            }
        } catch {
            print("⚠️ [IMPORT] \(sourceURL.lastPathComponent) のインポートに失敗しました: \(error)")
            return nil
        }
    }

    /// path が directory の「中」にあるかをディレクトリ境界込みで判定する。
    /// 素朴な hasPrefix 比較だと "/Downloads/VideoServerForMac_Media_backup" のような
    /// 兄弟フォルダが "/Downloads/VideoServerForMac_Media" のprefixに一致してしまい、
    /// アプリ管理外のファイルを誤って削除する原因になる。
    nonisolated static func isPath(_ path: String, inside directory: URL) -> Bool {
        let dirPath = directory.path
        return path == dirPath || path.hasPrefix(dirPath.hasSuffix("/") ? dirPath : dirPath + "/")
    }

    func isAppManagedPath(_ path: String) -> Bool {
        Self.isPath(path, inside: downloadStorageURL) || Self.isPath(path, inside: videoStorageURL)
    }
}
