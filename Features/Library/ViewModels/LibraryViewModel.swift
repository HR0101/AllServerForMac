import Foundation
import AppKit
import AVFoundation
import CryptoKit
import Combine
import Darwin
import Dispatch
import ImageIO
import UniformTypeIdentifiers
import Vision



@MainActor
class LibraryViewModel: ObservableObject {
    @Published var videos: [VideoItem] = [] {
        didSet {
            snapshotLibrary.value = LibrarySnapshotData(videos: videos, albums: albums)
            cachedExistingSourcePaths = nil
        }
    }

    /// `existingImportedSourcePaths()` の結果キャッシュ。リンクフォルダが数百件あると、
    /// アルバムごとに毎回 videos 全件を resolvingSymlinksInPath() し直すコストが
    /// 「アルバム数 × 動画数」で効いてきて起動時/定期スキャン時にメインスレッドが固まるため、
    /// videos が変化しない限り使い回す（変化した時だけ videos の didSet で無効化する）。
    var cachedExistingSourcePaths: Set<String>?
    @Published var albums: [Album] = [] {
        didSet { snapshotLibrary.value = LibrarySnapshotData(videos: videos, albums: albums) }
    }

    /// HTTPルート（ワーカースレッド）用の読み取り専用スナップショット。
    /// videos/albums の didSet で常に同期される（配列の代入は CoW なので軽い）。
    nonisolated let snapshotLibrary = LockedBox<LibrarySnapshotData>(LibrarySnapshotData(videos: [], albums: []))
    @Published var duplicateCheckStates: [UUID: DuplicateCheckState] = [:]
    @Published var isDuplicateCheckRunning = false
    @Published var linkedFolderConflicts: [LinkedFolderConflict] = []
    let duplicateCheckStatus = DuplicateCheckStatus()

    /// 自動重複チェック（バックグラウンドで定期的に走るもの）のオン/オフ。手動チェック（アルバム内の「重複チェック」ボタン）には影響しない。
    @Published var isAutoDuplicateCheckEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoDuplicateCheckEnabled, forKey: "autoDuplicateCheckEnabled")
        }
    }

    // MARK: - ユーザー設定（詳細設定シートから変更できる項目）

    /// インポート時にファイルをアプリの管理フォルダへコピーする（true）か、元の場所を参照するだけ（false, 既定）か。
    /// コピーにすれば元フォルダを消してもサーバー内に実体が残るが、ディスク容量を消費する。
    @Published var importCopiesFiles: Bool {
        didSet { UserDefaults.standard.set(importCopiesFiles, forKey: "importCopiesFiles") }
    }

    /// ゴミ箱の自動削除期限（日数）。0 = 自動削除しない（既定）。
    @Published var trashAutoDeleteDays: Int {
        didSet { UserDefaults.standard.set(trashAutoDeleteDays, forKey: "trashAutoDeleteDays") }
    }

    /// 起動時にリンク切れメディア（元ファイルが見つからないデータ）を自動整理するか。既定はオフ。
    /// 外付けドライブのメディアを参照している場合、未接続時に誤って消えるためオフを推奨。
    @Published var autoCleanupMissingFilesEnabled: Bool {
        didSet { UserDefaults.standard.set(autoCleanupMissingFilesEnabled, forKey: "autoCleanupMissingFilesEnabled") }
    }

    /// 自動重複チェックの実行間隔（秒）。既定30秒。
    @Published var duplicateCheckIntervalSeconds: Int {
        didSet { UserDefaults.standard.set(duplicateCheckIntervalSeconds, forKey: "duplicateCheckIntervalSeconds") }
    }

    /// 一括インポートの並列処理数。既定4。
    @Published var importConcurrency: Int {
        didSet { UserDefaults.standard.set(importConcurrency, forKey: "importConcurrency") }
    }

    /// エクスポート時にアルバムの階層構造をフォルダとして再現する（true, 既定）か、フラットに書き出す（false）か。
    @Published var exportPreservesAlbumStructure: Bool {
        didSet { UserDefaults.standard.set(exportPreservesAlbumStructure, forKey: "exportPreservesAlbumStructure") }
    }

    let appRootURL: URL
    // HTTPルート（ワーカースレッド）から実ファイル属性を読むため、isolation に依らず参照できるようにする。
    nonisolated let videoStorageURL: URL
    nonisolated let downloadStorageURL: URL
    let thumbnailStorageURL: URL
    let proxyStorageURL: URL
    let dataFileURL: URL

    /// library.json の現行スキーマ世代。フィールドを追加したら上げる。
    nonisolated static let librarySchemaVersion = 3

    static let allVideosAlbumName = "ALL VIDEOS"
    static let allPhotosAlbumName = "ALL PHOTOS"
    static let duplicateCheckVersion = "duplicate-v3-exact"

    var proxyQueue: [(sourceURL: URL, preset: String, destinationURL: URL)] = []
    var isGeneratingProxy = false
    var duplicateAutoCheckTask: Task<Void, Never>?
    var linkedFolderScanTasks: [UUID: Task<Void, Never>] = [:]
    var initialLinkedFolderScanTask: Task<Void, Never>?

    /// リンクフォルダの手動更新（ホーム画面のボタン）の進捗。ギャラリーを巻き込んで
    /// 再描画しないよう本体とは別の ObservableObject に分離している。
    let linkedFolderScanStatus = LinkedFolderScanStatus()

    // key: "<videoID>_<quality>", 値: 0...1 の進捗、nil = 生成していない
    var proxyProgressMap: [String: Double] = [:]

    var pendingSaveTask: Task<Void, Never>?
    var libraryLoadTask: Task<Void, Never>?
    var saveGeneration = 0

    @Published var isLibraryLoaded = false

    /// 並び替え用ファイルメタデータの遅延キャッシュです．
    nonisolated let fileMetadataCache = LockedBox<[UUID: VideoFileMetadata]>([:])

    /// ホーム画面に表示する使用容量です．ディスクI/Oを避けるため定期更新します．
    @Published var totalStorageSizeText: String = "計算中…"
    var storageSizeRefreshTask: Task<Void, Never>?

    /// 同じライブラリを開いている別インスタンスが既に存在する場合 true。
    /// このとき保存系は一切行わず、起動直後にユーザーへ通知して終了する。
    private(set) var isSecondaryInstance = false

    /// 排他ロックを取得する。取得したファイル記述子は意図的に開いたままにし、
    /// プロセス終了（クラッシュ含む）でOSが自動解放するのに任せる。
    nonisolated static func acquireInstanceLock(at url: URL) -> Bool {
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd != -1 else { return true } // ロックファイル自体を作れない環境では起動を妨げない
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        return true
    }

    init() {
        guard let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            fatalError("Movies directory not found.")
        }
        guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            fatalError("Downloads directory not found.")
        }

        self.appRootURL = moviesDir.appendingPathComponent("MacVideoServerData")
        self.videoStorageURL = self.appRootURL.appendingPathComponent("Videos")
        self.thumbnailStorageURL = self.appRootURL.appendingPathComponent("Thumbnails")
        self.proxyStorageURL = self.appRootURL.appendingPathComponent("Proxies")
        self.dataFileURL = self.appRootURL.appendingPathComponent("library.json")
        self.downloadStorageURL = downloadsDir.appendingPathComponent("VideoServerForMac_Media")
        self.isAutoDuplicateCheckEnabled = UserDefaults.standard.object(forKey: "autoDuplicateCheckEnabled") as? Bool ?? true
        self.importCopiesFiles = UserDefaults.standard.object(forKey: "importCopiesFiles") as? Bool ?? false
        self.trashAutoDeleteDays = UserDefaults.standard.object(forKey: "trashAutoDeleteDays") as? Int ?? 0
        self.autoCleanupMissingFilesEnabled = UserDefaults.standard.object(forKey: "autoCleanupMissingFilesEnabled") as? Bool ?? false
        self.duplicateCheckIntervalSeconds = UserDefaults.standard.object(forKey: "duplicateCheckIntervalSeconds") as? Int ?? 30
        self.importConcurrency = UserDefaults.standard.object(forKey: "importConcurrency") as? Int ?? 4
        self.exportPreservesAlbumStructure = UserDefaults.standard.object(forKey: "exportPreservesAlbumStructure") as? Bool ?? true

        try? FileManager.default.createDirectory(at: self.videoStorageURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.downloadStorageURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.thumbnailStorageURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.proxyStorageURL, withIntermediateDirectories: true)

        // 二重起動の検出。Xcodeからの実行と/Applications版は別アプリとして同時起動でき、
        // 両方が同じ library.json をデバウンス保存すると後勝ちでサイレントにデータが失われる。
        // flock はプロセス終了（クラッシュ含む）で自動解放されるため、確実に片方だけが書ける。
        isSecondaryInstance = !Self.acquireInstanceLock(at: appRootURL.appendingPathComponent(".instance.lock"))
        if isSecondaryInstance {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "AllServerForMac は既に起動しています"
                alert.informativeText = "別のインスタンス（例: Xcodeからの実行と通常起動）が同じライブラリを開いています。データの二重書き込みによる消失を防ぐため、このインスタンスは終了します。"
                alert.alertStyle = .warning
                alert.runModal()
                NSApplication.shared.terminate(nil)
            }
            return
        }

        startLoadingData()

        // 保存はデバウンスされているため、終了時に保留中の分を確実に書き込む
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.libraryLoadTask?.cancel()
                self?.cancelPendingLinkedFolderScans()
                self?.flushPendingSave()
            }
        }
    }

    nonisolated func getStorageUsage() async -> (videosSize: Int64, proxiesSize: Int64, downloadsSize: Int64, appTotalSize: Int64) {
        let videoStorageURL = self.videoStorageURL
        let proxyStorageURL = self.proxyStorageURL
        let downloadStorageURL = self.downloadStorageURL
        let appRootURL = self.appRootURL

        return await Task.detached(priority: .utility) {
            var vSize: Int64 = 0
            var pSize: Int64 = 0
            var dSize: Int64 = 0
            var totalSize: Int64 = 0

            if let urls = try? FileManager.default.contentsOfDirectory(at: videoStorageURL, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) {
                for url in urls {
                    let res = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                    if res?.isSymbolicLink == false { vSize += Int64(res?.fileSize ?? 0) }
                }
            }
            if let urls = try? FileManager.default.contentsOfDirectory(at: proxyStorageURL, includingPropertiesForKeys: [.fileSizeKey]) {
                for url in urls {
                    let res = try? url.resourceValues(forKeys: [.fileSizeKey])
                    pSize += Int64(res?.fileSize ?? 0)
                }
            }
            if let urls = try? FileManager.default.contentsOfDirectory(at: downloadStorageURL, includingPropertiesForKeys: [.fileSizeKey]) {
                for url in urls {
                    let res = try? url.resourceValues(forKeys: [.fileSizeKey])
                    dSize += Int64(res?.fileSize ?? 0)
                }
            }
            if let enumerator = FileManager.default.enumerator(at: appRootURL, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) {
                while let url = enumerator.nextObject() as? URL {
                    let res = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                    if res?.isSymbolicLink == false { totalSize += Int64(res?.fileSize ?? 0) }
                }
            }
            return (vSize, pSize, dSize, totalSize)
        }.value
    }

    func openAppRootFolderInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: appRootURL.path)
    }

    func openTempFolderInFinder() {
        let tempDir = FileManager.default.temporaryDirectory
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: tempDir.path)
    }
}
