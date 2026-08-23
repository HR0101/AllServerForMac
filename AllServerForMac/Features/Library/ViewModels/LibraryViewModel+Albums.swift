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

struct SystemTrashFailure: Codable, Equatable, Sendable {
    let videoID: UUID
    let filename: String
    let reason: String
}

struct SystemTrashResult: Codable, Equatable, Sendable {
    let movedVideoIDs: [UUID]
    let failures: [SystemTrashFailure]

    var notice: String? {
        guard !failures.isEmpty else { return nil }
        let movedCount = movedVideoIDs.count
        let details = failures.prefix(5).map {
            "・\($0.filename)：\($0.reason)"
        }.joined(separator: "\n")
        let remainingCount = max(0, failures.count - 5)
        let suffix = remainingCount > 0
            ? "\nほか\(remainingCount)件"
            : ""
        return "\(movedCount)件をMacのゴミ箱へ移動しました．\(failures.count)件は移動できなかったため，ライブラリに残しています．\n\n\(details)\(suffix)"
    }
}

extension LibraryViewModel {
    func deleteVideos(videoIDs: [UUID]) {
        for i in 0..<albums.count { albums[i].videoIDs.removeAll { videoIDs.contains($0) } }
        let idsToDelete = videoIDs.filter { videoID in !albums.contains { $0.videoIDs.contains(videoID) } }

        for id in idsToDelete {
            if let item = videos.first(where: { $0.id == id }) {
                if let extPath = item.externalFilePath {
                    let extURL = URL(fileURLWithPath: extPath)
                    // アプリ自身が管理しているコピー（ダウンロードフォルダ経由のアップロード等）だけを削除する。
                    // フォルダインポートはファイルをコピーせず元の場所を参照するだけなので、
                    // アプリ管理外にある元ファイルは、ライブラリから消しても一切触れない
                    // （以前はここで Finder のゴミ箱に移動しており、意図せず元ファイルが消える原因になっていた）。
                    if isAppManagedPath(extURL.path) {
                        try? FileManager.default.removeItem(at: extURL)
                    }
                } else if !item.internalFilename.isEmpty {
                    if let fileURL = fileURL(for: item) {
                         if isAppManagedPath(fileURL.path) {
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
        // 完全削除はやり直しが効かない操作なので、デバウンスを待たず即座にディスクへ書き切る。
        // （クラッシュや電源断でも「削除したはずのものが復活する」不整合を残さない）
        flushPendingSave()
    }

    func removeVideosFromAlbum(videoIDs: [UUID], albumID: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        let name = albums[index].name
        if name == LibraryViewModel.allVideosAlbumName || name == LibraryViewModel.allPhotosAlbumName {
            // 「すべての動画/画像」から外す＝ライブラリからの削除に相当するが、
            // 以前はここで完全削除（実ファイルの削除まで）していたため、リモート
            // （iOS/Web）からの操作一発でメディアが取り返しなく消えてしまう危険があった。
            // ゴミ箱行きに留め、完全削除は明示的な「完全に削除」操作（deleteVideos）だけが行う。
            moveToTrash(videoIDs: videoIDs)
        } else {
            albums[index].videoIDs.removeAll { videoIDs.contains($0) }
            saveData()
        }
    }

    /// 選択したメディアの実ファイルをmacOSのゴミ箱へ移動します．
    /// ファイル移動に成功した項目だけをライブラリから外し，失敗した項目は再試行できるよう残します．
    @discardableResult
    func moveMediaFilesToSystemTrash(videoIDs: [UUID]) -> SystemTrashResult {
        var seenIDs = Set<UUID>()
        let requestedIDs = videoIDs.filter { seenIDs.insert($0).inserted }
        let itemsByID = Dictionary(
            videos.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )

        var movedIDs: [UUID] = []
        var failures: [SystemTrashFailure] = []

        for videoID in requestedIDs {
            guard let item = itemsByID[videoID] else {
                failures.append(
                    SystemTrashFailure(
                        videoID: videoID,
                        filename: videoID.uuidString,
                        reason: "ライブラリに見つかりません．"
                    )
                )
                continue
            }
            guard let sourceURL = fileURL(for: item) else {
                failures.append(
                    SystemTrashFailure(
                        videoID: videoID,
                        filename: item.originalFilename,
                        reason: "実ファイルが見つかりません．"
                    )
                )
                continue
            }

            do {
                try storageEnvironment.moveFileToSystemTrash(sourceURL)
                movedIDs.append(videoID)
            } catch {
                failures.append(
                    SystemTrashFailure(
                        videoID: videoID,
                        filename: item.originalFilename,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        if !movedIDs.isEmpty {
            removeLibraryRecords(videoIDs: movedIDs)
        }

        let result = SystemTrashResult(
            movedVideoIDs: movedIDs,
            failures: failures
        )
        mediaDeletionNotice = result.notice
        return result
    }

    /// 実ファイルには触れず，ライブラリ登録と再生成可能なキャッシュだけを削除します．
    private func removeLibraryRecords(videoIDs: [UUID]) {
        let ids = Set(videoIDs)
        guard !ids.isEmpty else { return }
        let removedItems = videos.filter { ids.contains($0.id) }

        for index in albums.indices {
            albums[index].videoIDs.removeAll { ids.contains($0) }
        }
        videos.removeAll { ids.contains($0.id) }

        for item in removedItems {
            let thumbnailURL = thumbnailStorageURL
                .appendingPathComponent(item.id.uuidString)
                .appendingPathExtension("jpg")
            try? FileManager.default.removeItem(at: thumbnailURL)

            let proxy1080URL = proxyStorageURL
                .appendingPathComponent("\(item.id.uuidString)_1080p.mp4")
            try? FileManager.default.removeItem(at: proxy1080URL)
            let proxy540URL = proxyStorageURL
                .appendingPathComponent("\(item.id.uuidString)_540p.mp4")
            try? FileManager.default.removeItem(at: proxy540URL)
        }

        saveData()
        flushPendingSave()
    }
    @discardableResult
    func createAlbum(name: String, type: AlbumType) -> UUID? { guard name != LibraryViewModel.allVideosAlbumName && name != LibraryViewModel.allPhotosAlbumName else { return nil }; let id = UUID(); albums.append(Album(id: id, name: name, videoIDs: [], type: type)); saveData(); return id }

    /// 指定アルバムに動画を追加する（重複は無視）
    func addVideosToAlbum(videoIDs: [UUID], albumID: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        let existing = Set(albums[index].videoIDs)
        albums[index].videoIDs.append(contentsOf: videoIDs.filter { !existing.contains($0) })
        saveData()
    }
    func deleteAlbum(albumID: UUID) {
        deleteAlbums(albumIDs: [albumID], contentDisposal: .keep)
    }

    /// アルバムの名前を一括変更する。フォルダは実体を持たず "/" 区切りの名前だけで
    /// 表現されるため、サイドバーでのドラッグ移動やフォルダ作成はすべてこれで実現する。
    func renameAlbums(_ newNames: [UUID: String]) {
        guard !newNames.isEmpty else { return }
        let protectedNames: Set<String> = [LibraryViewModel.allVideosAlbumName, LibraryViewModel.allPhotosAlbumName]
        albums = albums.map { album in
            guard let newName = newNames[album.id], !protectedNames.contains(album.name), newName != album.name else { return album }
            var updated = album
            updated.name = newName
            return updated
        }
        saveData()
        reconcileLinkedFoldersFromExistingPaths()
    }

    /// アルバム削除時に中身のメディアをどうするか。
    enum AlbumContentDisposal {
        case keep    // アルバムだけ削除し、中身は ALL PHOTOS / ALL VIDEOS に残す
        case trash   // 中身をゴミ箱へ移動する（元に戻せる）
        case delete  // 中身を完全に削除する（元に戻せない）
        case systemTrash  // 中身の実ファイルをmacOSのゴミ箱へ移動する
    }

    func deleteAlbums(albumIDs: [UUID], contentDisposal: AlbumContentDisposal) {
        let targetIDs = Set(albumIDs)
        let protectedNames = Set([LibraryViewModel.allVideosAlbumName, LibraryViewModel.allPhotosAlbumName])
        let albumsToDelete = albums.filter { targetIDs.contains($0.id) && !protectedNames.contains($0.name) }
        guard !albumsToDelete.isEmpty else { return }

        switch contentDisposal {
        case .keep:
            break
        case .trash:
            let mediaIDs = Array(Set(albumsToDelete.flatMap { $0.videoIDs }))
            if !mediaIDs.isEmpty { moveToTrash(videoIDs: mediaIDs) }
        case .delete:
            let mediaIDs = Array(Set(albumsToDelete.flatMap { $0.videoIDs }))
            if !mediaIDs.isEmpty { deleteVideos(videoIDs: mediaIDs) }
        case .systemTrash:
            let mediaIDs = Array(Set(albumsToDelete.flatMap { $0.videoIDs }))
            if !mediaIDs.isEmpty {
                let result = moveMediaFilesToSystemTrash(videoIDs: mediaIDs)
                // 失敗した項目を同じアルバムから再試行できるよう，部分失敗時はアルバムを残す．
                guard result.failures.isEmpty else { return }
            }
        }

        let deletableIDs = Set(albumsToDelete.map { $0.id })
        albums.removeAll { deletableIDs.contains($0.id) }
        saveData()
        reconcileLinkedFoldersFromExistingPaths()
    }
    func moveVideos(videoIDs: [UUID], from sourceAlbumID: UUID, to targetAlbumID: UUID) { guard albums.contains(where: { $0.id == targetAlbumID }) else { return }; if let sourceIndex = albums.firstIndex(where: { $0.id == sourceAlbumID }), albums[sourceIndex].name != LibraryViewModel.allVideosAlbumName, albums[sourceIndex].name != LibraryViewModel.allPhotosAlbumName { albums[sourceIndex].videoIDs.removeAll { videoIDs.contains($0) } }; if let targetIndex = albums.firstIndex(where: { $0.id == targetAlbumID }) { let existingIDs = Set(albums[targetIndex].videoIDs); let newIDs = videoIDs.filter { !existingIDs.contains($0) }; albums[targetIndex].videoIDs.append(contentsOf: newIDs) }; saveData() }

    // MARK: - Favorites & Trash

    /// ゴミ箱を除いたお気に入り
    var favoriteVideos: [VideoItem] { videos.filter { $0.isFavorite && !$0.isInTrash } }
    /// ゴミ箱内のアイテム
    var trashedVideos: [VideoItem] { videos.filter { $0.isInTrash } }

    // videos[i].xxx = ... を for ループで1件ずつ書き換えると、対象件数の分だけ @Published が発火し
    // ギャラリーが再描画され続けてしまう（重複チェックが数百〜数千件をまとめて処理する際に顕著）。
    // 変更後の配列を作ってから1回で代入することで、発火を1回にまとめる。

    /// 指定アイテムのお気に入りを切り替える（1つでも未登録があれば全て登録、なければ全て解除）
    func toggleFavorite(videoIDs: [UUID]) {
        let ids = Set(videoIDs)
        let shouldFavorite = videos.contains { ids.contains($0.id) && !$0.isFavorite }
        videos = videos.map { item in
            guard ids.contains(item.id) else { return item }
            var updated = item
            updated.isFavorite = shouldFavorite
            return updated
        }
        saveData()
    }

    func moveToTrash(videoIDs: [UUID]) {
        let ids = Set(videoIDs)
        videos = videos.map { item in
            guard ids.contains(item.id) else { return item }
            var updated = item
            updated.isInTrash = true
            updated.isFavorite = false
            updated.trashedDate = Date()
            return updated
        }
        saveData()
    }

    func restoreFromTrash(videoIDs: [UUID]) {
        let ids = Set(videoIDs)
        videos = videos.map { item in
            guard ids.contains(item.id) else { return item }
            var updated = item
            updated.isInTrash = false
            updated.trashedDate = nil
            return updated
        }
        saveData()
    }

    /// ゴミ箱の自動削除期限（設定）を超えた項目を完全削除する。起動時に1回呼ばれる。
    /// trashedDate を持たない旧データは即削除せず、今の日時を刻んで次回以降の起点にする。
    func purgeExpiredTrash() {
        guard trashAutoDeleteDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-TimeInterval(trashAutoDeleteDays) * 86_400)

        var legacyStamped = false
        let now = Date()
        videos = videos.map { item in
            guard item.isInTrash else { return item }
            if item.trashedDate == nil {
                var updated = item
                updated.trashedDate = now
                legacyStamped = true
                return updated
            }
            // システム時計の変更・NTP補正などで trashedDate が未来になっていると、
            // 期限の比較が狂い「いつまでも消えない」状態になるため、現在時刻へ丸め直す。
            if let stamped = item.trashedDate, stamped > now.addingTimeInterval(3600) {
                var updated = item
                updated.trashedDate = now
                legacyStamped = true
                return updated
            }
            return item
        }

        let expiredIDs = videos
            .filter { $0.isInTrash && ($0.trashedDate ?? Date()) < cutoff }
            .map { $0.id }
        if !expiredIDs.isEmpty {
            deleteVideos(videoIDs: expiredIDs)
        } else if legacyStamped {
            saveData()
        }
    }

    /// ゴミ箱を空にする（ファイルごと完全削除）
    func emptyTrash() {
        deleteVideos(videoIDs: trashedVideos.map { $0.id })
    }

    /// リンク切れメディア（元ファイルが見つからないデータ）を整理する（ストレージ管理画面の手動ボタン用）
    func cleanupMissingFiles() -> Int {
        let missingIDs = videos.filter { fileURL(for: $0) == nil }.map { $0.id }
        guard !missingIDs.isEmpty else { return 0 }
        deleteVideos(videoIDs: missingIDs)
        return missingIDs.count
    }

    /// 起動時に自動でリンク切れメディアを整理する。件数が多いと存在チェックだけで
    /// 相応のディスクI/Oになるため、メインスレッドをブロックしないようバックグラウンドで判定し、
    /// 削除の反映だけメインアクターに戻す。
    func runAutomaticMissingFileCleanup() {
        let videosSnapshot = videos
        let videoStorageURL = self.videoStorageURL
        let downloadStorageURL = self.downloadStorageURL
        Task.detached(priority: .utility) {
            let missingIDs = videosSnapshot.filter {
                LibraryViewModel.resolveFileURL(for: $0, videoStorageURL: videoStorageURL, downloadStorageURL: downloadStorageURL) == nil
            }.map { $0.id }
            guard !missingIDs.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.deleteVideos(videoIDs: missingIDs)
            }
        }
    }

    /// ライブラリ全体をJSONへ保存する。エンコード・書き込みはメインスレッドをブロックしないようバックグラウンドで行い、
    /// 短時間に連続で呼ばれた場合は最後の状態だけを書き込む（デバウンス）。
    /// アプリ終了時は flushPendingSave() が同期的に保留分を書き切る。
    /// library.json への書き込みを直列化する専用キュー。
    /// これがないと flushPendingSave の同期書き込みと、キャンセルチェックを通過済みの
    /// デバウンス書き込みが並走し、古い内容が後からファイルを上書きするレースが起きる。
    nonisolated static let saveQueue = DispatchQueue(label: "AllServerForMac.librarySave", qos: .utility)
    /// saveQueue 上でのみ読み書きする、最後に書き込んだ世代番号。
    nonisolated(unsafe) static var lastWrittenSaveGeneration = 0
    /// メインアクター上で発番する保存世代。呼び出し順＝新しさの順になる。
}
