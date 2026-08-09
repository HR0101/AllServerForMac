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
    func cleanUpOrphanedFiles() {
        // ライブラリが空（読み込み失敗直後など）の状態で走らせると、Videos/ 内の
        // 実ファイル全てを「ライブラリにない孤児ファイル」と誤判定して削除してしまう。
        // 空のライブラリに孤児整理は不要なので、その場合は何もしない。
        guard !videos.isEmpty else { return }

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

    func startMissingSymlinkRepair() {
        guard symlinkRepairTask == nil else { return }
        let videosSnapshot = videos
        let videoStorageURL = self.videoStorageURL

        symlinkRepairTask = Task { [weak self] in
            let repairedNames = await Task.detached(priority: .utility) {
                Self.repairMissingSymlinks(
                    videos: videosSnapshot,
                    videoStorageURL: videoStorageURL
                )
            }.value
            guard let self, !Task.isCancelled else { return }

            if !repairedNames.isEmpty {
                self.videos = self.videos.map { item in
                    guard item.internalFilename.isEmpty,
                          let internalFilename = repairedNames[item.id] else {
                        return item
                    }
                    var updatedItem = item
                    updatedItem.internalFilename = internalFilename
                    return updatedItem
                }
                self.saveData()
            }
            self.symlinkRepairTask = nil
        }
    }

    nonisolated static func repairMissingSymlinks(
        videos: [VideoItem],
        videoStorageURL: URL
    ) -> [UUID: String] {
        let fileManager = FileManager.default
        var repairedNames: [UUID: String] = [:]

        for item in videos {
            guard !Task.isCancelled,
                  item.internalFilename.isEmpty,
                  let externalPath = item.externalFilePath else {
                continue
            }

            let sourceURL = URL(fileURLWithPath: externalPath)
            let internalFilename = "\(item.id.uuidString).\(sourceURL.pathExtension)"
            let symlinkURL = videoStorageURL.appendingPathComponent(internalFilename)
            let linkNodeExists = (try? fileManager.attributesOfItem(atPath: symlinkURL.path)) != nil
            let targetReachable = fileManager.fileExists(atPath: symlinkURL.path)

            if linkNodeExists && !targetReachable {
                try? fileManager.removeItem(at: symlinkURL)
            }
            if (try? fileManager.attributesOfItem(atPath: symlinkURL.path)) == nil {
                try? fileManager.createSymbolicLink(
                    at: symlinkURL,
                    withDestinationURL: sourceURL
                )
            }
            repairedNames[item.id] = internalFilename
        }
        return repairedNames
    }

    /// ファイルメタデータのキャッシュを捨てて、次回の並び替えで実ファイルを読み直させる。
    /// 「最後に開いた日」などセッション中に変わり得る属性を、その順で並べ直すとき最新化するために使う。
    nonisolated func refreshFileMetadataCache() {
        fileMetadataCache.value = [:]
    }

    /// 並び替え（サイズ・変更日・最後に開いた日）用に item の実ファイル属性を返す。
    /// 一度読んだものは item.id でキャッシュする。実ファイルが無ければ空の属性を返す。
    ///
    /// Mac の一覧表示と HTTP の `/albums/:id/videos` の両方がここを通る。ルート側で個別に
    /// stat し直すと、アルバムを開くたびにメディア件数ぶんのファイルIOが走り（1件あたり
    /// 実体探索＋属性読み取り）、数百〜数千件のアルバムでは一覧の応答がはっきり遅れる。
    /// ワーカースレッドから呼べるよう nonisolated にして、キャッシュごと共有する。
    nonisolated func fileMetadata(for item: VideoItem) -> VideoFileMetadata {
        if let cached = fileMetadataCache.value[item.id] { return cached }
        let meta: VideoFileMetadata
        // resourceValues はリンク自体の属性を返す（Videos/ 内のリンクだとサイズが数十バイトになる）ため、
        // 実体の属性を読むには先にリンクを解決しておく必要がある。
        // 解決は1件ずつ実ファイルを辿るぶん高くつくので、必ずこのキャッシュの内側で行う。
        if let url = LibraryViewModel.resolveFileURL(for: item, videoStorageURL: videoStorageURL, downloadStorageURL: downloadStorageURL)?
            .resolvingSymlinksInPath(),
           let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .contentAccessDateKey]) {
            meta = VideoFileMetadata(
                size: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate,
                accessDate: values.contentAccessDate
            )
        } else {
            meta = VideoFileMetadata()
        }
        fileMetadataCache.value[item.id] = meta
        return meta
    }

    /// 「Finderで表示」で選択すべき URL。フォルダインポート品は Videos/ 内のシンボリックリンク
    /// （＝アプリデータ側のエイリアス）ではなく元ファイルの場所を開きたいので、元パスを優先して返す
    /// `fileURL(for:)` の結果をシンボリックリンク解決してから返す。
    /// 元ファイルが辿れないときのみ内部のリンク自体を指す。
    func revealURL(for item: VideoItem) -> URL? {
        fileURL(for: item)?.resolvingSymlinksInPath()
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

    /// 選択したメディアの実ファイルを、指定フォルダへコピーとして書き出す。
    /// フォルダインポートは元ファイルを参照するだけでアプリはコピーを持たないため、
    /// 誤って元ファイルを消してしまった場合に備え、事前に手元へコピーを残せるようにする安全弁。
    ///
    /// サーバー上でそのメディアが属しているアルバム名（"/" 区切りのフォルダ階層も含む）を
    /// 書き出し先フォルダの下にそのまま再現し、ファイル名も元のファイル名を使う。
    /// お気に入り・ゴミ箱のように複数アルバムのメディアが混在する場面でも、
    /// アイテムごとに所属アルバムを調べてそれぞれ適切なサブフォルダへ振り分ける。
    func exportMedia(videoIDs: [UUID], to destinationFolder: URL, progress: @MainActor @escaping (Int, Int) -> Void = { _, _ in }) async -> (successCount: Int, failedCount: Int) {
        let itemsByID = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })

        // 各アイテムが属するカスタムアルバム名を1回の走査で求める（ALL VIDEOS/ALL PHOTOS は除外）。
        // 複数のアルバムに属する場合は albums 内で最初に見つかったものを使う。
        var albumNameByVideoID: [UUID: String] = [:]
        for a in albums where a.name != LibraryViewModel.allVideosAlbumName && a.name != LibraryViewModel.allPhotosAlbumName {
            for vid in a.videoIDs where albumNameByVideoID[vid] == nil {
                albumNameByVideoID[vid] = a.name
            }
        }

        var sources: [(url: URL, filename: String, albumPath: String?)] = []
        var missingCount = 0
        for id in videoIDs {
            if let item = itemsByID[id], let sourceURL = fileURL(for: item) {
                sources.append((sourceURL, item.originalFilename, albumNameByVideoID[id]))
            } else {
                missingCount += 1
            }
        }

        let total = max(sources.count, 1)
        var successCount = 0
        var failedCount = 0

        let preserveStructure = exportPreservesAlbumStructure
        for (index, source) in sources.enumerated() {
            let ok = await Task.detached(priority: .utility) { () -> Bool in
                var targetFolder = destinationFolder
                if preserveStructure, let albumPath = source.albumPath {
                    for component in albumPath.split(separator: "/") {
                        targetFolder = targetFolder.appendingPathComponent(String(component))
                    }
                    try? FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
                }

                var destinationURL = targetFolder.appendingPathComponent(source.filename)
                var counter = 2
                let nameWithoutExt = destinationURL.deletingPathExtension().lastPathComponent
                let fileExt = destinationURL.pathExtension
                while FileManager.default.fileExists(atPath: destinationURL.path) {
                    destinationURL = fileExt.isEmpty
                        ? targetFolder.appendingPathComponent("\(nameWithoutExt) (\(counter))")
                        : targetFolder.appendingPathComponent("\(nameWithoutExt) (\(counter)).\(fileExt)")
                    counter += 1
                }
                do {
                    try FileManager.default.copyItem(at: source.url, to: destinationURL)
                    return true
                } catch {
                    print("⚠️ [EXPORT] \(source.filename) の書き出しに失敗しました: \(error)")
                    return false
                }
            }.value

            if ok { successCount += 1 } else { failedCount += 1 }
            progress(index + 1, total)
        }

        return (successCount, failedCount + missingCount)
    }

    func enqueueProxyTask(sourceURL: URL, preset: String, destinationURL: URL) {
        proxyQueue.append((sourceURL: sourceURL, preset: preset, destinationURL: destinationURL))
        processNextProxyTask()
    }

    func processNextProxyTask() {
        guard !isGeneratingProxy, !proxyQueue.isEmpty else { return }
        isGeneratingProxy = true

        let nextTask = proxyQueue.removeFirst()

        Task {
            await generateProxy(sourceURL: nextTask.sourceURL, destinationURL: nextTask.destinationURL, preset: nextTask.preset)
            self.isGeneratingProxy = false
            self.processNextProxyTask()
        }
    }

    func generateProxy(sourceURL: URL, destinationURL: URL, preset: String) async {
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else { return }
        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        do {
            try await exportSession.export(to: destinationURL, as: .mp4)
        } catch {
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

    func proxyGenerationFailure(videoID: String, quality: String) -> String? {
        proxyFailureMap["\(videoID)_\(quality)"]
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
        proxyFailureMap[key] = nil
        Task { await generateOnDemandProxy(sourceURL: sourceURL, destinationURL: dest, preset: preset, key: key) }
    }

    func retryOnDemandProxy(videoID: String, quality: String) {
        proxyFailureMap["\(videoID)_\(quality)"] = nil
        startOnDemandProxy(videoID: videoID, quality: quality)
    }

    func generateOnDemandProxy(sourceURL: URL, destinationURL: URL, preset: String, key: String) async {
        try? FileManager.default.removeItem(at: destinationURL)
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            await MainActor.run {
                self.proxyProgressMap[key] = nil
                self.proxyFailureMap[key] = "このファイルはmacOSの変換機能で読み込めません。"
            }
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

        do {
            try await exportSession.export(to: destinationURL, as: .mp4)
        } catch {
            progressTimer.cancel()
            await MainActor.run {
                self.proxyProgressMap[key] = nil
                self.proxyFailureMap[key] = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: destinationURL)
            return
        }
        progressTimer.cancel()

        await MainActor.run {
            self.proxyProgressMap[key] = nil   // 完了/失敗で生成中フラグを解除
            self.proxyFailureMap[key] = nil
        }
    }

    /// 指定URL以外のプロキシを全削除する (常に1本だけ保持するため)
    func sweepProxies(except keepURL: URL?) {
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

    /// ホーム画面に表示する使用容量（キャッシュ済み・バックグラウンドで定期更新）。
    /// 件数が多いとファイル存在チェック・サイズ取得だけで数万回のディスクI/Oになるため、
    /// 描画のたびに同期計算すると（特にダッシュボードは1秒おきに再描画されるため）致命的に重くなる。
    func startStorageSizeAutoRefresh(
        initialDelayNanoseconds: UInt64
    ) {
        guard storageSizeRefreshTask == nil else { return }
        storageSizeRefreshTask = Task { [weak self] in
            if initialDelayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: initialDelayNanoseconds)
                } catch {
                    return
                }
            }

            while !Task.isCancelled {
                guard let self else { return }
                self.refreshTotalStorageSize()
                // 全ファイルの存在チェック・サイズ取得はライブラリが大きいと相応のディスクI/Oになるため、
                // 60秒だと頻度が高すぎた。使用容量はそこまで頻繁に変わらないので5分間隔に緩和する。
                do {
                    try await Task.sleep(nanoseconds: 300_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    func refreshTotalStorageSize() {
        let videosSnapshot = videos
        let videoStorageURL = self.videoStorageURL
        let downloadStorageURL = self.downloadStorageURL
        Task.detached(priority: .background) {
            let text = LibraryViewModel.computeTotalStorageSizeText(
                videos: videosSnapshot,
                videoStorageURL: videoStorageURL,
                downloadStorageURL: downloadStorageURL
            )
            await MainActor.run { [weak self] in
                self?.totalStorageSizeText = text
            }
        }
    }

    /// `fileURL(for:)` と同じ解決ロジックのスレッド非依存版。
    /// ストレージ集計やHTTPルート（ワーカースレッド）から使う。
    nonisolated static func resolveFileURL(for item: VideoItem, videoStorageURL: URL, downloadStorageURL: URL) -> URL? {
        if let extPath = item.externalFilePath {
            let extURL = URL(fileURLWithPath: extPath)
            if FileManager.default.fileExists(atPath: extURL.path) { return extURL }
        }
        if !item.internalFilename.isEmpty {
            let hiddenURL = videoStorageURL.appendingPathComponent(item.internalFilename)
            if FileManager.default.fileExists(atPath: hiddenURL.path) { return hiddenURL }
            let downloadURL = downloadStorageURL.appendingPathComponent(item.internalFilename)
            if FileManager.default.fileExists(atPath: downloadURL.path) { return downloadURL }
        }
        return nil
    }

    nonisolated static func computeTotalStorageSizeText(videos: [VideoItem], videoStorageURL: URL, downloadStorageURL: URL) -> String {
        let totalSize = videos.reduce(Int64(0)) { result, item in
            guard let url = resolveFileURL(for: item, videoStorageURL: videoStorageURL, downloadStorageURL: downloadStorageURL) else { return result }
            let resources = try? url.resourceValues(forKeys: [.fileSizeKey])
            return result + Int64(resources?.fileSize ?? 0)
        }
        let formatter = ByteCountFormatter(); formatter.allowedUnits = [.useGB, .useMB, .useKB]; formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
}
