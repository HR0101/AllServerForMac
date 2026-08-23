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
    func saveData() {
        // 二重起動側のインスタンスは一切書き込まない（後勝ちによるサイレント消失防止）
        guard isReadyForOperations, isLibraryLoaded else { return }
        saveGeneration += 1
        let generation = saveGeneration
        let container = DataContainer(videos: videos, albums: albums, duplicateCheckStates: duplicateCheckStates, schemaVersion: Self.librarySchemaVersion)
        let url = dataFileURL

        pendingSaveTask?.cancel()
        pendingSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            LibraryViewModel.saveQueue.async {
                // より新しい世代が既に書かれていたら、この古いスナップショットは破棄する
                guard generation > LibraryViewModel.lastWrittenSaveGeneration else { return }
                LibraryViewModel.lastWrittenSaveGeneration = generation
                LibraryViewModel.writeContainer(container, to: url)
            }
        }
    }

    nonisolated static func writeContainer(_ container: DataContainer, to url: URL) {
        guard let data = try? JSONEncoder().encode(container) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 保留中の非同期保存があれば取り消し、現在の状態を同期的に書き込む（アプリ終了時用）
    func flushPendingSave() {
        guard isReadyForOperations, isLibraryLoaded else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        saveGeneration += 1
        let generation = saveGeneration
        let container = DataContainer(videos: videos, albums: albums, duplicateCheckStates: duplicateCheckStates, schemaVersion: Self.librarySchemaVersion)
        let url = dataFileURL
        // 同期実行: キューに残っている古い書き込みを先に流し切ったうえで、
        // 最新世代として書き込み、以降に紛れ込む古い世代の上書きを世代番号で防ぐ。
        LibraryViewModel.saveQueue.sync {
            guard generation > LibraryViewModel.lastWrittenSaveGeneration else { return }
            LibraryViewModel.lastWrittenSaveGeneration = generation
            LibraryViewModel.writeContainer(container, to: url)
        }
    }
    var backupFileURL: URL { appRootURL.appendingPathComponent("library.backup.json") }

    func startLoadingData() {
        guard isReadyForOperations, libraryLoadTask == nil else { return }
        let dataFileURL = self.dataFileURL
        let appRootURL = self.appRootURL

        libraryLoadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.loadLibrary(
                    dataFileURL: dataFileURL,
                    appRootURL: appRootURL
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            self.applyLibraryLoadResult(result)
            self.libraryLoadTask = nil
        }
    }

    nonisolated static func loadLibrary(
        dataFileURL: URL,
        appRootURL: URL
    ) -> LibraryLoadResult {
        let fileManager = FileManager.default
        let backupURLs = backupGenerationURLs(for: appRootURL)

        guard fileManager.fileExists(atPath: dataFileURL.path),
              let data = try? Data(contentsOf: dataFileURL),
              !data.isEmpty else {
            return .empty
        }

        if let container = try? JSONDecoder().decode(DataContainer.self, from: data) {
            let isNewerSchema = (container.schemaVersion ?? 0) > librarySchemaVersion
            if isNewerSchema {
                print("⚠️ [LOAD] library.json はこのバージョンより新しい形式（v\(container.schemaVersion ?? 0)）です。バックアップの更新をスキップします。")
            }

            let shouldSkipBackup = isNewerSchema
                || (container.videos.isEmpty && fileManager.fileExists(atPath: backupURLs[0].path))
            if !shouldSkipBackup {
                rotateBackups(with: data, backupURLs: backupURLs)
            }
            return .loaded(prepareLoadedContainer(container))
        }

        let corruptedURL = appRootURL.appendingPathComponent(
            "library.corrupted-\(Int(Date().timeIntervalSince1970)).json"
        )
        try? fileManager.copyItem(at: dataFileURL, to: corruptedURL)
        print("⚠️ [LOAD] library.json が破損していたため \(corruptedURL.lastPathComponent) に退避しました")

        for backupURL in backupURLs {
            if let backupData = try? Data(contentsOf: backupURL),
               let container = try? JSONDecoder().decode(DataContainer.self, from: backupData) {
                print("✅ [LOAD] バックアップ（\(backupURL.lastPathComponent)）から復元しました")
                return .recovered(prepareLoadedContainer(container))
            }
        }

        return .empty
    }

    nonisolated static func backupGenerationURLs(for appRootURL: URL) -> [URL] {
        [
            appRootURL.appendingPathComponent("library.backup.json"),
            appRootURL.appendingPathComponent("library.backup.2.json"),
            appRootURL.appendingPathComponent("library.backup.3.json"),
        ]
    }

    nonisolated static func rotateBackups(with data: Data, backupURLs: [URL]) {
        guard backupURLs.count == 3 else { return }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: backupURLs[2])
        if fileManager.fileExists(atPath: backupURLs[1].path) {
            try? fileManager.moveItem(at: backupURLs[1], to: backupURLs[2])
        }
        if fileManager.fileExists(atPath: backupURLs[0].path) {
            try? fileManager.moveItem(at: backupURLs[0], to: backupURLs[1])
        }
        try? data.write(to: backupURLs[0], options: .atomic)
    }

    nonisolated static func prepareLoadedContainer(
        _ container: DataContainer
    ) -> DataContainer {
        var prepared = container
        var videoIDs = Set<UUID>()
        var photoIDs = Set<UUID>()

        for item in prepared.videos {
            switch item.mediaType {
            case .video:
                videoIDs.insert(item.id)
            case .photo:
                photoIDs.insert(item.id)
            }
        }

        updateSystemAlbum(
            name: allVideosAlbumName,
            type: .video,
            ids: videoIDs,
            albums: &prepared.albums
        )
        updateSystemAlbum(
            name: allPhotosAlbumName,
            type: .photo,
            ids: photoIDs,
            albums: &prepared.albums
        )

        let albumIDs = Set(prepared.albums.map(\.id))
        prepared.duplicateCheckStates = prepared.duplicateCheckStates?.filter {
            albumIDs.contains($0.key)
        }
        return prepared
    }

    nonisolated static func updateSystemAlbum(
        name: String,
        type: AlbumType,
        ids: Set<UUID>,
        albums: inout [Album]
    ) {
        if let index = albums.firstIndex(where: { $0.name == name }) {
            albums[index].videoIDs = Array(ids)
            albums[index].type = type
        } else {
            albums.insert(
                Album(id: UUID(), name: name, videoIDs: Array(ids), type: type),
                at: 0
            )
        }
    }

    func applyLibraryLoadResult(_ result: LibraryLoadResult) {
        switch result {
        case .loaded(let container):
            applyLoadedContainer(container)
        case .recovered(let container):
            applyLoadedContainer(container)
        case .empty:
            setupInitialAlbums()
        }

        isLibraryLoaded = true
        if case .loaded = result {
            startPostLoadTasks()
        } else {
            saveData()
            startPostLoadTasks()
        }
    }

    func startPostLoadTasks() {
        startMissingSymlinkRepair()
        startAutomaticDuplicateChecks(
            initialDelayNanoseconds: Self.duplicateCheckStartupDelayNanoseconds
        )
        startStorageSizeAutoRefresh(
            initialDelayNanoseconds: Self.storageRefreshStartupDelayNanoseconds
        )
        startDeferredLibraryMaintenance()
        startInitialLinkedFolderScan()
    }

    func startDeferredLibraryMaintenance() {
        guard startupMaintenanceTask == nil else { return }
        startupMaintenanceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.maintenanceStartupDelayNanoseconds
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }

            self.purgeExpiredTrash()
            if self.autoCleanupMissingFilesEnabled {
                self.runAutomaticMissingFileCleanup()
            }
            self.reconcileLinkedFoldersFromExistingPaths(
                shouldScheduleScans: false
            )
            self.startupMaintenanceTask = nil
        }
    }

    /// バックアップの世代（新しい順）。起動が正常なたびに 1→2→3 へローテーションされる。
    var backupGenerationURLs: [URL] {
        Self.backupGenerationURLs(for: appRootURL)
    }

    func applyLoadedContainer(_ container: DataContainer) {
        videos = container.videos
        albums = container.albums
        duplicateCheckStates = container.duplicateCheckStates ?? [:]
    }
    func setupInitialAlbums() { updateOrCreateSystemAlbum(name: LibraryViewModel.allVideosAlbumName, type: .video, ids: Set(videos.filter { $0.mediaType == .video }.map { $0.id })); updateOrCreateSystemAlbum(name: LibraryViewModel.allPhotosAlbumName, type: .photo, ids: Set(videos.filter { $0.mediaType == .photo }.map { $0.id })) }
    func pruneDuplicateCheckStates() { let albumIDs = Set(albums.map { $0.id }); duplicateCheckStates = duplicateCheckStates.filter { albumIDs.contains($0.key) } }
    func updateOrCreateSystemAlbum(name: String, type: AlbumType, ids: Set<UUID>) { if let index = albums.firstIndex(where: { $0.name == name }) { albums[index].videoIDs = Array(ids); albums[index].type = type } else { albums.insert(Album(id: UUID(), name: name, videoIDs: Array(ids), type: type), at: 0) } }
    nonisolated static func computeFileHash(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 65536)
            if !chunk.isEmpty { hasher.update(data: chunk); return true }
            return false
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
