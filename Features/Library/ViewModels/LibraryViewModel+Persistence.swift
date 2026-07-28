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
        guard !isSecondaryInstance else { return }
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
        guard !isSecondaryInstance else { return }
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

    func loadData() {
        guard FileManager.default.fileExists(atPath: dataFileURL.path),
              let data = try? Data(contentsOf: dataFileURL), !data.isEmpty else {
            setupInitialAlbums()
            saveData()
            return
        }

        if let container = try? JSONDecoder().decode(DataContainer.self, from: data) {
            applyLoadedContainer(container)
            // 正常に読めたスナップショットをバックアップとして残す（次回破損時の復元用）。
            // 「デコードできた」だけで空に近いライブラリを世代1に上書きすると、良いバックアップまで
            // 汚染されるため、中身が空で既存バックアップがある場合は更新しない。
            // また1世代だと汚染に弱いため、3世代でローテーションする。
            // さらに、自分より新しいスキーマ世代のデータを読んだ場合もバックアップを更新しない
            // （この古いビルドが知らないフィールドを落とした内容で新形式のバックアップを汚さないため）。
            let isNewerSchema = (container.schemaVersion ?? 0) > Self.librarySchemaVersion
            if isNewerSchema {
                print("⚠️ [LOAD] library.json はこのバージョンより新しい形式（v\(container.schemaVersion ?? 0)）です。バックアップの更新をスキップします。")
            }
            let shouldSkipBackup = isNewerSchema || (container.videos.isEmpty && FileManager.default.fileExists(atPath: backupFileURL.path))
            if !shouldSkipBackup {
                let urls = backupGenerationURLs
                Task.detached(priority: .utility) {
                    let fm = FileManager.default
                    try? fm.removeItem(at: urls[2])
                    if fm.fileExists(atPath: urls[1].path) { try? fm.moveItem(at: urls[1], to: urls[2]) }
                    if fm.fileExists(atPath: urls[0].path) { try? fm.moveItem(at: urls[0], to: urls[1]) }
                    try? data.write(to: urls[0], options: .atomic)
                }
            }
            return
        }

        // ここに来るのは library.json が壊れて読めないとき。
        // 以前はこの場で空のライブラリを保存し直しており、全アルバム構成・参照・お気に入りが
        // 一瞬で失われる事故につながっていた。壊れたファイルは必ず退避してから、
        // バックアップ（新しい世代から順）での復元を試み、それも無い場合のみ空の状態から始める。
        let corruptedURL = appRootURL.appendingPathComponent("library.corrupted-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: dataFileURL, to: corruptedURL)
        print("⚠️ [LOAD] library.json が破損していたため \(corruptedURL.lastPathComponent) に退避しました")

        for backupURL in backupGenerationURLs {
            if let backupData = try? Data(contentsOf: backupURL),
               let container = try? JSONDecoder().decode(DataContainer.self, from: backupData) {
                print("✅ [LOAD] バックアップ（\(backupURL.lastPathComponent)）から復元しました")
                applyLoadedContainer(container)
                saveData()
                return
            }
        }

        setupInitialAlbums()
        saveData()
    }

    /// バックアップの世代（新しい順）。起動が正常なたびに 1→2→3 へローテーションされる。
    var backupGenerationURLs: [URL] {
        [
            backupFileURL,
            appRootURL.appendingPathComponent("library.backup.2.json"),
            appRootURL.appendingPathComponent("library.backup.3.json"),
        ]
    }

    func applyLoadedContainer(_ container: DataContainer) {
        videos = container.videos
        albums = container.albums
        duplicateCheckStates = container.duplicateCheckStates ?? [:]
        setupInitialAlbums()
        pruneDuplicateCheckStates()
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
