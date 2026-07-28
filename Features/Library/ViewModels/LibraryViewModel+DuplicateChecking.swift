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
    var duplicateCheckTargetAlbums: [Album] {
        let activeIDs = Set(videos.filter { !$0.isInTrash }.map { $0.id })
        return albums.filter { album in
            album.name != LibraryViewModel.allVideosAlbumName &&
            album.name != LibraryViewModel.allPhotosAlbumName &&
            album.videoIDs.contains { activeIDs.contains($0) }
        }
    }

    var duplicateCheckedAlbums: [Album] {
        duplicateCheckTargetAlbums.filter { !albumNeedsDuplicateCheck($0) }
    }

    var duplicateUncheckedAlbums: [Album] {
        duplicateCheckTargetAlbums.filter { albumNeedsDuplicateCheck($0) }
    }

    /// ダッシュボード表示用のチェック済み/未チェックアルバム一覧キャッシュを更新する。
    /// duplicateCheckedAlbums/duplicateUncheckedAlbums は呼ぶたびにアルバムごとの署名を再計算するため、
    /// 画面の再描画のたびに呼ぶのではなく、この関数を低頻度（自動チェックループやチェック完了時）で呼んで
    /// 結果をキャッシュする。
    func refreshDuplicateCheckAlbumCaches() {
        // trashedIDs / activeIDs をここで1回だけ作り、全アルバムで使い回す。
        // 以前はアルバムごとに albumNeedsDuplicateCheck → duplicateCheckSignature が
        // videos 全件を走査して trashedIDs を作り直し、さらに checked/unchecked で2回フィルタしていたため、
        // O(アルバム数 × ライブラリ全件 × 2) のコストが30秒ごとにメインスレッドで走り、周期的な引っかかりの原因になっていた。
        var trashedIDs = Set<UUID>()
        var activeIDs = Set<UUID>()
        for video in videos {
            if video.isInTrash { trashedIDs.insert(video.id) } else { activeIDs.insert(video.id) }
        }

        var checked: [Album] = []
        var unchecked: [Album] = []
        for album in albums {
            guard album.name != Self.allVideosAlbumName,
                  album.name != Self.allPhotosAlbumName,
                  album.videoIDs.contains(where: { activeIDs.contains($0) }) else { continue }
            if albumNeedsDuplicateCheck(album, trashedIDs: trashedIDs) {
                unchecked.append(album)
            } else {
                checked.append(album)
            }
        }
        duplicateCheckStatus.checkedAlbums = checked
        duplicateCheckStatus.uncheckedAlbums = unchecked
    }

    func albumNeedsDuplicateCheck(_ album: Album) -> Bool {
        albumNeedsDuplicateCheck(album, trashedIDs: Set(videos.filter { $0.isInTrash }.map { $0.id }))
    }

    /// trashedIDs を呼び出し側で1回だけ計算して渡す版。多数のアルバムを一括判定する
    /// refreshDuplicateCheckAlbumCaches から使い、アルバムごとに videos 全件を走査し直すのを避ける。
    func albumNeedsDuplicateCheck(_ album: Album, trashedIDs: Set<UUID>) -> Bool {
        guard let state = duplicateCheckStates[album.id] else { return true }
        return state.albumSignature != duplicateCheckSignature(for: album, trashedIDs: trashedIDs)
    }

    func duplicateCheckSignature(for album: Album) -> String {
        duplicateCheckSignature(for: album, trashedIDs: Set(videos.filter { $0.isInTrash }.map { $0.id }))
    }

    func duplicateCheckSignature(for album: Album, trashedIDs: Set<UUID>) -> String {
        let mediaSignature = album.videoIDs
            .filter { !trashedIDs.contains($0) }
            .map { $0.uuidString }
            .sorted()
            .joined(separator: "|")
        return "\(Self.duplicateCheckVersion)|\(mediaSignature)"
    }

    func markDuplicateCheckCompleted(for albumID: UUID) {
        guard let album = albums.first(where: { $0.id == albumID }) else { return }
        duplicateCheckStates[albumID] = DuplicateCheckState(
            checkedAt: Date(),
            albumSignature: duplicateCheckSignature(for: album)
        )
    }

    func startAutomaticDuplicateChecks() {
        guard duplicateAutoCheckTask == nil else { return }

        duplicateAutoCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            while !Task.isCancelled {
                guard let self else { return }

                if !self.isAutoDuplicateCheckEnabled {
                    // 自動チェックがオフのときは、重い署名計算（refreshDuplicateCheckAlbumCaches）を
                    // 一切行わずにアイドルする。以前はオフでも毎ループ先頭で refresh を呼んでいたため、
                    // オフにしても30秒ごとにライブラリ全件走査が走り、UIが定期的に引っかかっていた。
                    // 状態表示は初回に一度だけ更新すれば足りるので、既にオフ表示なら何もしない。
                    if self.duplicateCheckStatus.statusMessage != "自動チェックはオフです" {
                        self.duplicateCheckStatus.isAutoChecking = false
                        self.duplicateCheckStatus.currentAlbumName = nil
                        self.duplicateCheckStatus.progress = 0
                        self.duplicateCheckStatus.statusMessage = "自動チェックはオフです"
                    }
                } else {
                    self.refreshDuplicateCheckAlbumCaches()

                    if !self.isDuplicateCheckRunning, let album = self.duplicateCheckStatus.uncheckedAlbums.first {
                        self.duplicateCheckStatus.isAutoChecking = true
                        self.duplicateCheckStatus.currentAlbumName = album.name
                        self.duplicateCheckStatus.progress = 0
                        self.duplicateCheckStatus.statusMessage = "「\(album.name)」を確認中"

                        _ = await self.removeDuplicateMedia(in: album.id) { current, total in
                            self.duplicateCheckStatus.progress = total == 0 ? 0 : Double(current) / Double(total)
                        }

                        self.duplicateCheckStatus.isAutoChecking = false
                        self.duplicateCheckStatus.currentAlbumName = nil
                        self.duplicateCheckStatus.progress = 0
                        self.duplicateCheckStatus.statusMessage = self.duplicateCheckStatus.uncheckedAlbums.isEmpty ? "すべて確認済み" : "待機中"
                    } else {
                        self.duplicateCheckStatus.statusMessage = self.duplicateCheckStatus.uncheckedAlbums.isEmpty ? "すべて確認済み" : "待機中"
                    }
                }

                let intervalSeconds = UInt64(max(10, self.duplicateCheckIntervalSeconds))
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            }
        }
    }

    /// ホーム画面の「今すぐすべてチェック」ボタン用。対象アルバムをまとめて一括で重複チェックする。
    /// 自動チェックのオン/オフとは独立して動くので、自動チェックをオフにしていてもこのボタンで実行できる。
    /// 30秒ごとに1アルバムずつ処理する自動モードに対して、これは押した瞬間に全アルバムをまとめて処理する。
    func checkAllAlbumsForDuplicatesNow() async {
        guard !isDuplicateCheckRunning else { return }

        let targets = duplicateCheckTargetAlbums
        guard !targets.isEmpty else {
            duplicateCheckStatus.statusMessage = "対象アルバムはありません"
            return
        }

        isDuplicateCheckRunning = true
        duplicateCheckStatus.isAutoChecking = true
        duplicateCheckStatus.progress = 0

        let itemsByID = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        for (index, album) in targets.enumerated() {
            duplicateCheckStatus.currentAlbumName = album.name
            duplicateCheckStatus.statusMessage = "「\(album.name)」を確認中（\(index + 1)/\(targets.count)）"
            duplicateCheckStatus.progress = 0

            let targetItems = album.videoIDs.compactMap { itemsByID[$0] }.filter { !$0.isInTrash }
            _ = await runDuplicateScan(targetItems: targetItems) { current, total in
                self.duplicateCheckStatus.progress = total == 0 ? 0 : Double(current) / Double(total)
            }
            markDuplicateCheckCompleted(for: album.id)
        }

        saveData()

        isDuplicateCheckRunning = false
        duplicateCheckStatus.isAutoChecking = false
        duplicateCheckStatus.currentAlbumName = nil
        duplicateCheckStatus.progress = 0
        refreshDuplicateCheckAlbumCaches()
        duplicateCheckStatus.statusMessage = "すべて確認済み"
    }

    func removeDuplicateVideos() async -> Int {
        let result = await removeDuplicateMedia(in: nil)
        cleanUpOrphanedFiles()
        return result.duplicateCount
    }

    func removeDuplicateMedia(in albumID: UUID?, progress: @MainActor @escaping (Int, Int) -> Void = { _, _ in }) async -> DuplicateCheckResult {
        guard !isDuplicateCheckRunning else {
            return DuplicateCheckResult(checkedCount: 0, duplicateCount: 0, missingFileCount: 0, failedHashCount: 0)
        }

        let itemsByID = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })

        if let albumID {
            guard let album = albums.first(where: { $0.id == albumID }) else {
                return DuplicateCheckResult(checkedCount: 0, duplicateCount: 0, missingFileCount: 0, failedHashCount: 0)
            }
            // 「すべての動画」「すべての画像」はあらゆるアルバムのメディアが集まる集約アルバムのため、
            // ここで重複チェックすると本来は別アルバムに属する（＝重複として消してはいけない）
            // メディア同士まで巻き込んで削除してしまう。そのため対象から除外する。
            guard album.name != LibraryViewModel.allVideosAlbumName, album.name != LibraryViewModel.allPhotosAlbumName else {
                return DuplicateCheckResult(checkedCount: 0, duplicateCount: 0, missingFileCount: 0, failedHashCount: 0)
            }

            isDuplicateCheckRunning = true
            defer { isDuplicateCheckRunning = false }

            let targetItems = album.videoIDs.compactMap { itemsByID[$0] }.filter { !$0.isInTrash }
            let result = await runDuplicateScan(targetItems: targetItems, progress: progress)
            markDuplicateCheckCompleted(for: albumID)
            saveData()
            refreshDuplicateCheckAlbumCaches()
            return result
        }

        // アルバム未指定＝ライブラリ全体の一括整理（ストレージ管理画面の「重複動画を検出して削除」用）。
        // ここでも別アルバム同士のメディアを巻き込まないよう、実アルバム（システムアルバムを除く）ごとに
        // 独立してチェックし、結果を合算する。
        isDuplicateCheckRunning = true
        defer { isDuplicateCheckRunning = false }

        var aggregate = DuplicateCheckResult(checkedCount: 0, duplicateCount: 0, missingFileCount: 0, failedHashCount: 0)
        for album in duplicateCheckTargetAlbums {
            let targetItems = album.videoIDs.compactMap { itemsByID[$0] }.filter { !$0.isInTrash }
            let result = await runDuplicateScan(targetItems: targetItems, progress: { _, _ in })
            aggregate = DuplicateCheckResult(
                checkedCount: aggregate.checkedCount + result.checkedCount,
                duplicateCount: aggregate.duplicateCount + result.duplicateCount,
                missingFileCount: aggregate.missingFileCount + result.missingFileCount,
                failedHashCount: aggregate.failedHashCount + result.failedHashCount
            )
            markDuplicateCheckCompleted(for: album.id)
        }
        saveData()
        refreshDuplicateCheckAlbumCaches()
        return aggregate
    }

    /// 1つのアルバム（実アルバム）内のメディアだけを対象に、完全一致（SHA256）の重複を検出しゴミ箱へ移す。
    /// 呼び出し側が isDuplicateCheckRunning / markDuplicateCheckCompleted / saveData を管理する。
    func runDuplicateScan(targetItems: [VideoItem], progress: @MainActor @escaping (Int, Int) -> Void) async -> DuplicateCheckResult {
        struct DuplicateCandidate {
            let item: VideoItem
            let url: URL
            let fileSize: Int64
            let order: Int
        }

        var candidates = [DuplicateCandidate]()
        var missingFileCount = 0
        for (order, item) in targetItems.enumerated() {
            guard let url = fileURL(for: item) else {
                missingFileCount += 1
                continue
            }

            let fileSize = fileSize(at: url)
            candidates.append(DuplicateCandidate(item: item, url: url, fileSize: fileSize, order: order))
        }

        let candidatesBySize = Dictionary(grouping: candidates, by: \.fileSize)
        let hashTargets = candidatesBySize.values
            .filter { $0.count > 1 }
            .flatMap { $0 }

        var seenHashes = Set<String>()
        var duplicateIDs = [UUID]()
        var progressCount = 0
        var failedHashCount = 0
        let progressTotal = max(hashTargets.count, 1)

        // fileHash の算出結果はここでいったんローカルに集め、最後にまとめて videos へ反映する
        // （1件ずつ videos を書き換えると @Published が候補の数だけ発火し、写真一覧のビューが
        // チェック中ずっと再描画され続けてしまうため）。
        var computedFileHashes: [UUID: (hash: String, modificationDate: Date?)] = [:]

        // インポート時と同じ完全一致（SHA256）のみで重複判定する。サイズが同じものだけSHA256を計算するため、
        // 全ファイルのフルハッシュ化は避けられる。
        for candidate in hashTargets {
            progressCount += 1
            progress(progressCount, progressTotal)

            do {
                let result = try await fileHash(for: candidate.item, url: candidate.url)
                guard !result.hash.isEmpty else {
                    failedHashCount += 1
                    continue
                }
                computedFileHashes[candidate.item.id] = result

                if seenHashes.contains(result.hash) {
                    duplicateIDs.append(candidate.item.id)
                } else {
                    seenHashes.insert(result.hash)
                }
            } catch {
                failedHashCount += 1
                print("⚠️ [DUPLICATE] \(candidate.item.originalFilename) のハッシュ計算に失敗しました: \(error)")
            }
        }

        progress(progressTotal, progressTotal)

        // ハッシュキャッシュを（計算時点の更新日時とセットで）1回でまとめて反映する
        if !computedFileHashes.isEmpty {
            videos = videos.map { item in
                guard let result = computedFileHashes[item.id] else { return item }
                var updated = item
                updated.fileHash = result.hash
                updated.fileHashDate = result.modificationDate
                return updated
            }
        }

        if !duplicateIDs.isEmpty {
            moveToTrash(videoIDs: duplicateIDs)
        }

        return DuplicateCheckResult(
            checkedCount: targetItems.count,
            duplicateCount: duplicateIDs.count,
            missingFileCount: missingFileCount,
            failedHashCount: failedHashCount
        )
    }

    func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    nonisolated static func fileModificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // fileHash は算出のたびに videos[index].fileHash = hash のように1件ずつ書き戻すと、
    // @Published var videos が候補の数だけ発火し、写真一覧を表示しているビューが重複チェック中ずっと
    // 再描画され続けてしまう。そのため算出結果は呼び出し側（removeDuplicateMedia）でいったん
    // ローカルな辞書に集め、チェック完了後にまとめて1回だけ videos へ反映する。
    /// キャッシュ済みハッシュは「計算時点のファイル更新日時」が現在と一致する場合だけ信頼する。
    /// これがないと、同じパスのままファイルの中身が変わった（編集・上書き）後も
    /// 古いハッシュ同士を比較して重複判定を誤る。
    func fileHash(for item: VideoItem, url: URL) async throws -> (hash: String, modificationDate: Date?) {
        let currentModDate = Self.fileModificationDate(at: url)
        if !item.fileHash.isEmpty,
           let cachedDate = item.fileHashDate,
           let modDate = currentModDate,
           abs(modDate.timeIntervalSince(cachedDate)) < 1 {
            return (item.fileHash, cachedDate)
        }

        let hash = try await Task.detached(priority: .utility) {
            try LibraryViewModel.computeFileHash(for: url)
        }.value
        return (hash, currentModDate)
    }
}
