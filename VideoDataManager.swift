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



// MARK: - Shared Utilities

func isImagePredominantlyBlack(image: CGImage, threshold: CGFloat = 0.1) -> Bool {
    let size = 20
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var rawData = [UInt8](repeating: 0, count: size * size * 4)
    guard let context = CGContext(
        data: &rawData, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
    var darkPixelCount = 0
    for i in 0..<(size * size) {
        let offset = i * 4
        let luminance = 0.299 * CGFloat(rawData[offset]) / 255.0
                      + 0.587 * CGFloat(rawData[offset + 1]) / 255.0
                      + 0.114 * CGFloat(rawData[offset + 2]) / 255.0
        if luminance < threshold { darkPixelCount += 1 }
    }
    return Double(darkPixelCount) / Double(size * size) > 0.8
}

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
    var internalFilename: String
    let duration: TimeInterval
    let importDate: Date
    let creationDate: Date?
    var fileHash: String
    var mediaType: MediaType = .video

    var externalFilePath: String?

    var isFavorite: Bool = false
    var isInTrash: Bool = false
    /// ゴミ箱に入れた日時。ゴミ箱の自動削除期限（設定）で使う。nil はゴミ箱に入っていないか旧データ。
    var trashedDate: Date? = nil
    /// fileHash を計算した時点のファイル更新日時。ファイルの中身が後から変わった場合に
    /// 古いハッシュを使い続けないための検証用。nil は旧データ（＝ハッシュは信頼しない）。
    var fileHashDate: Date? = nil

    init(id: UUID, originalFilename: String, internalFilename: String, duration: TimeInterval, importDate: Date, creationDate: Date?, fileHash: String, mediaType: MediaType = .video, externalFilePath: String? = nil, isFavorite: Bool = false, isInTrash: Bool = false, trashedDate: Date? = nil) {
        self.id = id
        self.originalFilename = originalFilename
        self.internalFilename = internalFilename
        self.duration = duration
        self.importDate = importDate
        self.creationDate = creationDate
        self.fileHash = fileHash
        self.mediaType = mediaType
        self.externalFilePath = externalFilePath
        self.isFavorite = isFavorite
        self.isInTrash = isInTrash
        self.trashedDate = trashedDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.originalFilename = try container.decode(String.self, forKey: .originalFilename)
        self.internalFilename = try container.decode(String.self, forKey: .internalFilename)
        self.duration = try container.decode(TimeInterval.self, forKey: .duration)
        self.importDate = try container.decode(Date.self, forKey: .importDate)
        self.creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate)
        self.fileHash = try container.decode(String.self, forKey: .fileHash)
        self.mediaType = try container.decodeIfPresent(MediaType.self, forKey: .mediaType) ?? .video
        self.externalFilePath = try container.decodeIfPresent(String.self, forKey: .externalFilePath)
        self.isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        self.isInTrash = try container.decodeIfPresent(Bool.self, forKey: .isInTrash) ?? false
        self.trashedDate = try container.decodeIfPresent(Date.self, forKey: .trashedDate)
        self.fileHashDate = try container.decodeIfPresent(Date.self, forKey: .fileHashDate)
    }
}

/// 並び替え（サイズ・変更日・最後に開いた日）のために実ファイルから読む属性。
/// VideoItem には保持していないので、必要になった時だけ stat して埋める。
struct VideoFileMetadata {
    var size: Int64 = 0
    var modificationDate: Date? = nil
    var accessDate: Date? = nil
}

struct Album: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var videoIDs: [UUID]
    var type: AlbumType
    var linkedFolderPath: String?
    var linkedFolderBookmarkData: Data?
    
    init(
        id: UUID,
        name: String,
        videoIDs: [UUID],
        type: AlbumType,
        linkedFolderPath: String? = nil,
        linkedFolderBookmarkData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.videoIDs = videoIDs
        self.type = type
        self.linkedFolderPath = linkedFolderPath
        self.linkedFolderBookmarkData = linkedFolderBookmarkData
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.videoIDs = try container.decode([UUID].self, forKey: .videoIDs)
        self.type = try container.decodeIfPresent(AlbumType.self, forKey: .type) ?? .video
        self.linkedFolderPath = try container.decodeIfPresent(String.self, forKey: .linkedFolderPath)
        self.linkedFolderBookmarkData = try container.decodeIfPresent(Data.self, forKey: .linkedFolderBookmarkData)
    }
}

struct LinkedFolderCandidate: Identifiable, Hashable {
    let id: String
    let conflictID: String
    let albumID: UUID?
    let albumName: String
    let albumType: AlbumType
    let folderPath: String
    let matchCount: Int
}

struct LinkedFolderConflict: Identifiable, Hashable {
    let id: String
    let albumID: UUID?
    let albumName: String
    let albumType: AlbumType
    let candidates: [LinkedFolderCandidate]
}

private nonisolated struct DataContainer: Codable {
    var videos: [VideoItem]
    var albums: [Album]
    var duplicateCheckStates: [UUID: DuplicateCheckState]?
    /// ライブラリJSONのスキーマ世代。古いビルドはこのキーを知らないまま読み書きして
    /// 新フィールドを黙って落とすため、少なくとも「自分より新しい形式か」を
    /// 新しいビルド側で検知できるようにしておく（nil は旧ビルドが書いたデータ）。
    var schemaVersion: Int? = nil
}

/// ロック付きの値ボックス。メインアクター側で書き込み、HTTPワーカースレッドから読む。
/// サーバーの各ルートが DispatchQueue.main.sync でライブラリを読むと、
/// Mac の UI が忙しいときに iOS への応答が止まり、逆にリクエストラッシュが
/// Mac の UI をカクつかせるため、ルートはこのスナップショット経由で読む。
nonisolated final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        _value = value
    }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

struct DuplicateCheckState: Codable, Hashable {
    let checkedAt: Date
    let albumSignature: String
}

struct DuplicateCheckResult {
    let checkedCount: Int
    let duplicateCount: Int
    let missingFileCount: Int
    let failedHashCount: Int
}

/// リンクフォルダの手動更新（ホーム画面のボタン）の進捗状態。VideoDataManager 本体とは別の
/// ObservableObject に分離することで、スキャン中に更新される statusMessage が、写真・動画一覧を
/// 表示する巨大なギャラリービュー（videos/albums を @Published で購読している側）まで
/// 再描画させないようにする（DuplicateCheckStatus と同じ理由）。
final class LinkedFolderScanStatus: ObservableObject {
    @Published var isScanning = false
    /// これまでに確認し終えたフォルダ数（進捗バーの分子）。
    @Published var processedCount = 0
    /// 今回の更新で対象になったフォルダ総数（進捗バーの分母）。
    @Published var totalCount = 0
    /// 現在スキャン中のフォルダ（アルバム）名。
    @Published var currentFolderName: String?
    /// 現在のフォルダで新しく取り込んだメディア件数（単一フォルダでも進捗が動いて見えるように）。
    @Published var processedItemsInCurrentFolder = 0
    /// スキャン完了後などに表示するメッセージ。
    @Published var statusMessage = ""
}

/// 自動重複チェックの進捗状態。VideoDataManager 本体とは別の ObservableObject に分離することで、
/// ハッシュ計算中に頻繁に更新される progress/statusMessage が、写真・動画一覧を表示する
/// 巨大なギャラリービュー（videos/albums を @Published で購読している側）まで再描画させないようにする。
final class DuplicateCheckStatus: ObservableObject {
    @Published var isAutoChecking = false
    @Published var currentAlbumName: String?
    @Published var progress: Double = 0
    @Published var statusMessage = "待機中"

    // チェック済み/未チェックのアルバム一覧はダッシュボードの表示用キャッシュ。
    // 署名（アルバム内の全動画IDをソートして連結した文字列）の再計算はアルバム件数が多いと軽くないため、
    // 描画のたびではなく自動チェックループ（数十秒おき）やチェック完了時にだけ更新する。
    @Published var checkedAlbums: [Album] = []
    @Published var uncheckedAlbums: [Album] = []
}

/// HTTPルートへ渡すライブラリの一貫スナップショット。videos と albums を別々のロックで
/// 読むと、その間の変更で「アルバムにはIDがあるのに動画リストに無い」ような不整合な
/// ペアになるため、必ず1つの値として原子的に読み書きする。
nonisolated struct LibrarySnapshotData {
    var videos: [VideoItem]
    var albums: [Album]
}

@MainActor
class VideoDataManager: ObservableObject {
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
    private var cachedExistingSourcePaths: Set<String>?
    @Published var albums: [Album] = [] {
        didSet { snapshotLibrary.value = LibrarySnapshotData(videos: videos, albums: albums) }
    }

    /// HTTPルート（ワーカースレッド）用の読み取り専用スナップショット。
    /// videos/albums の didSet で常に同期される（配列の代入は CoW なので軽い）。
    nonisolated let snapshotLibrary = LockedBox<LibrarySnapshotData>(LibrarySnapshotData(videos: [], albums: []))
    @Published private(set) var duplicateCheckStates: [UUID: DuplicateCheckState] = [:]
    @Published private(set) var isDuplicateCheckRunning = false
    @Published private(set) var linkedFolderConflicts: [LinkedFolderConflict] = []
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
    let videoStorageURL: URL
    let downloadStorageURL: URL
    let thumbnailStorageURL: URL
    let proxyStorageURL: URL
    private let dataFileURL: URL
    
    /// library.json の現行スキーマ世代。フィールドを追加したら上げる。
    nonisolated static let librarySchemaVersion = 3

    static let allVideosAlbumName = "ALL VIDEOS"
    static let allPhotosAlbumName = "ALL PHOTOS"
    private static let duplicateCheckVersion = "duplicate-v3-exact"

    private var proxyQueue: [(sourceURL: URL, preset: String, destinationURL: URL)] = []
    private var isGeneratingProxy = false
    private var duplicateAutoCheckTask: Task<Void, Never>?
    private var linkedFolderScanTasks: [UUID: Task<Void, Never>] = [:]
    private var initialLinkedFolderScanTask: Task<Void, Never>?

    /// リンクフォルダの手動更新（ホーム画面のボタン）の進捗。ギャラリーを巻き込んで
    /// 再描画しないよう本体とは別の ObservableObject に分離している。
    let linkedFolderScanStatus = LinkedFolderScanStatus()

    // key: "<videoID>_<quality>", 値: 0...1 の進捗、nil = 生成していない
    private var proxyProgressMap: [String: Double] = [:]

    private var pendingSaveTask: Task<Void, Never>?

    /// 同じライブラリを開いている別インスタンスが既に存在する場合 true。
    /// このとき保存系は一切行わず、起動直後にユーザーへ通知して終了する。
    private(set) var isSecondaryInstance = false

    /// 排他ロックを取得する。取得したファイル記述子は意図的に開いたままにし、
    /// プロセス終了（クラッシュ含む）でOSが自動解放するのに任せる。
    nonisolated private static func acquireInstanceLock(at url: URL) -> Bool {
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

        loadData()
        repairMissingSymlinks()
        refreshDuplicateCheckAlbumCaches()
        startAutomaticDuplicateChecks()
        startStorageSizeAutoRefresh()
        purgeExpiredTrash()
        // リンク切れの自動整理は誤削除のリスクがあるため既定オフの設定制。
        // （外付けドライブのメディアを参照している場合、未接続時に誤って消える）
        if autoCleanupMissingFilesEnabled {
            runAutomaticMissingFileCleanup()
        }
        reconcileLinkedFoldersFromExistingPaths()
        // リンクフォルダの取り込みは、60秒ごとの自動ポーリング＋ファイル監視をやめ、
        // ホーム画面の「リンクフォルダを更新」ボタンによる手動実行に切り替えた。
        // 件数が多いと自動スキャンがメインスレッドを圧迫してUIがカクつくため。
        // ただし、アプリを閉じている間にFinder側で増減したメディアを反映するため、
        // 起動時だけは一度自動スキャンする（以降の更新は手動ボタン）。
        startInitialLinkedFolderScan()

        // 保存はデバウンスされているため、終了時に保留中の分を確実に書き込む
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
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

    var duplicateCheckTargetAlbums: [Album] {
        let activeIDs = Set(videos.filter { !$0.isInTrash }.map { $0.id })
        return albums.filter { album in
            album.name != VideoDataManager.allVideosAlbumName &&
            album.name != VideoDataManager.allPhotosAlbumName &&
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
    private func refreshDuplicateCheckAlbumCaches() {
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
    private func albumNeedsDuplicateCheck(_ album: Album, trashedIDs: Set<UUID>) -> Bool {
        guard let state = duplicateCheckStates[album.id] else { return true }
        return state.albumSignature != duplicateCheckSignature(for: album, trashedIDs: trashedIDs)
    }

    private func duplicateCheckSignature(for album: Album) -> String {
        duplicateCheckSignature(for: album, trashedIDs: Set(videos.filter { $0.isInTrash }.map { $0.id }))
    }

    private func duplicateCheckSignature(for album: Album, trashedIDs: Set<UUID>) -> String {
        let mediaSignature = album.videoIDs
            .filter { !trashedIDs.contains($0) }
            .map { $0.uuidString }
            .sorted()
            .joined(separator: "|")
        return "\(Self.duplicateCheckVersion)|\(mediaSignature)"
    }

    private func markDuplicateCheckCompleted(for albumID: UUID) {
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
            guard album.name != VideoDataManager.allVideosAlbumName, album.name != VideoDataManager.allPhotosAlbumName else {
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
    private func runDuplicateScan(targetItems: [VideoItem], progress: @MainActor @escaping (Int, Int) -> Void) async -> DuplicateCheckResult {
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

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    nonisolated private static func fileModificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // fileHash は算出のたびに videos[index].fileHash = hash のように1件ずつ書き戻すと、
    // @Published var videos が候補の数だけ発火し、写真一覧を表示しているビューが重複チェック中ずっと
    // 再描画され続けてしまう。そのため算出結果は呼び出し側（removeDuplicateMedia）でいったん
    // ローカルな辞書に集め、チェック完了後にまとめて1回だけ videos へ反映する。
    /// キャッシュ済みハッシュは「計算時点のファイル更新日時」が現在と一致する場合だけ信頼する。
    /// これがないと、同じパスのままファイルの中身が変わった（編集・上書き）後も
    /// 古いハッシュ同士を比較して重複判定を誤る。
    private func fileHash(for item: VideoItem, url: URL) async throws -> (hash: String, modificationDate: Date?) {
        let currentModDate = Self.fileModificationDate(at: url)
        if !item.fileHash.isEmpty,
           let cachedDate = item.fileHashDate,
           let modDate = currentModDate,
           abs(modDate.timeIntervalSince(cachedDate)) < 1 {
            return (item.fileHash, cachedDate)
        }

        let hash = try await Task.detached(priority: .utility) {
            try VideoDataManager.computeFileHash(for: url)
        }.value
        return (hash, currentModDate)
    }

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
    
    private func repairMissingSymlinks() {
        // for ループの中で videos[i].xxx = ... を1件ずつ書き換えると対象件数だけ @Published が発火するため
        // （インポート直後の初回起動で数千件が一気に対象になりうる）、更新後の配列を作ってから1回で代入する。
        var needsSave = false
        let updated = videos.map { item -> VideoItem in
            guard item.internalFilename.isEmpty, let extPath = item.externalFilePath else { return item }

            let sourceURL = URL(fileURLWithPath: extPath)
            let ext = sourceURL.pathExtension
            let newInternal = "\(item.id.uuidString).\(ext)"
            let symlinkURL = videoStorageURL.appendingPathComponent(newInternal)

            // fileExists はシンボリックリンクを「辿って」判定するため、リンク切れリンクは
            // 「存在しない」と報告される。一方 createSymbolicLink はリンクノード自体が残っていると
            // 「既に存在する」で失敗するため、まずリンクノードの有無を（辿らない）attributesOfItem で
            // 確認し、リンク切れなら削除してから作り直す。これをしないと毎起動失敗し続ける。
            let linkNodeExists = (try? FileManager.default.attributesOfItem(atPath: symlinkURL.path)) != nil
            let targetReachable = FileManager.default.fileExists(atPath: symlinkURL.path)
            if linkNodeExists && !targetReachable {
                try? FileManager.default.removeItem(at: symlinkURL)
            }
            if (try? FileManager.default.attributesOfItem(atPath: symlinkURL.path)) == nil {
                try? FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: sourceURL)
            }
            var updatedItem = item
            updatedItem.internalFilename = newInternal
            needsSave = true
            return updatedItem
        }
        if needsSave {
            videos = updated
            saveData()
        }
    }
    
    /// 並び替え用ファイルメタデータの遅延キャッシュ（item.id → 属性）。
    /// サイズ・変更日で並べ替えるたびに全ファイルを stat し直すと重いので一度読んだら使い回す。
    /// サイズや変更日はセッション中まず変わらないため、明示的な無効化はしていない。
    private var fileMetadataCache: [UUID: VideoFileMetadata] = [:]

    /// ファイルメタデータのキャッシュを捨てて、次回の並び替えで実ファイルを読み直させる。
    /// 「最後に開いた日」などセッション中に変わり得る属性を、その順で並べ直すとき最新化するために使う。
    func refreshFileMetadataCache() {
        fileMetadataCache.removeAll()
    }

    /// 並び替え（サイズ・変更日・最後に開いた日）用に item の実ファイル属性を返す。
    /// 一度読んだものは item.id でキャッシュする。実ファイルが無ければ空の属性を返す。
    func fileMetadata(for item: VideoItem) -> VideoFileMetadata {
        if let cached = fileMetadataCache[item.id] { return cached }
        let meta: VideoFileMetadata
        if let url = fileURL(for: item),
           let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .contentAccessDateKey]) {
            meta = VideoFileMetadata(
                size: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate,
                accessDate: values.contentAccessDate
            )
        } else {
            meta = VideoFileMetadata()
        }
        fileMetadataCache[item.id] = meta
        return meta
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
        for a in albums where a.name != VideoDataManager.allVideosAlbumName && a.name != VideoDataManager.allPhotosAlbumName {
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

    private func enqueueProxyTask(sourceURL: URL, preset: String, destinationURL: URL) {
        proxyQueue.append((sourceURL: sourceURL, preset: preset, destinationURL: destinationURL))
        processNextProxyTask()
    }
    
    private func processNextProxyTask() {
        guard !isGeneratingProxy, !proxyQueue.isEmpty else { return }
        isGeneratingProxy = true
        
        let nextTask = proxyQueue.removeFirst()
        
        Task {
            await generateProxy(sourceURL: nextTask.sourceURL, destinationURL: nextTask.destinationURL, preset: nextTask.preset)
            self.isGeneratingProxy = false
            self.processNextProxyTask()
        }
    }
    
    private func generateProxy(sourceURL: URL, destinationURL: URL, preset: String) async {
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
        Task { await generateOnDemandProxy(sourceURL: sourceURL, destinationURL: dest, preset: preset, key: key) }
    }

    private func generateOnDemandProxy(sourceURL: URL, destinationURL: URL, preset: String, key: String) async {
        try? FileManager.default.removeItem(at: destinationURL)
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            await MainActor.run { self.proxyProgressMap[key] = nil }
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
            await MainActor.run { self.proxyProgressMap[key] = nil }
            try? FileManager.default.removeItem(at: destinationURL)
            return
        }
        progressTimer.cancel()

        await MainActor.run {
            self.proxyProgressMap[key] = nil   // 完了/失敗で生成中フラグを解除
        }
    }

    /// 指定URL以外のプロキシを全削除する (常に1本だけ保持するため)
    private func sweepProxies(except keepURL: URL?) {
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
    @Published private(set) var totalStorageSizeText: String = "計算中…"
    private var storageSizeRefreshTask: Task<Void, Never>?

    private func startStorageSizeAutoRefresh() {
        guard storageSizeRefreshTask == nil else { return }
        storageSizeRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshTotalStorageSize()
                // 全ファイルの存在チェック・サイズ取得はライブラリが大きいと相応のディスクI/Oになるため、
                // 60秒だと頻度が高すぎた。使用容量はそこまで頻繁に変わらないので5分間隔に緩和する。
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
        }
    }

    func refreshTotalStorageSize() {
        let videosSnapshot = videos
        let videoStorageURL = self.videoStorageURL
        let downloadStorageURL = self.downloadStorageURL
        Task.detached(priority: .background) {
            let text = VideoDataManager.computeTotalStorageSizeText(
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

    nonisolated private static func computeTotalStorageSizeText(videos: [VideoItem], videoStorageURL: URL, downloadStorageURL: URL) -> String {
        let totalSize = videos.reduce(Int64(0)) { result, item in
            guard let url = resolveFileURL(for: item, videoStorageURL: videoStorageURL, downloadStorageURL: downloadStorageURL) else { return result }
            let resources = try? url.resourceValues(forKeys: [.fileSizeKey])
            return result + Int64(resources?.fileSize ?? 0)
        }
        let formatter = ByteCountFormatter(); formatter.allowedUnits = [.useGB, .useMB, .useKB]; formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }

    private func bookmarkData(for folderURL: URL) -> Data? {
        try? folderURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func resolvedLinkedFolderURL(for album: Album) -> URL? {
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

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func existingImportedSourcePaths() -> Set<String> {
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

    private func newMediaFiles(from urls: [URL], existingPaths: Set<String>) -> [URL] {
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

    func confirmLinkedFolderCandidate(_ candidate: LinkedFolderCandidate) {
        guard let albumID = existingOrCreateAlbumID(name: candidate.albumName, type: candidate.albumType, preferredID: candidate.albumID) else {
            return
        }
        setLinkedFolder(folderURL: URL(fileURLWithPath: candidate.folderPath), albumID: albumID)
        linkedFolderConflicts.removeAll { $0.id == candidate.conflictID }
        scheduleLinkedFolderScan(albumID: albumID, delayNanoseconds: 500_000_000)
    }

    private func setLinkedFolder(folderURL: URL, albumID: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        albums[index].linkedFolderPath = folderURL.path
        albums[index].linkedFolderBookmarkData = bookmarkData(for: folderURL)
        saveData()
    }

    private func existingOrCreateAlbumID(name: String, type: AlbumType, preferredID: UUID? = nil) -> UUID? {
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
    private func mergeDuplicateFolderAlbums() {
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

    private func reconcileLinkedFoldersFromExistingPaths() {
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
                confirmLinkedFolderCandidate(candidate)
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
                confirmLinkedFolderCandidate(candidate)
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

    private func linkedFolderCandidateCounts(
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

    private func virtualFolderCandidates(
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

    private func albumPathComponents(_ name: String) -> [String] {
        name.split(separator: "/").map(String.init)
    }

    private func combinedAlbumType(_ lhs: AlbumType?, _ rhs: AlbumType) -> AlbumType {
        guard let lhs else { return rhs }
        return lhs == rhs ? lhs : .mixed
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// 名前パスから導かれる階層アルバム（例: "Bengugu/陽夜"）と、同じ物理フォルダに
    /// 直接紐づけられた単体アルバム（例: "陽夜"）が両方存在する場合、片方だけが
    /// 再スキャンされて新規メディアが割れてしまう問題を防ぐため、
    /// 同じフォルダを指す候補の中からメディア数が最も多いアルバムへ寄せる。
    private func existingAlbum(named albumName: String, type albumType: AlbumType, orLinkedTo folderURL: URL) -> Album? {
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

    private func importLinkedFolderContents(
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

        for url in sortedContents where isDirectory(url) && !isExcludedFromImport(url) {
            await importLinkedFolderContents(
                folderURL: url,
                as: albumType,
                parentAlbumName: albumName,
                rootAlbumID: nil,
                rootBookmarkData: nil,
                existingPaths: currentExistingPaths,
                onItemProcessed: onItemProcessed
            )
        }
    }

    private func scanLinkedFolder(albumID: UUID, onItemProcessed: @MainActor @escaping () -> Void = {}) async {
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

    private func scheduleLinkedFolderScan(albumID: UUID, delayNanoseconds: UInt64 = 1_500_000_000) {
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
    private func startInitialLinkedFolderScan() {
        initialLinkedFolderScanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
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

        for album in linkedAlbums {
            linkedFolderScanStatus.currentFolderName = album.name
            linkedFolderScanStatus.processedItemsInCurrentFolder = 0
            await scanLinkedFolder(albumID: album.id) { [weak self] in
                self?.linkedFolderScanStatus.processedItemsInCurrentFolder += 1
            }
            linkedFolderScanStatus.processedCount += 1
        }

        let imported = max(0, videos.count - beforeCount)
        linkedFolderScanStatus.isScanning = false
        linkedFolderScanStatus.currentFolderName = nil
        linkedFolderScanStatus.processedItemsInCurrentFolder = 0
        linkedFolderScanStatus.statusMessage = imported > 0
            ? "\(linkedAlbums.count)件のフォルダを更新し、\(imported)件の新しいメディアを取り込みました。"
            : "\(linkedAlbums.count)件のフォルダを更新しました（新規メディアはありません）。"
    }

    /// 予約済みの単発スキャン（起動時の初回スキャン・フォルダ紐づけ直後などに走るもの）を取り消す。アプリ終了時に呼ぶ。
    private func cancelPendingLinkedFolderScans() {
        initialLinkedFolderScanTask?.cancel()
        initialLinkedFolderScanTask = nil
        linkedFolderScanTasks.values.forEach { $0.cancel() }
        linkedFolderScanTasks.removeAll()
    }

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

    private func importFolderContents(folderURL: URL, as albumType: AlbumType, parentAlbumName: String?, onItemProcessed: @MainActor @escaping () -> Void) async {
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

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// フォルダ再帰インポート時に無視するディレクトリ名。
    /// Python の venv や node_modules 等は写真フォルダの隣に置かれがちで、
    /// 中には各パッケージのテスト用画像が大量かつ深く（8階層超）ネストされている。
    /// これをそのまま再帰すると、数百件の無関係なネストされたアルバムが自動生成され、
    /// サイドバーのフォルダツリー描画がSwiftUIのレイアウト再帰上限を超えてクラッシュする
    /// （フォルダ紐づけ候補の自動リンクで実際に発生した障害）。
    private static let importExcludedDirectoryNames: Set<String> = [
        "venv", ".venv", "env", ".env",
        "node_modules", "site-packages",
        "__pycache__", ".git", ".svn", ".hg",
        "dist", "build", "Pods", "DerivedData"
    ]

    private func isExcludedFromImport(_ url: URL) -> Bool {
        Self.importExcludedDirectoryNames.contains(url.lastPathComponent)
    }

    private func isSupportedMedia(_ url: URL, for albumType: AlbumType) -> Bool {
        switch albumType {
        case .photo:
            return isSupportedPhoto(url)
        case .video:
            return isSupportedVideo(url)
        case .mixed:
            return isSupportedPhoto(url) || isSupportedVideo(url)
        }
    }

    private func isSupportedPhoto(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        let fallbackExtensions = Set(["jpg", "jpeg", "png", "heic", "webp", "gif", "tiff"])
        return UTType(filenameExtension: fileExtension)?.conforms(to: .image) == true || fallbackExtensions.contains(fileExtension)
    }

    private func isSupportedVideo(_ url: URL) -> Bool {
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
    private func importMediaBatch(
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
            if !photoIDs.isEmpty, let idx = albums.firstIndex(where: { $0.name == VideoDataManager.allPhotosAlbumName }) {
                albums[idx].videoIDs.append(contentsOf: photoIDs)
            }
            if !videoIDs.isEmpty, let idx = albums.firstIndex(where: { $0.name == VideoDataManager.allVideosAlbumName }) {
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
                    await VideoDataManager.buildImportedItem(from: url, targetAlbumType: targetAlbumType, downloadStorageURL: downloadStorageURL, copyIntoManagedStorage: managedCopyURL)
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
        guard let newItem = await VideoDataManager.buildImportedItem(from: sourceURL, targetAlbumType: targetAlbum.type, downloadStorageURL: downloadStorageURL, customFilename: customFilename, copyIntoManagedStorage: (customFilename == nil && importCopiesFiles) ? videoStorageURL : nil) else {
            return false
        }

        videos.append(newItem)
        if let index = albums.firstIndex(where: { $0.id == albumID }) { albums[index].videoIDs.append(newItem.id) }
        if newItem.mediaType == .photo {
            if let idx = albums.firstIndex(where: { $0.name == VideoDataManager.allPhotosAlbumName }) { albums[idx].videoIDs.append(newItem.id) }
        } else {
            if let idx = albums.firstIndex(where: { $0.name == VideoDataManager.allVideosAlbumName }) { albums[idx].videoIDs.append(newItem.id) }
        }

        if saveImmediately { saveData() }
        return true
    }

    /// ファイルのコピー・メタデータ抽出だけを行い、videos/albums には一切触れない。MainActor に一切
    /// 依存しない（nonisolated）ため、一括インポート側は複数ファイルを本当に並行して処理できる。
    nonisolated private static func buildImportedItem(from sourceURL: URL, targetAlbumType: AlbumType, downloadStorageURL: URL, customFilename: String? = nil, copyIntoManagedStorage: URL? = nil) async -> VideoItem? {
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
    nonisolated private static func isPath(_ path: String, inside directory: URL) -> Bool {
        let dirPath = directory.path
        return path == dirPath || path.hasPrefix(dirPath.hasSuffix("/") ? dirPath : dirPath + "/")
    }

    private func isAppManagedPath(_ path: String) -> Bool {
        Self.isPath(path, inside: downloadStorageURL) || Self.isPath(path, inside: videoStorageURL)
    }

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
        if name == VideoDataManager.allVideosAlbumName || name == VideoDataManager.allPhotosAlbumName {
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
    @discardableResult
    func createAlbum(name: String, type: AlbumType) -> UUID? { guard name != VideoDataManager.allVideosAlbumName && name != VideoDataManager.allPhotosAlbumName else { return nil }; let id = UUID(); albums.append(Album(id: id, name: name, videoIDs: [], type: type)); saveData(); return id }

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
        let protectedNames: Set<String> = [VideoDataManager.allVideosAlbumName, VideoDataManager.allPhotosAlbumName]
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
    }

    func deleteAlbums(albumIDs: [UUID], contentDisposal: AlbumContentDisposal) {
        let targetIDs = Set(albumIDs)
        let protectedNames = Set([VideoDataManager.allVideosAlbumName, VideoDataManager.allPhotosAlbumName])
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
        }

        let deletableIDs = Set(albumsToDelete.map { $0.id })
        albums.removeAll { deletableIDs.contains($0.id) }
        saveData()
        reconcileLinkedFoldersFromExistingPaths()
    }
    func moveVideos(videoIDs: [UUID], from sourceAlbumID: UUID, to targetAlbumID: UUID) { guard albums.contains(where: { $0.id == targetAlbumID }) else { return }; if let sourceIndex = albums.firstIndex(where: { $0.id == sourceAlbumID }), albums[sourceIndex].name != VideoDataManager.allVideosAlbumName, albums[sourceIndex].name != VideoDataManager.allPhotosAlbumName { albums[sourceIndex].videoIDs.removeAll { videoIDs.contains($0) } }; if let targetIndex = albums.firstIndex(where: { $0.id == targetAlbumID }) { let existingIDs = Set(albums[targetIndex].videoIDs); let newIDs = videoIDs.filter { !existingIDs.contains($0) }; albums[targetIndex].videoIDs.append(contentsOf: newIDs) }; saveData() }

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
    private func purgeExpiredTrash() {
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
    private func runAutomaticMissingFileCleanup() {
        let videosSnapshot = videos
        let videoStorageURL = self.videoStorageURL
        let downloadStorageURL = self.downloadStorageURL
        Task.detached(priority: .utility) {
            let missingIDs = videosSnapshot.filter {
                VideoDataManager.resolveFileURL(for: $0, videoStorageURL: videoStorageURL, downloadStorageURL: downloadStorageURL) == nil
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
    nonisolated private static let saveQueue = DispatchQueue(label: "AllServerForMac.librarySave", qos: .utility)
    /// saveQueue 上でのみ読み書きする、最後に書き込んだ世代番号。
    nonisolated(unsafe) private static var lastWrittenSaveGeneration = 0
    /// メインアクター上で発番する保存世代。呼び出し順＝新しさの順になる。
    private var saveGeneration = 0

    private func saveData() {
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
            VideoDataManager.saveQueue.async {
                // より新しい世代が既に書かれていたら、この古いスナップショットは破棄する
                guard generation > VideoDataManager.lastWrittenSaveGeneration else { return }
                VideoDataManager.lastWrittenSaveGeneration = generation
                VideoDataManager.writeContainer(container, to: url)
            }
        }
    }

    nonisolated private static func writeContainer(_ container: DataContainer, to url: URL) {
        guard let data = try? JSONEncoder().encode(container) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 保留中の非同期保存があれば取り消し、現在の状態を同期的に書き込む（アプリ終了時用）
    private func flushPendingSave() {
        guard !isSecondaryInstance else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        saveGeneration += 1
        let generation = saveGeneration
        let container = DataContainer(videos: videos, albums: albums, duplicateCheckStates: duplicateCheckStates, schemaVersion: Self.librarySchemaVersion)
        let url = dataFileURL
        // 同期実行: キューに残っている古い書き込みを先に流し切ったうえで、
        // 最新世代として書き込み、以降に紛れ込む古い世代の上書きを世代番号で防ぐ。
        VideoDataManager.saveQueue.sync {
            guard generation > VideoDataManager.lastWrittenSaveGeneration else { return }
            VideoDataManager.lastWrittenSaveGeneration = generation
            VideoDataManager.writeContainer(container, to: url)
        }
    }
    private var backupFileURL: URL { appRootURL.appendingPathComponent("library.backup.json") }

    private func loadData() {
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
    private var backupGenerationURLs: [URL] {
        [
            backupFileURL,
            appRootURL.appendingPathComponent("library.backup.2.json"),
            appRootURL.appendingPathComponent("library.backup.3.json"),
        ]
    }

    private func applyLoadedContainer(_ container: DataContainer) {
        videos = container.videos
        albums = container.albums
        duplicateCheckStates = container.duplicateCheckStates ?? [:]
        setupInitialAlbums()
        pruneDuplicateCheckStates()
    }
    private func setupInitialAlbums() { updateOrCreateSystemAlbum(name: VideoDataManager.allVideosAlbumName, type: .video, ids: Set(videos.filter { $0.mediaType == .video }.map { $0.id })); updateOrCreateSystemAlbum(name: VideoDataManager.allPhotosAlbumName, type: .photo, ids: Set(videos.filter { $0.mediaType == .photo }.map { $0.id })) }
    private func pruneDuplicateCheckStates() { let albumIDs = Set(albums.map { $0.id }); duplicateCheckStates = duplicateCheckStates.filter { albumIDs.contains($0.key) } }
    private func updateOrCreateSystemAlbum(name: String, type: AlbumType, ids: Set<UUID>) { if let index = albums.firstIndex(where: { $0.name == name }) { albums[index].videoIDs = Array(ids); albums[index].type = type } else { albums.insert(Album(id: UUID(), name: name, videoIDs: Array(ids), type: type), at: 0) } }
    nonisolated private static func computeFileHash(for url: URL) throws -> String {
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
