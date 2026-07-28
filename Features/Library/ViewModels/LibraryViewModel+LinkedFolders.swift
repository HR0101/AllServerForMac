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
    func bookmarkData(for folderURL: URL) -> Data? {
        try? folderURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolvedLinkedFolderURL(for album: Album) -> URL? {
        if let data = album.linkedFolderBookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale, let index = albums.firstIndex(where: { $0.id == album.id }) {
                    albums[index].linkedFolderBookmarkData = bookmarkData(for: url)
                    albums[index].linkedFolderPath = url.path
                    saveData()
                }
                return url
            }
        }

        if let path = album.linkedFolderPath {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func existingImportedSourcePaths() -> Set<String> {
        if let cachedExistingSourcePaths {
            return cachedExistingSourcePaths
        }
        let paths: Set<String> = Set(videos.compactMap { item in
            guard let path = item.externalFilePath else { return nil }
            return normalizedPath(URL(fileURLWithPath: path))
        })
        cachedExistingSourcePaths = paths
        return paths
    }

    func newMediaFiles(from urls: [URL], existingPaths: Set<String>) -> [URL] {
        urls.filter { !existingPaths.contains(normalizedPath($0)) }
    }

    func importAndLinkFolder(
        folderURL: URL,
        as albumType: AlbumType,
        onItemProcessed: @MainActor @escaping () -> Void = {}
    ) async {
        let shouldStopAccessing = folderURL.startAccessingSecurityScopedResource()
        defer { if shouldStopAccessing { folderURL.stopAccessingSecurityScopedResource() } }

        await importLinkedFolderContents(
            folderURL: folderURL,
            as: albumType,
            parentAlbumName: nil,
            rootBookmarkData: bookmarkData(for: folderURL),
            onItemProcessed: onItemProcessed
        )
        reconcileLinkedFoldersFromExistingPaths()
    }

    func linkFolder(
        folderURL: URL,
        to albumID: UUID,
        onItemProcessed: @MainActor @escaping () -> Void = {}
    ) async {
        guard let album = albums.first(where: { $0.id == albumID }) else { return }
        let shouldStopAccessing = folderURL.startAccessingSecurityScopedResource()
        defer { if shouldStopAccessing { folderURL.stopAccessingSecurityScopedResource() } }

        await importLinkedFolderContents(
            folderURL: folderURL,
            as: album.type,
            parentAlbumName: nil,
            rootAlbumID: albumID,
            rootBookmarkData: bookmarkData(for: folderURL),
            onItemProcessed: onItemProcessed
        )
        reconcileLinkedFoldersFromExistingPaths()
    }

    func rescanLinkedFolder(
        albumID: UUID,
        onItemProcessed: @MainActor @escaping () -> Void = {}
    ) async {
        await scanLinkedFolder(albumID: albumID, onItemProcessed: onItemProcessed)
    }

    func confirmLinkedFolderCandidate(
        _ candidate: LinkedFolderCandidate,
        shouldScheduleScan: Bool = true
    ) {
        guard let albumID = existingOrCreateAlbumID(name: candidate.albumName, type: candidate.albumType, preferredID: candidate.albumID) else {
            return
        }
        setLinkedFolder(folderURL: URL(fileURLWithPath: candidate.folderPath), albumID: albumID)
        linkedFolderConflicts.removeAll { $0.id == candidate.conflictID }
        if shouldScheduleScan {
            scheduleLinkedFolderScan(albumID: albumID, delayNanoseconds: 500_000_000)
        }
    }

    func setLinkedFolder(folderURL: URL, albumID: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        albums[index].linkedFolderPath = folderURL.path
        albums[index].linkedFolderBookmarkData = bookmarkData(for: folderURL)
        saveData()
    }

    func existingOrCreateAlbumID(name: String, type: AlbumType, preferredID: UUID? = nil) -> UUID? {
        if let preferredID, albums.contains(where: { $0.id == preferredID }) {
            return preferredID
        }
        if let existingAlbum = albums.first(where: { $0.name == name }) {
            return existingAlbum.id
        }
        return createAlbum(name: name, type: type)
    }

    /// 同じ物理フォルダを実質的に指している重複アルバム（直接リンクした「陽夜」と、
    /// 親フォルダのリンクから再帰インポートで生成された「Bengugu/陽夜」など）を検出し、1つに統合する。
    /// 元々メディア数が多かった方を残し、少ない方のメディアと（あれば）フォルダのリンク情報を
    /// 残す側へ移してから、空になったアルバムを削除する。
    func mergeDuplicateFolderAlbums() {
        let protectedNames: Set<String> = [Self.allVideosAlbumName, Self.allPhotosAlbumName]
        let itemsByID = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })

        func resolvedFolderPath(for album: Album) -> String? {
            if let linkedPath = album.linkedFolderPath {
                return normalizedPath(URL(fileURLWithPath: linkedPath))
            }
            let parentPaths = Set(album.videoIDs.compactMap { id -> String? in
                guard let externalPath = itemsByID[id]?.externalFilePath else { return nil }
                return normalizedPath(URL(fileURLWithPath: externalPath).deletingLastPathComponent())
            })
            return parentPaths.count == 1 ? parentPaths.first : nil
        }

        var groups: [String: [Album]] = [:]
        for album in albums where !protectedNames.contains(album.name) {
            guard let folder = resolvedFolderPath(for: album) else { continue }
            groups[folder, default: []].append(album)
        }

        var albumIDsToDelete: [UUID] = []
        for group in groups.values where group.count > 1 {
            let ordered = group.sorted { $0.videoIDs.count > $1.videoIDs.count }
            guard let primaryID = ordered.first?.id,
                  let primaryIndex = albums.firstIndex(where: { $0.id == primaryID }) else { continue }

            var mergedIDs = Set(albums[primaryIndex].videoIDs)
            var mergedType = albums[primaryIndex].type
            var linkedPath = albums[primaryIndex].linkedFolderPath
            var linkedBookmark = albums[primaryIndex].linkedFolderBookmarkData

            for loser in ordered.dropFirst() {
                mergedIDs.formUnion(loser.videoIDs)
                mergedType = combinedAlbumType(mergedType, loser.type)
                if linkedPath == nil, let loserPath = loser.linkedFolderPath {
                    linkedPath = loserPath
                    linkedBookmark = loser.linkedFolderBookmarkData
                }
                albumIDsToDelete.append(loser.id)
            }

            albums[primaryIndex].videoIDs = Array(mergedIDs)
            albums[primaryIndex].type = mergedType
            albums[primaryIndex].linkedFolderPath = linkedPath
            albums[primaryIndex].linkedFolderBookmarkData = linkedBookmark
        }

        guard !albumIDsToDelete.isEmpty else { return }
        let deletableIDs = Set(albumIDsToDelete)
        albums.removeAll { deletableIDs.contains($0.id) }
        saveData()
    }

    func reconcileLinkedFoldersFromExistingPaths(
        shouldScheduleScans: Bool = true
    ) {
        mergeDuplicateFolderAlbums()
        let protectedNames: Set<String> = [Self.allVideosAlbumName, Self.allPhotosAlbumName]
        let itemsByID = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let existingAlbumsByName = Dictionary(grouping: albums) { $0.name }
        let albumsToEvaluate = albums.filter { album in
            !protectedNames.contains(album.name)
            && album.linkedFolderPath == nil
            && album.linkedFolderBookmarkData == nil
        }
        let sourceAlbums = albums.filter { !protectedNames.contains($0.name) }
        var conflicts: [LinkedFolderConflict] = []

        for album in albumsToEvaluate {
            let candidateCounts = linkedFolderCandidateCounts(
                targetAlbumName: album.name,
                sourceAlbums: [album],
                itemsByID: itemsByID
            )

            let candidates = candidateCounts
                .map { path, count in
                    LinkedFolderCandidate(
                        id: "\(album.id.uuidString)|\(path)",
                        conflictID: album.id.uuidString,
                        albumID: album.id,
                        albumName: album.name,
                        albumType: album.type,
                        folderPath: path,
                        matchCount: count
                    )
                }
                .sorted {
                    if $0.matchCount != $1.matchCount { return $0.matchCount > $1.matchCount }
                    return $0.folderPath.localizedStandardCompare($1.folderPath) == .orderedAscending
                }

            if candidates.count == 1, let candidate = candidates.first {
                confirmLinkedFolderCandidate(
                    candidate,
                    shouldScheduleScan: shouldScheduleScans
                )
            } else if candidates.count > 1 {
                conflicts.append(
                    LinkedFolderConflict(
                        id: album.id.uuidString,
                        albumID: album.id,
                        albumName: album.name,
                        albumType: album.type,
                        candidates: candidates
                    )
                )
            }
        }

        let virtualFolders = virtualFolderCandidates(
            from: sourceAlbums,
            existingAlbumsByName: existingAlbumsByName,
            itemsByID: itemsByID
        )
        for folder in virtualFolders {
            let candidateCounts = linkedFolderCandidateCounts(
                targetAlbumName: folder.name,
                sourceAlbums: folder.sourceAlbums,
                itemsByID: itemsByID
            )
            let candidates = candidateCounts
                .map { path, count in
                    LinkedFolderCandidate(
                        id: "virtual|\(folder.name)|\(path)",
                        conflictID: "virtual|\(folder.name)",
                        albumID: nil,
                        albumName: folder.name,
                        albumType: folder.type,
                        folderPath: path,
                        matchCount: count
                    )
                }
                .sorted {
                    if $0.matchCount != $1.matchCount { return $0.matchCount > $1.matchCount }
                    return $0.folderPath.localizedStandardCompare($1.folderPath) == .orderedAscending
                }

            if candidates.count == 1, let candidate = candidates.first {
                confirmLinkedFolderCandidate(
                    candidate,
                    shouldScheduleScan: shouldScheduleScans
                )
            } else if candidates.count > 1 {
                conflicts.append(
                    LinkedFolderConflict(
                        id: "virtual|\(folder.name)",
                        albumID: nil,
                        albumName: folder.name,
                        albumType: folder.type,
                        candidates: candidates
                    )
                )
            }
        }

        linkedFolderConflicts = conflicts
    }

    func linkedFolderCandidateCounts(
        targetAlbumName: String,
        sourceAlbums: [Album],
        itemsByID: [UUID: VideoItem]
    ) -> [String: Int] {
        let targetComponents = albumPathComponents(targetAlbumName)
        guard !targetComponents.isEmpty else { return [:] }

        var counts: [String: Int] = [:]
        for album in sourceAlbums {
            let sourceComponents = albumPathComponents(album.name)
            guard sourceComponents.starts(with: targetComponents) else { continue }
            let levelsUp = sourceComponents.count - targetComponents.count

            for itemID in album.videoIDs {
                guard let item = itemsByID[itemID],
                      let externalPath = item.externalFilePath else { continue }

                var folderURL = URL(fileURLWithPath: externalPath).deletingLastPathComponent()
                for _ in 0..<levelsUp {
                    folderURL.deleteLastPathComponent()
                }

                guard folderURL.lastPathComponent == targetComponents.last,
                      isExistingDirectory(folderURL) else { continue }
                counts[normalizedPath(folderURL), default: 0] += 1
            }
        }
        return counts
    }

    func virtualFolderCandidates(
        from sourceAlbums: [Album],
        existingAlbumsByName: [String: [Album]],
        itemsByID: [UUID: VideoItem]
    ) -> [(name: String, type: AlbumType, sourceAlbums: [Album])] {
        var sourceAlbumsByFolder: [String: [Album]] = [:]
        var typeByFolder: [String: AlbumType] = [:]

        for album in sourceAlbums {
            let components = albumPathComponents(album.name)
            guard components.count > 1 else { continue }

            for depth in 1..<components.count {
                let folderName = components.prefix(depth).joined(separator: "/")
                guard existingAlbumsByName[folderName] == nil else { continue }
                sourceAlbumsByFolder[folderName, default: []].append(album)
                typeByFolder[folderName] = combinedAlbumType(typeByFolder[folderName], album.type)
                break
            }
        }

        return sourceAlbumsByFolder.compactMap { name, albums in
            let candidateCounts = linkedFolderCandidateCounts(
                targetAlbumName: name,
                sourceAlbums: albums,
                itemsByID: itemsByID
            )
            guard !candidateCounts.isEmpty else {
                return nil
            }
            return (name: name, type: typeByFolder[name] ?? .mixed, sourceAlbums: albums)
        }
        .sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func albumPathComponents(_ name: String) -> [String] {
        name.split(separator: "/").map(String.init)
    }

    func combinedAlbumType(_ lhs: AlbumType?, _ rhs: AlbumType) -> AlbumType {
        guard let lhs else { return rhs }
        return lhs == rhs ? lhs : .mixed
    }

    func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// 名前パスから導かれる階層アルバム（例: "Bengugu/陽夜"）と、同じ物理フォルダに
    /// 直接紐づけられた単体アルバム（例: "陽夜"）が両方存在する場合、片方だけが
    /// 再スキャンされて新規メディアが割れてしまう問題を防ぐため、
    /// 同じフォルダを指す候補の中からメディア数が最も多いアルバムへ寄せる。
    func existingAlbum(named albumName: String, type albumType: AlbumType, orLinkedTo folderURL: URL) -> Album? {
        let normalizedFolder = normalizedPath(folderURL)
        let candidates = albums.filter { album in
            if album.name == albumName && album.type == albumType { return true }
            if let linkedPath = album.linkedFolderPath {
                return normalizedPath(URL(fileURLWithPath: linkedPath)) == normalizedFolder
            }
            return false
        }
        return candidates.max { $0.videoIDs.count < $1.videoIDs.count }
    }

    func importLinkedFolderContents(
        folderURL: URL,
        as albumType: AlbumType,
        parentAlbumName: String?,
        rootAlbumID: UUID? = nil,
        rootBookmarkData: Data?,
        existingPaths: Set<String>? = nil,
        onItemProcessed: @MainActor @escaping () -> Void
    ) async {
        let folderName = folderURL.lastPathComponent
        let albumName = parentAlbumName
            .map { "\($0)/\(folderName)" }
            ?? rootAlbumID.flatMap { rootID in albums.first(where: { $0.id == rootID })?.name }
            ?? folderName

        guard let entries = await Self.loadLinkedFolderEntries(at: folderURL) else {
            return
        }

        let mediaFiles = entries
            .filter { !$0.isDirectory && isSupportedMedia($0.url, for: albumType) }
            .map(\.url)

        var targetAlbumID: UUID?
        let shouldCreateAlbum = parentAlbumName == nil || !mediaFiles.isEmpty
        if shouldCreateAlbum {
            if parentAlbumName == nil, let rootAlbumID, albums.contains(where: { $0.id == rootAlbumID }) {
                targetAlbumID = rootAlbumID
            } else if let existingAlbum = existingAlbum(named: albumName, type: albumType, orLinkedTo: folderURL) {
                targetAlbumID = existingAlbum.id
            } else {
                let newID = UUID()
                targetAlbumID = newID
                albums.append(Album(id: newID, name: albumName, videoIDs: [], type: albumType))
            }
        }

        if parentAlbumName == nil, let targetAlbumID,
           let index = albums.firstIndex(where: { $0.id == targetAlbumID }) {
            albums[index].linkedFolderPath = folderURL.path
            albums[index].linkedFolderBookmarkData = rootBookmarkData
        }

        var currentExistingPaths = existingPaths ?? existingImportedSourcePaths()

        if let targetAlbumID {
            let targets = newMediaFiles(from: mediaFiles, existingPaths: currentExistingPaths)
            if !targets.isEmpty {
                await importMediaBatch(urls: targets, to: targetAlbumID, onItemProcessed: onItemProcessed, forceReferenceOriginals: true)
                for target in targets {
                    currentExistingPaths.insert(normalizedPath(target))
                }
            } else if shouldCreateAlbum {
                saveData()
            }
        }

        for entry in entries where entry.isDirectory && !isExcludedFromImport(entry.url) {
            guard !Task.isCancelled else { return }
            await Task.yield()
            await importLinkedFolderContents(
                folderURL: entry.url,
                as: albumType,
                parentAlbumName: albumName,
                rootAlbumID: nil,
                rootBookmarkData: nil,
                existingPaths: currentExistingPaths,
                onItemProcessed: onItemProcessed
            )
        }
    }

    nonisolated static func loadLinkedFolderEntries(
        at folderURL: URL
    ) async -> [LinkedFolderDirectoryEntry]? {
        await Task.detached(priority: .utility) {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return nil
            }

            return contents.map { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return LinkedFolderDirectoryEntry(
                    url: url,
                    isDirectory: values?.isDirectory == true
                )
            }
            .sorted {
                $0.url.lastPathComponent.localizedStandardCompare(
                    $1.url.lastPathComponent
                ) == .orderedAscending
            }
        }.value
    }

    func scanLinkedFolder(albumID: UUID, onItemProcessed: @MainActor @escaping () -> Void = {}) async {
        guard let album = albums.first(where: { $0.id == albumID }),
              let folderURL = resolvedLinkedFolderURL(for: album) else { return }

        let shouldStopAccessing = folderURL.startAccessingSecurityScopedResource()
        defer { if shouldStopAccessing { folderURL.stopAccessingSecurityScopedResource() } }

        await importLinkedFolderContents(
            folderURL: folderURL,
            as: album.type,
            parentAlbumName: nil,
            rootAlbumID: albumID,
            rootBookmarkData: album.linkedFolderBookmarkData ?? bookmarkData(for: folderURL),
            onItemProcessed: onItemProcessed
        )
        mergeDuplicateFolderAlbums()
    }

    func scheduleLinkedFolderScan(albumID: UUID, delayNanoseconds: UInt64 = 1_500_000_000) {
        linkedFolderScanTasks[albumID]?.cancel()
        linkedFolderScanTasks[albumID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.scanLinkedFolder(albumID: albumID)
            self?.linkedFolderScanTasks[albumID] = nil
        }
    }

    /// 現在フォルダに紐づいているアルバムの件数（ホーム画面の手動更新カードで使う）。
    var linkedFolderCount: Int {
        albums.filter { $0.linkedFolderPath != nil || $0.linkedFolderBookmarkData != nil }.count
    }

    /// 起動時に一度だけリンクフォルダを自動スキャンする。起動直後のUI描画や他の初期化処理と
    /// 競合しないよう数秒待ってから実行し、以降は自動スキャンしない（更新は手動ボタン）。
    /// リンクフォルダが無い場合は何もしない（ホーム画面に不要な状態メッセージを出さないため）。
    func startInitialLinkedFolderScan() {
        initialLinkedFolderScanTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.linkedFolderStartupDelayNanoseconds
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.linkedFolderCount > 0 else { return }
            await self.rescanAllLinkedFolders()
        }
    }

    /// ホーム画面の「リンクフォルダを更新」ボタンから呼ぶ。紐づけ済みフォルダを1つずつ
    /// 再スキャンし、Finder側で追加された新規メディアを取り込む。
    /// 以前は60秒ごとの自動ポーリング＋ファイル監視で自動更新していたが、件数が多いと
    /// メインスレッドを圧迫してUIがカクつくため、この明示的な手動実行に切り替えた。
    func rescanAllLinkedFolders() async {
        guard !linkedFolderScanStatus.isScanning else { return }
        let linkedAlbums = albums.filter { $0.linkedFolderPath != nil || $0.linkedFolderBookmarkData != nil }
        guard !linkedAlbums.isEmpty else {
            linkedFolderScanStatus.statusMessage = "リンクされたフォルダはありません。"
            return
        }

        let beforeCount = videos.count

        linkedFolderScanStatus.isScanning = true
        linkedFolderScanStatus.totalCount = linkedAlbums.count
        linkedFolderScanStatus.processedCount = 0
        linkedFolderScanStatus.currentFolderName = nil
        linkedFolderScanStatus.processedItemsInCurrentFolder = 0
        linkedFolderScanStatus.statusMessage = ""

        var wasCancelled = false
        for (index, album) in linkedAlbums.enumerated() {
            guard !Task.isCancelled else {
                wasCancelled = true
                break
            }
            linkedFolderScanStatus.currentFolderName = album.name
            linkedFolderScanStatus.processedItemsInCurrentFolder = 0
            await scanLinkedFolder(albumID: album.id) { [weak self] in
                self?.linkedFolderScanStatus.processedItemsInCurrentFolder += 1
            }
            linkedFolderScanStatus.processedCount += 1

            guard index < linkedAlbums.count - 1 else { continue }
            do {
                try await Task.sleep(
                    nanoseconds: Self.linkedFolderScanSpacingNanoseconds
                )
            } catch {
                wasCancelled = true
                break
            }
        }

        let imported = max(0, videos.count - beforeCount)
        linkedFolderScanStatus.isScanning = false
        linkedFolderScanStatus.currentFolderName = nil
        linkedFolderScanStatus.processedItemsInCurrentFolder = 0
        if wasCancelled {
            linkedFolderScanStatus.statusMessage = "リンクフォルダの更新を中止しました。"
        } else {
            linkedFolderScanStatus.statusMessage = imported > 0
                ? "\(linkedAlbums.count)件のフォルダを更新し、\(imported)件の新しいメディアを取り込みました。"
                : "\(linkedAlbums.count)件のフォルダを更新しました（新規メディアはありません）。"
        }
    }

    /// 予約済みの単発スキャン（起動時の初回スキャン・フォルダ紐づけ直後などに走るもの）を取り消す。アプリ終了時に呼ぶ。
    func cancelPendingLinkedFolderScans() {
        initialLinkedFolderScanTask?.cancel()
        initialLinkedFolderScanTask = nil
        linkedFolderScanTasks.values.forEach { $0.cancel() }
        linkedFolderScanTasks.removeAll()
    }
}
