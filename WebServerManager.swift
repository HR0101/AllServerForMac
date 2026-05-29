import Foundation
import Swifter
import AVFoundation
import AppKit
import Darwin
import Combine


class WebServerManager: NSObject, ObservableObject, NetServiceDelegate {
    private let server = HttpServer()
    private var netService: NetService?
    
    private weak var dataManager: VideoDataManager?
    
    @Published var statusMessage: String = "停止中"
    var isRunning: Bool { serverStartTime != nil }
    
    @Published var serverStartTime: Date?
    @Published var uptimeString: String = "00:00:00"
    private var timerCancellable: AnyCancellable?
    
    @Published var autoStopEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoStopEnabled, forKey: "autoStopEnabled")
        }
    }
    @Published var autoStopIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(autoStopIntervalMinutes, forKey: "autoStopIntervalMinutes")
        }
    }

    @Published var scheduleEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(scheduleEnabled, forKey: "scheduleEnabled")
            if !scheduleEnabled { removeSchedule() }
        }
    }
    @Published var scheduleStartTime: Date {
        didSet { UserDefaults.standard.set(scheduleStartTime, forKey: "scheduleStartTime") }
    }
    @Published var scheduleStopTime: Date {
        didSet { UserDefaults.standard.set(scheduleStopTime, forKey: "scheduleStopTime") }
    }
    @Published var scheduleStatusMessage: String = ""


    @Published var targetPort: Int {
        didSet {
            UserDefaults.standard.set(targetPort, forKey: "serverPort")
        }
    }

    @Published var authEnabled: Bool = true {
        didSet {
            authEnabledCache = authEnabled
            UserDefaults.standard.set(authEnabled, forKey: "authEnabled")
        }
    }
    @Published var authPIN: String = "" {
        didSet {
            authPINCache = authPIN
            UserDefaults.standard.set(authPIN, forKey: "authPIN")
        }
    }
    // バックグラウンドスレッドから安全に読むためのスナップショット
    private var authEnabledCache = true
    private var authPINCache = ""

    @Published var accessLogs: [AccessLogEntry] = []
    private let maxAccessLogs = 200

    init(dataManager: VideoDataManager) {
        self.dataManager = dataManager

        let savedPort = UserDefaults.standard.integer(forKey: "serverPort")
        self.targetPort = savedPort == 0 ? 8080 : savedPort

        self.autoStopEnabled = UserDefaults.standard.bool(forKey: "autoStopEnabled")
        let savedInterval = UserDefaults.standard.integer(forKey: "autoStopIntervalMinutes")
        self.autoStopIntervalMinutes = savedInterval == 0 ? 60 : savedInterval

        self.scheduleEnabled = UserDefaults.standard.bool(forKey: "scheduleEnabled")
        let cal = Calendar.current
        self.scheduleStartTime = (UserDefaults.standard.object(forKey: "scheduleStartTime") as? Date)
            ?? cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        self.scheduleStopTime = (UserDefaults.standard.object(forKey: "scheduleStopTime") as? Date)
            ?? cal.date(bySettingHour: 23, minute: 0, second: 0, of: Date()) ?? Date()

        let authEnabledValue = UserDefaults.standard.object(forKey: "authEnabled") as? Bool ?? true
        self.authEnabled = authEnabledValue
        let savedPIN = UserDefaults.standard.string(forKey: "authPIN") ?? ""
        let pin = savedPIN.isEmpty ? String(format: "%06d", Int.random(in: 0...999999)) : savedPIN
        self.authPIN = pin
        // didSet は init 中に発火しないため、キャッシュと永続化を手動で行う
        self.authEnabledCache = authEnabledValue
        self.authPINCache = pin
        UserDefaults.standard.set(pin, forKey: "authPIN")

        super.init()
        print("✅ [LIFECYCLE] WebServerManager initialized.")
        setupRoutes()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionOrAppTermination),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionOrAppTermination),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )

        if scheduleEnabled && isWithinScheduleWindow(Date()) {
            startServer()
        }
    }

    deinit {
        print("🛑 [LIFECYCLE] WebServerManager deinitialized.")
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Auth & Access Log
    func regeneratePIN() {
        authPIN = String(format: "%06d", Int.random(in: 0...999999))
    }

    private func extractPIN(from request: HttpRequest) -> String? {
        if let header = request.headers["x-auth-pin"], !header.isEmpty { return header }
        if let q = request.queryParams.first(where: { $0.0 == "pin" })?.1, !q.isEmpty { return q }
        if let cookie = request.headers["cookie"] {
            for part in cookie.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2, kv[0] == "pin", !kv[1].isEmpty { return kv[1] }
            }
        }
        return nil
    }

    private func isAuthorized(_ request: HttpRequest) -> Bool {
        if !authEnabledCache { return true }
        guard let pin = extractPIN(from: request) else { return false }
        return pin == authPINCache
    }

    private func logAccess(_ request: HttpRequest, authorized: Bool) {
        let ip = request.address ?? "unknown"
        let method = request.method
        let path = request.path
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.accessLogs.insert(AccessLogEntry(date: Date(), ip: ip, method: method, path: path, authorized: authorized), at: 0)
            if self.accessLogs.count > self.maxAccessLogs {
                self.accessLogs.removeLast(self.accessLogs.count - self.maxAccessLogs)
            }
        }
    }

    /// 認証チェック付きでルートハンドラを包む
    private func protected(_ handler: @escaping (HttpRequest) -> HttpResponse) -> (HttpRequest) -> HttpResponse {
        return { [weak self] request in
            guard let self = self else { return .internalServerError }
            let ok = self.isAuthorized(request)
            self.logAccess(request, authorized: ok)
            if !ok {
                let body = Array(#"{"error":"auth_required"}"#.utf8)
                return .raw(401, "Unauthorized",
                            ["Content-Type": "application/json", "WWW-Authenticate": "PIN"],
                            { try? $0.write(body) })
            }
            return handler(request)
        }
    }

    // MARK: - API Routes
    private func setupRoutes() {
        
        server["/"] = { [weak self] request -> HttpResponse in
            self?.logAccess(request, authorized: true)
            let html = #"""
            <!DOCTYPE html>
            <html lang="ja">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
                <title>Mac Video Server</title>
                <style>
                    :root {
                        --bg-color: #0D0D14;
                        --bg-secondary: #161622;
                        --accent-color: #D9BA73;
                        --text-primary: #FFFFFF;
                        --text-secondary: rgba(255,255,255,0.6);
                    }
                    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
                    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background-color: var(--bg-color); color: var(--text-primary); margin: 0; padding: 0; padding-bottom: 50px; }
                    
                    /* Header */
                    .header { display: flex; align-items: center; position: sticky; top: 0; background: rgba(13, 13, 20, 0.85); padding: 16px 20px; z-index: 10; backdrop-filter: blur(12px); border-bottom: 1px solid rgba(217, 186, 115, 0.2); }
                    .back-btn { display: none; background: rgba(255,255,255,0.1); color: var(--accent-color); border: none; padding: 8px 16px; border-radius: 20px; font-weight: bold; cursor: pointer; margin-right: 16px; transition: 0.2s; backdrop-filter: blur(4px); }
                    .back-btn:active { background: rgba(255,255,255,0.2); }
                    h1 { font-size: 20px; margin: 0; font-weight: bold; letter-spacing: 0.5px; color: var(--accent-color); }
                    
                    .container { padding: 20px; max-width: 1200px; margin: 0 auto; }
                    .section-title { font-size: 16px; font-weight: 600; color: var(--text-secondary); margin-top: 24px; margin-bottom: 12px; letter-spacing: 1px; border-bottom: 1px solid rgba(255,255,255,0.05); padding-bottom: 4px; }
                    
                    /* Grid & Cards */
                    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 16px; }
                    .card { background: var(--bg-secondary); border-radius: 20px; overflow: hidden; cursor: pointer; transition: transform 0.2s, box-shadow 0.2s; border: 1px solid rgba(255,255,255,0.05); position: relative; }
                    .card:active { transform: scale(0.96); }
                    .thumb-container { position: relative; width: 100%; padding-top: 100%; background: #000; overflow: hidden; }
                    .thumb { position: absolute; top: 0; left: 0; width: 100%; height: 100%; object-fit: cover; transition: opacity 0.3s; }
                    .icon-center { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); font-size: 48px; opacity: 0.8; }
                    .title { padding: 12px; font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-weight: 600; }
                    
                    /* Badges */
                    .badge-count { position: absolute; bottom: 10px; right: 10px; background: var(--accent-color); color: #000; padding: 2px 8px; border-radius: 8px; font-size: 12px; font-weight: bold; }
                    .badge-type { position: absolute; bottom: 8px; right: 8px; background: rgba(0,0,0,0.6); color: var(--accent-color); padding: 4px; border-radius: 6px; font-size: 12px; backdrop-filter: blur(4px); }
                    .badge-duration { position: absolute; bottom: 8px; left: 8px; background: rgba(0,0,0,0.6); color: #fff; padding: 2px 6px; border-radius: 4px; font-size: 11px; font-weight: bold; backdrop-filter: blur(4px); }
                    
                    /* Toolbar (Search & Sort) */
                    .toolbar { display: flex; gap: 12px; margin-bottom: 20px; }
                    .search-bar { flex: 1; background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); padding: 12px 16px; border-radius: 12px; color: white; font-size: 14px; outline: none; transition: 0.2s; }
                    .search-bar:focus { border-color: var(--accent-color); background: rgba(255,255,255,0.1); }
                    .sort-select { background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); color: white; padding: 0 16px; border-radius: 12px; font-size: 14px; outline: none; appearance: none; cursor: pointer; }
                    
                    /* Player Modal */
                    #player-modal { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: #000; z-index: 1000; flex-direction: column; }
                    .player-header { position: absolute; top: 0; left: 0; width: 100%; display: flex; justify-content: space-between; align-items: center; padding: 20px; z-index: 1001; background: linear-gradient(to bottom, rgba(0,0,0,0.8), transparent); pointer-events: none; }
                    .player-header > * { pointer-events: auto; }
                    .filename-display { color: white; font-size: 16px; font-weight: bold; text-shadow: 0 2px 4px rgba(0,0,0,0.8); max-width: 60%; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
                    
                    .controls-right { display: flex; gap: 16px; align-items: center; }
                    .quality-select { background: rgba(255,255,255,0.2); color: white; border: 1px solid rgba(255,255,255,0.4); padding: 6px 12px; border-radius: 16px; font-size: 13px; backdrop-filter: blur(8px); outline: none; cursor: pointer; }
                    .quality-select option { background: #222; color: #fff; }
                    .close-btn { width: 40px; height: 40px; background: rgba(255,255,255,0.2); border-radius: 20px; display: flex; justify-content: center; align-items: center; font-size: 24px; color: white; cursor: pointer; backdrop-filter: blur(8px); border: 1px solid rgba(255,255,255,0.1); }
                    
                    .media-container { flex: 1; display: flex; justify-content: center; align-items: center; position: relative; width: 100%; height: 100%; }
                    video, .photo-viewer { width: 100%; height: 100%; max-height: 100vh; object-fit: contain; outline: none; }
                    
                    /* Navigation Arrows */
                    .nav-btn { position: absolute; top: 50%; transform: translateY(-50%); width: 50px; height: 80px; background: rgba(0,0,0,0.3); color: white; display: flex; justify-content: center; align-items: center; font-size: 32px; cursor: pointer; border-radius: 8px; backdrop-filter: blur(4px); transition: 0.2s; z-index: 1001; opacity: 0; pointer-events: none; }
                    .media-container:hover .nav-btn { opacity: 1; pointer-events: auto; }
                    .nav-btn:hover { background: rgba(0,0,0,0.6); color: var(--accent-color); }
                    .nav-prev { left: 20px; }
                    .nav-next { right: 20px; }
                    
                    @media (max-width: 600px) {
                        .nav-btn { display: none; } /* モバイルでは矢印を非表示（タップ領域と被るため）*/
                    }

                    /* Login Overlay */
                    #login-modal { display: none; position: fixed; inset: 0; background: rgba(13,13,20,0.96); z-index: 2000; justify-content: center; align-items: center; backdrop-filter: blur(8px); }
                    .login-card { background: var(--bg-secondary); border: 1px solid rgba(217,186,115,0.25); border-radius: 24px; padding: 36px 28px; width: 90%; max-width: 320px; text-align: center; box-shadow: 0 20px 60px rgba(0,0,0,0.5); }
                    .login-card .lock { font-size: 44px; margin-bottom: 8px; }
                    .login-card h2 { color: var(--accent-color); margin: 8px 0 4px; font-size: 20px; }
                    .login-card p { color: var(--text-secondary); font-size: 13px; margin: 0 0 20px; }
                    .pin-input { width: 100%; background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.15); color: #fff; font-size: 24px; letter-spacing: 8px; text-align: center; padding: 14px; border-radius: 14px; outline: none; box-sizing: border-box; }
                    .pin-input:focus { border-color: var(--accent-color); }
                    .login-btn { margin-top: 16px; width: 100%; background: var(--accent-color); color: #000; font-weight: bold; font-size: 16px; padding: 14px; border: none; border-radius: 14px; cursor: pointer; }
                    .login-btn:active { opacity: 0.85; }
                    .login-error { color: #ff6b6b; font-size: 13px; margin-top: 12px; min-height: 18px; }
                </style>
            </head>
            <body>
                <div class="header">
                    <button class="back-btn" id="back-btn" onclick="showAlbumsView()">← 戻る</button>
                    <h1 id="page-title">Mac Video Server</h1>
                </div>

                <div class="container" id="albums-view">
                    <div id="library-section"></div>
                    <div id="video-albums-section"></div>
                    <div id="photo-albums-section"></div>
                </div>

                <div class="container" id="videos-view" style="display: none;">
                    <div class="toolbar">
                        <input type="text" class="search-bar" id="search-input" placeholder="ファイル名で検索..." oninput="renderVideos()">
                        <select class="sort-select" id="sort-select" onchange="renderVideos()">
                            <option value="importDesc">追加日が新しい順</option>
                            <option value="importAsc">追加日が古い順</option>
                            <option value="creationDesc">撮影日が新しい順</option>
                            <option value="creationAsc">撮影日が古い順</option>
                            <option value="durationDesc">長さが長い順</option>
                            <option value="durationAsc">長さが短い順</option>
                        </select>
                    </div>
                    <div class="grid" id="videos-grid"></div>
                </div>

                <div id="login-modal">
                    <div class="login-card">
                        <div class="lock">🔒</div>
                        <h2>PIN認証</h2>
                        <p>このサーバーは保護されています。<br>Macの画面に表示されているPINを入力してください。</p>
                        <input type="password" inputmode="numeric" class="pin-input" id="pin-input" placeholder="••••••" maxlength="12" onkeydown="if(event.key==='Enter') submitPIN()">
                        <button class="login-btn" onclick="submitPIN()">ロック解除</button>
                        <div class="login-error" id="login-error"></div>
                    </div>
                </div>

                <div id="player-modal">
                    <div class="player-header">
                        <div class="filename-display" id="player-filename"></div>
                        <div class="controls-right">
                            <select class="quality-select" id="quality-select" onchange="changeQuality(this.value)">
                                <option value="original">Original</option>
                                <option value="1080p" selected>1080p (軽量)</option>
                                <option value="540p">540p (節約)</option>
                            </select>
                            <div class="close-btn" onclick="closePlayer()">✕</div>
                        </div>
                    </div>
                    <div class="media-container" id="media-container">
                        <div class="nav-btn nav-prev" onclick="prevMedia()">&#10094;</div>
                        <div class="nav-btn nav-next" onclick="nextMedia()">&#10095;</div>
                    </div>
                </div>

                <script>
                    let currentRawVideos = [];
                    let currentFilteredVideos = [];
                    let currentAlbumName = "";
                    let currentMediaIndex = 0;
                    let selectedQuality = "1080p";

                    function showLogin() {
                        document.getElementById('login-modal').style.display = 'flex';
                        setTimeout(() => document.getElementById('pin-input').focus(), 100);
                    }
                    function submitPIN() {
                        const val = document.getElementById('pin-input').value.trim();
                        if (!val) return;
                        // Cookieに保存することで、画像/動画タグのリクエストにも自動付与される
                        document.cookie = 'pin=' + encodeURIComponent(val) + ';path=/;max-age=31536000;samesite=lax';
                        document.getElementById('login-error').innerText = '';
                        loadAlbums();
                    }

                    function formatDuration(seconds) {
                        if(!seconds) return "0:00";
                        const m = Math.floor(seconds / 60);
                        const s = Math.floor(seconds % 60);
                        return m + ":" + (s < 10 ? "0" : "") + s;
                    }

                    function showAlbumsView() {
                        document.getElementById('albums-view').style.display = 'block';
                        document.getElementById('videos-view').style.display = 'none';
                        document.getElementById('back-btn').style.display = 'none';
                        document.getElementById('page-title').innerText = 'Mac Video Server';
                        loadAlbums();
                    }

                    async function loadAlbums() {
                        const libSec = document.getElementById('library-section');
                        const vidSec = document.getElementById('video-albums-section');
                        const phoSec = document.getElementById('photo-albums-section');
                        
                        libSec.innerHTML = '<p style="color:#888;">読み込み中...</p>';
                        vidSec.innerHTML = ''; phoSec.innerHTML = '';
                        
                        try {
                            const res = await fetch('/albums');
                            if (res.status === 401) {
                                libSec.innerHTML = '';
                                document.getElementById('login-error').innerText = document.cookie.indexOf('pin=') >= 0 ? 'PINが正しくありません。' : '';
                                showLogin();
                                return;
                            }
                            document.getElementById('login-modal').style.display = 'none';
                            const albums = await res.json();
                            
                            let libHtml = '<div class="section-title">ライブラリ</div><div class="grid">';
                            let vidHtml = '<div class="section-title">動画アルバム</div><div class="grid">';
                            let phoHtml = '<div class="section-title">写真アルバム</div><div class="grid">';
                            
                            let hasVid = false, hasPho = false;

                            albums.forEach(album => {
                                const cardHtml = `
                                    <div class="card" onclick="loadVideos(${JSON.stringify(album.id)}, ${JSON.stringify(album.name)})">
                                        <div class="thumb-container">
                                            <div class="icon-center">${album.type === 'photo' ? '🖼️' : '📁'}</div>
                                            <div class="badge-count">${album.videoCount}</div>
                                        </div>
                                        <div class="title" style="color: ${album.type === 'photo' ? '#ff9f0a' : '#fff'}">${album.name}</div>
                                    </div>
                                `;
                                if (album.name === "ALL VIDEOS" || album.name === "ALL PHOTOS" || album.type === "mixed") {
                                    libHtml += cardHtml;
                                } else if (album.type === "photo") {
                                    phoHtml += cardHtml;
                                    hasPho = true;
                                } else {
                                    vidHtml += cardHtml;
                                    hasVid = true;
                                }
                            });
                            
                            libSec.innerHTML = libHtml + '</div>';
                            vidSec.innerHTML = hasVid ? vidHtml + '</div>' : '';
                            phoSec.innerHTML = hasPho ? phoHtml + '</div>' : '';
                            
                        } catch (e) {
                            libSec.innerHTML = '<p style="color:red;">エラーが発生しました</p>';
                        }
                    }

                    async function loadVideos(albumId, albumName) {
                        currentAlbumName = albumName;
                        document.getElementById('albums-view').style.display = 'none';
                        document.getElementById('videos-view').style.display = 'block';
                        document.getElementById('back-btn').style.display = 'block';
                        document.getElementById('page-title').innerText = albumName;
                        document.getElementById('search-input').value = "";
                        
                        const grid = document.getElementById('videos-grid');
                        grid.innerHTML = '<p style="grid-column: 1/-1; text-align:center; color:#888;">読み込み中...</p>';
                        
                        try {
                            const res = await fetch(`/albums/${albumId}/videos`);
                            if (res.status === 401) { showLogin(); return; }
                            currentRawVideos = await res.json();
                            renderVideos();
                        } catch (e) {
                            grid.innerHTML = '<p style="grid-column: 1/-1; text-align:center; color:red;">取得エラー</p>';
                        }
                    }

                    function renderVideos() {
                        const searchText = document.getElementById('search-input').value.toLowerCase();
                        const sortOrder = document.getElementById('sort-select').value;
                        const grid = document.getElementById('videos-grid');
                        
                        currentFilteredVideos = currentRawVideos.filter(v => v.filename.toLowerCase().includes(searchText));

                        currentFilteredVideos.sort((a, b) => {
                            if (sortOrder === 'durationDesc') {
                                return (b.duration || 0) - (a.duration || 0);
                            } else if (sortOrder === 'durationAsc') {
                                return (a.duration || 0) - (b.duration || 0);
                            } else if (sortOrder === 'importDesc') {
                                return new Date(b.importDate) - new Date(a.importDate);
                            } else if (sortOrder === 'importAsc') {
                                return new Date(a.importDate) - new Date(b.importDate);
                            } else if (sortOrder === 'creationDesc') {
                                const dateA = new Date(a.creationDate || a.importDate);
                                const dateB = new Date(b.creationDate || b.importDate);
                                return dateB - dateA;
                            } else if (sortOrder === 'creationAsc') {
                                const dateA = new Date(a.creationDate || a.importDate);
                                const dateB = new Date(b.creationDate || b.importDate);
                                return dateA - dateB;
                            }
                            return 0;
                        });
                        
                        if (currentFilteredVideos.length === 0) {
                            grid.innerHTML = '<p style="grid-column: 1/-1; text-align:center; color:#888;">メディアが見つかりません</p>';
                            return;
                        }
                        
                        let html = '';
                        currentFilteredVideos.forEach((video, index) => {
                            const isPhoto = video.mediaType === 'photo';
                            const typeIcon = isPhoto ? '📷' : '🎥';
                            const durBadge = !isPhoto && video.duration > 0 ? `<div class="badge-duration">${formatDuration(video.duration)}</div>` : '';
                            
                            html += `
                                <div class="card" onclick="openMedia(${index})">
                                    <div class="thumb-container">
                                        <img class="thumb" src="/thumbnail/${video.id}" loading="lazy" onerror="this.src='data:image/svg+xml;utf8,<svg xmlns=\\'http://www.w3.org/2000/svg\\'><rect width=\\'100%\\' height=\\'100%\\' fill=\\'%23111\\'/></svg>'">
                                        ${durBadge}
                                        <div class="badge-type">${typeIcon}</div>
                                    </div>
                                    <div class="title">${video.filename}</div>
                                </div>
                            `;
                        });
                        grid.innerHTML = html;
                    }

                    function openMedia(index) {
                        if (index < 0 || index >= currentFilteredVideos.length) return;
                        currentMediaIndex = index;
                        const media = currentFilteredVideos[index];
                        const isPhoto = media.mediaType === 'photo';
                        
                        document.getElementById('player-filename').innerText = media.filename;
                        const container = document.getElementById('media-container');
                        
                        const oldMedia = document.getElementById('main-media');
                        if (oldMedia) oldMedia.remove();
                        
                        if (isPhoto) {
                            document.getElementById('quality-select').style.display = 'none';
                            const img = document.createElement('img');
                            img.id = 'main-media';
                            img.className = 'photo-viewer';
                            img.src = `/video/${media.id}`;
                            container.insertBefore(img, container.children[1]);
                        } else {
                            document.getElementById('quality-select').style.display = 'block';
                            const video = document.createElement('video');
                            video.id = 'main-media';
                            video.controls = true;
                            video.playsInline = true;
                            video.src = `/video/${media.id}?q=${selectedQuality}`;
                            
                            const savedTime = localStorage.getItem('resume_' + media.id);
                            if (savedTime) {
                                video.currentTime = parseFloat(savedTime);
                            }

                            video.addEventListener('timeupdate', () => {
                                if(video.currentTime > 2) {
                                    localStorage.setItem('resume_' + media.id, video.currentTime);
                                }
                            });
                            
                            container.insertBefore(video, container.children[1]);
                            video.play().catch(e => console.log("自動再生がブロックされました"));
                        }
                        
                        document.getElementById('player-modal').style.display = 'flex';
                    }

                    function changeQuality(q) {
                        selectedQuality = q;
                        const media = currentFilteredVideos[currentMediaIndex];
                        if (media && media.mediaType !== 'photo') {
                            const video = document.getElementById('main-media');
                            const currentTime = video.currentTime;
                            const isPaused = video.paused;
                            
                            video.src = `/video/${media.id}?q=${q}`;
                            video.currentTime = currentTime;
                            if (!isPaused) video.play();
                        }
                    }

                    function closePlayer() {
                        const media = document.getElementById('main-media');
                        if (media && media.tagName === 'VIDEO') {
                            media.pause();
                            media.src = '';
                        }
                        document.getElementById('player-modal').style.display = 'none';
                    }

                    function prevMedia() { openMedia(currentMediaIndex - 1); }
                    function nextMedia() { openMedia(currentMediaIndex + 1); }

                    document.addEventListener('keydown', (e) => {
                        if (document.getElementById('player-modal').style.display === 'flex') {
                            const media = document.getElementById('main-media');
                            const isVideo = media && media.tagName === 'VIDEO';

                            if (document.activeElement.tagName === 'INPUT') return;

                            if (e.key === 'Escape') {
                                closePlayer();
                                return;
                            }

                            if (isVideo) {
                                switch (e.key.toLowerCase()) {
                                    case ' ': // スペースキー
                                    case 'k':
                                        e.preventDefault();
                                        if (media.paused) media.play();
                                        else media.pause();
                                        break;
                                    case 'j':
                                        e.preventDefault();
                                        media.currentTime = Math.max(0, media.currentTime - 5);
                                        break;
                                    case 'l':
                                        e.preventDefault();
                                        media.currentTime = Math.min(media.duration, media.currentTime + 5);
                                        break;
                                    case 'arrowleft':
                                        e.preventDefault();
                                        if (e.shiftKey) {
                                            prevMedia();
                                        } else {
                                            media.currentTime = Math.max(0, media.currentTime - 5);
                                        }
                                        break;
                                    case 'arrowright':
                                        e.preventDefault();
                                        if (e.shiftKey) {
                                            nextMedia();
                                        } else {
                                            media.currentTime = Math.min(media.duration, media.currentTime + 5);
                                        }
                                        break;
                                    case 'arrowup':
                                        e.preventDefault();
                                        media.volume = Math.min(1.0, media.volume + 0.1);
                                        break;
                                    case 'arrowdown':
                                        e.preventDefault();
                                        media.volume = Math.max(0.0, media.volume - 0.1);
                                        break;
                                    case 'm':
                                        e.preventDefault();
                                        media.muted = !media.muted;
                                        break;
                                    case 'f':
                                        e.preventDefault();
                                        if (!document.fullscreenElement) {
                                            if (media.requestFullscreen) {
                                                media.requestFullscreen();
                                            } else if (media.webkitRequestFullscreen) { // Safari対応
                                                media.webkitRequestFullscreen();
                                            }
                                        } else {
                                            if (document.exitFullscreen) {
                                                document.exitFullscreen();
                                            } else if (document.webkitExitFullscreen) { // Safari対応
                                                document.webkitExitFullscreen();
                                            }
                                        }
                                        break;
                                }
                            } else {
                                if (e.key === 'ArrowLeft') prevMedia();
                                if (e.key === 'ArrowRight') nextMedia();
                            }
                        }
                    });

                    showAlbumsView();
                </script>
            </body>
            </html>
            """#
            return .ok(.html(html))
        }
        
        server["/albums"] = protected { [weak self] _ -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            var albumInfos: [RemoteAlbumInfo] = []
            DispatchQueue.main.sync {
                albumInfos = dataManager.albums.map {
                    RemoteAlbumInfo(id: $0.id.uuidString, name: $0.name, videoCount: $0.videoIDs.count, type: $0.type.rawValue)
                }
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                let jsonData = try encoder.encode(albumInfos)
                return .ok(.data(jsonData, contentType: "application/json"))
            } catch { return .internalServerError }
        }
        
        server["/albums/:id/videos"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            guard let albumIDString = request.params[":id"], let albumID = UUID(uuidString: albumIDString) else {
                return .badRequest(.text("Invalid album ID"))
            }
            var videoInfos: [RemoteVideoInfo] = []
            var found = false
            DispatchQueue.main.sync {
                if let album = dataManager.albums.first(where: { $0.id == albumID }) {
                    found = true
                    let videoItems = dataManager.videos.filter { album.videoIDs.contains($0.id) }
                    videoInfos = videoItems.map {
                        RemoteVideoInfo(id: $0.id.uuidString,
                                        filename: $0.originalFilename,
                                        duration: $0.duration,
                                        importDate: $0.importDate,
                                        creationDate: $0.creationDate,
                                        mediaType: $0.mediaType.rawValue)
                    }
                }
            }
            guard found else { return .notFound }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let jsonData = try encoder.encode(videoInfos)
                return .ok(.data(jsonData, contentType: "application/json"))
            } catch { return .internalServerError }
        }
        
        server["/server/status"] = protected { [weak self] _ -> HttpResponse in
            var uptime = 0
            DispatchQueue.main.sync {
                if let start = self?.serverStartTime {
                    uptime = Int(Date().timeIntervalSince(start))
                }
            }
            struct StatusData: Codable { let uptime: Int }
            if let data = try? JSONEncoder().encode(StatusData(uptime: uptime)) {
                return .ok(.data(data, contentType: "application/json"))
            }
            return .internalServerError
        }

        server.post["/server/shutdown"] = protected { [weak self] _ -> HttpResponse in
            DispatchQueue.main.async {
                self?.stopServerInternal()
                NSApplication.shared.terminate(nil)
            }
            return .ok(.text("Shutdown initiated"))
        }
        
        server.post["/albums/create"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            struct CreateReq: Codable { let name: String; let type: String }
            do {
                let req = try JSONDecoder().decode(CreateReq.self, from: Data(request.body))
                let albumType = AlbumType(rawValue: req.type) ?? .video
                DispatchQueue.main.async { dataManager.createAlbum(name: req.name, type: albumType) }
                return .ok(.text("Created"))
            } catch { return .badRequest(.text("Invalid request")) }
        }

        server.delete["/albums/:id"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let idStr = request.params[":id"], let id = UUID(uuidString: idStr) else { return .badRequest(.text("Invalid ID")) }
            DispatchQueue.main.async { dataManager.deleteAlbum(albumID: id) }
            return .ok(.text("Deleted"))
        }

        server.post["/move"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            struct MoveRequest: Codable { let videoIds: [String]; let sourceAlbumId: String; let targetAlbumId: String }
            do {
                let moveRequest = try JSONDecoder().decode(MoveRequest.self, from: Data(request.body))
                let videoUUIDs = moveRequest.videoIds.compactMap { UUID(uuidString: $0) }
                guard let sourceUUID = UUID(uuidString: moveRequest.sourceAlbumId),
                      let targetUUID = UUID(uuidString: moveRequest.targetAlbumId) else { return .badRequest(.text("Invalid IDs")) }
                DispatchQueue.main.async { dataManager.moveVideos(videoIDs: videoUUIDs, from: sourceUUID, to: targetUUID) }
                return .ok(.text("Moved successfully"))
            } catch { return .badRequest(.text("Invalid request body")) }
        }

        server.post["/deleteVideos"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            struct DelRequest: Codable { let videoIds: [String]; let albumId: String }
            do {
                let req = try JSONDecoder().decode(DelRequest.self, from: Data(request.body))
                let videoUUIDs = req.videoIds.compactMap { UUID(uuidString: $0) }
                guard let albumUUID = UUID(uuidString: req.albumId) else { return .badRequest(.text("Invalid Album ID")) }
                DispatchQueue.main.async { dataManager.removeVideosFromAlbum(videoIDs: videoUUIDs, albumID: albumUUID) }
                return .ok(.text("Deleted successfully"))
            } catch { return .badRequest(.text("Invalid request body")) }
        }

        server.post["/upload"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            
            let encodedFilename = request.headers["x-filename"] ?? "uploaded_media"
            let filename = encodedFilename.removingPercentEncoding ?? encodedFilename
            let albumIdStr = request.headers["x-album-id"] ?? ""
            
            let tempDir = FileManager.default.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + filename)
            
            let data = Data(request.body)
            do {
                try data.write(to: tempURL)
                
                let targetAlbumID: UUID
                if let aid = UUID(uuidString: albumIdStr) {
                    targetAlbumID = aid
                } else {
                    guard let allVideos = dataManager.albums.first(where: { $0.name == VideoDataManager.allVideosAlbumName }) else {
                        return .internalServerError
                    }
                    targetAlbumID = allVideos.id
                }
                
                DispatchQueue.main.async {
                    Task {
                        await dataManager.importMedia(from: tempURL, to: targetAlbumID, customFilename: filename)
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                }
                return .ok(.text("Upload successful"))
            } catch {
                return .internalServerError
            }
        }

        server["/video/:id"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let videoIDString = request.params[":id"],
                  let videoID = UUID(uuidString: videoIDString) else { return .notFound }
            
            let quality = request.queryParams.first(where: { $0.0 == "q" })?.1 ?? "original"
            
            var videoURL: URL?
            DispatchQueue.main.sync {
                if let videoItem = dataManager.videos.first(where: { $0.id == videoID }) {
                    if quality == "1080p" {
                        let proxyURL = dataManager.proxyStorageURL.appendingPathComponent("\(videoIDString)_1080p.mp4")
                        if FileManager.default.fileExists(atPath: proxyURL.path) {
                            videoURL = proxyURL
                        }
                    } else if quality == "540p" {
                        let proxyURL = dataManager.proxyStorageURL.appendingPathComponent("\(videoIDString)_540p.mp4")
                        if FileManager.default.fileExists(atPath: proxyURL.path) {
                            videoURL = proxyURL
                        }
                    }
                    
                    if videoURL == nil {
                        videoURL = dataManager.fileURL(for: videoItem)
                    }
                }
            }
            guard let url = videoURL else { return .notFound }
            return self.serveFile(at: url, request: request)
        }

        server["/video/:id/prepare"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let idStr = request.params[":id"] else { return .notFound }
            let quality = request.queryParams.first(where: { $0.0 == "q" })?.1 ?? "1080p"
            var state = "generating"
            var progress = 0.0
            DispatchQueue.main.sync {
                if dataManager.isProxyReady(videoID: idStr, quality: quality) {
                    state = "ready"
                } else if let p = dataManager.proxyGenerationProgress(videoID: idStr, quality: quality) {
                    state = "generating"; progress = p
                } else {
                    dataManager.startOnDemandProxy(videoID: idStr, quality: quality)
                    state = "generating"; progress = 0
                }
            }
            struct PrepareResp: Codable { let state: String; let progress: Double }
            if let data = try? JSONEncoder().encode(PrepareResp(state: state, progress: progress)) {
                return .ok(.data(data, contentType: "application/json"))
            }
            return .internalServerError
        }

        server.delete["/video/:id/proxy"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager else { return .internalServerError }
            DispatchQueue.main.async { dataManager.deleteAllProxies() }
            return .ok(.text("Deleted"))
        }

        server["/thumbnail/:id"] = protected { [weak self] request -> HttpResponse in
            guard let self = self, let dataManager = self.dataManager,
                  let videoIDString = request.params[":id"],
                  let videoID = UUID(uuidString: videoIDString) else { return .notFound }
            
            let thumbnailURL = dataManager.thumbnailStorageURL.appendingPathComponent(videoIDString).appendingPathExtension("jpg")

            if let cachedData = try? Data(contentsOf: thumbnailURL) {
                return .ok(.data(cachedData, contentType: "image/jpeg"))
            }
            
            var targetItem: VideoItem?
            var videoFileUrl: URL?
            DispatchQueue.main.sync {
                if let item = dataManager.videos.first(where: { $0.id == videoID }) {
                    targetItem = item
                    videoFileUrl = dataManager.fileURL(for: item)
                }
            }
            guard let item = targetItem, let fileUrl = videoFileUrl else { return .notFound }
            
            let semaphore = DispatchSemaphore(value: 0)
            var generatedData: Data? = nil
            
            Task {
                if let data = await self.generateThumbnailData(for: fileUrl, type: item.mediaType, quality: .high) {
                    try? data.write(to: thumbnailURL)
                    generatedData = data
                }
                semaphore.signal()
            }
            
            let result = semaphore.wait(timeout: .now() + 5.0)
            
            if result == .success, let data = generatedData {
                return .ok(.data(data, contentType: "image/jpeg"))
            } else {
                let headers = ["Content-Type": "image/jpeg"]
                return .raw(202, "Accepted", headers, { writer in
                    try? writer.write(self.placeholderData)
                })
            }
        }
        
        print("✅ [SETUP] API routes configured.")
    }
    
    // MARK: - Server Control
    func startServer() {
        guard !server.operating else { return }
        
        let portToUse = in_port_t(targetPort)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.server.start(portToUse, forceIPv4: true)
                let actualPort = try self.server.port()
                DispatchQueue.main.async {
                    self.targetPort = Int(actualPort)
                    guard let computerName = Host.current().localizedName else {
                        self.statusMessage = "❌ [FATAL] Could not get computer name."; self.server.stop(); return
                    }
                    let userName = NSUserName()
                    let uniqueServiceName = "\(computerName) (\(userName))"
                    self.netService = NetService(domain: "local.", type: "_myvideoserver._tcp.", name: uniqueServiceName, port: Int32(actualPort))
                    self.netService?.delegate = self
                    self.netService?.publish()
                    
                    self.serverStartTime = Date()
                    self.startUptimeTimer()
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "❌ 起動失敗: ポート \(portToUse) は既に使用されている可能性があります。"
                }
            }
        }
    }

    private func startUptimeTimer() {
        self.timerCancellable?.cancel()
        self.timerCancellable = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self = self, let start = self.serverStartTime else { return }
            let diff = Int(Date().timeIntervalSince(start))

            if self.autoStopEnabled {
                let limitSeconds = self.autoStopIntervalMinutes * 60
                if diff >= limitSeconds {
                    self.stopServerInternal()
                    NSApplication.shared.terminate(nil)
                    return
                }
            }

            if self.scheduleEnabled {
                let now = Date()
                let cal = Calendar.current
                let stop = cal.dateComponents([.hour, .minute], from: self.scheduleStopTime)
                let cur = cal.dateComponents([.hour, .minute], from: now)
                if cur.hour == stop.hour && cur.minute == stop.minute {
                    self.stopServerInternal()
                    NSApplication.shared.terminate(nil)
                    return
                }
            }

            let h = diff / 3600
            let m = (diff % 3600) / 60
            let s = diff % 60
            self.uptimeString = String(format: "%02d:%02d:%02d", h, m, s)
        }
    }

    @objc func stopServer() { stopServerInternal() }

    private func stopServerInternal() {
        netService?.stop(); netService = nil
        server.stop()
        
        DispatchQueue.main.async {
            self.serverStartTime = nil
            self.timerCancellable?.cancel()
            self.uptimeString = "00:00:00"
            self.statusMessage = "🛑 サーバー停止"
        }
    }
    
    @objc private func handleSessionOrAppTermination() { stopServerInternal() }

    // MARK: - スケジュール起動/停止
    /// 現在時刻が起動時刻〜停止時刻の時間帯に入っているか（日をまたぐ設定にも対応）
    func isWithinScheduleWindow(_ now: Date) -> Bool {
        let cal = Calendar.current
        let s = cal.dateComponents([.hour, .minute], from: scheduleStartTime)
        let e = cal.dateComponents([.hour, .minute], from: scheduleStopTime)
        let n = cal.dateComponents([.hour, .minute], from: now)
        let startMin = (s.hour ?? 0) * 60 + (s.minute ?? 0)
        let stopMin  = (e.hour ?? 0) * 60 + (e.minute ?? 0)
        let nowMin   = (n.hour ?? 0) * 60 + (n.minute ?? 0)
        if startMin == stopMin { return false }
        if startMin < stopMin { return nowMin >= startMin && nowMin < stopMin }
        return nowMin >= startMin || nowMin < stopMin // 日をまたぐ場合
    }

    private var launchAgentLabel: String {
        (Bundle.main.bundleIdentifier ?? "com.allserverformac.app") + ".autostart"
    }
    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    /// 設定画面の「適用」ボタンから呼ぶ。LaunchAgent登録 + スリープ起床(pmset)を設定する
    func applySchedule() {
        installLaunchAgent()
        scheduleWake()
    }

    /// スケジュール解除（LaunchAgent削除 + pmset起床解除）
    func removeSchedule() {
        removeLaunchAgent()
        cancelWake()
        DispatchQueue.main.async { self.scheduleStatusMessage = "スケジュールを解除しました。" }
    }

    private func installLaunchAgent() {
        let cal = Calendar.current
        let comp = cal.dateComponents([.hour, .minute], from: scheduleStartTime)
        let hour = comp.hour ?? 9
        let minute = comp.minute ?? 0
        let appPath = Bundle.main.bundlePath

        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": ["/usr/bin/open", appPath],
            "StartCalendarInterval": ["Hour": hour, "Minute": minute],
            "RunAtLoad": false
        ]

        do {
            let dir = launchAgentURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: launchAgentURL)
            reloadLaunchAgent()
            let timeStr = String(format: "%02d:%02d", hour, minute)
            DispatchQueue.main.async {
                self.scheduleStatusMessage = "✅ 毎日 \(timeStr) に自動起動するよう登録しました。"
            }
        } catch {
            DispatchQueue.main.async {
                self.scheduleStatusMessage = "❌ 自動起動の登録に失敗: \(error.localizedDescription)"
            }
        }
    }

    private func reloadLaunchAgent() {
        let path = launchAgentURL.path
        _ = runProcess("/bin/launchctl", ["unload", path])   // 既存があれば解除（失敗は無視）
        _ = runProcess("/bin/launchctl", ["load", "-w", path])
    }

    private func removeLaunchAgent() {
        let path = launchAgentURL.path
        _ = runProcess("/bin/launchctl", ["unload", path])
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    /// スリープ中でも起動時刻にMacを起こす（pmset / 管理者権限が必要）。起動2分前に起床させる
    private func scheduleWake() {
        let cal = Calendar.current
        let comp = cal.dateComponents([.hour, .minute], from: scheduleStartTime)
        var total = (comp.hour ?? 9) * 60 + (comp.minute ?? 0) - 2
        if total < 0 { total += 24 * 60 }
        let timeStr = String(format: "%02d:%02d:00", total / 60, total % 60)
        runAdminShell("/usr/bin/pmset repeat wakeorpoweron MTWRFSU \(timeStr)") { ok in
            DispatchQueue.main.async {
                if !ok {
                    self.scheduleStatusMessage = "⚠️ 自動起動は登録しましたが、スリープ起床(pmset)の設定がキャンセル/失敗しました。"
                }
            }
        }
    }

    private func cancelWake() {
        runAdminShell("/usr/bin/pmset repeat cancel") { _ in }
    }

    /// 管理者権限でシェルコマンドを実行（GUIでパスワード入力を求める）
    private func runAdminShell(_ command: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
            let source = "do shell script \"\(escaped)\" with administrator privileges"
            var errorDict: NSDictionary?
            if let script = NSAppleScript(source: source) {
                script.executeAndReturnError(&errorDict)
                completion(errorDict == nil)
            } else {
                completion(false)
            }
        }
    }

    @discardableResult
    private func runProcess(_ launchPath: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    func netServiceDidPublish(_ sender: NetService) {
        let ipAddress = getIPAddress() ?? "N/A"
        self.statusMessage = "✅ 実行中: http://\(ipAddress):\(sender.port)"
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        self.statusMessage = "❌ Bonjour publish failed."
        self.server.stop()
    }
    
    // MARK: - Helpers
    private func serveFile(at url: URL, request: HttpRequest) -> HttpResponse {
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attr[.size] as? UInt64 else { return .internalServerError }
            let mime = MimeType.forPath(url.path)
            
            if let rangeHeader = request.headers["range"], let range = parseRangeHeader(rangeHeader, totalSize: size) {
                let (start, end) = range
                let length = end - start + 1
                let file = try FileHandle(forReadingFrom: url)
                defer { file.closeFile() }
                try file.seek(toOffset: start)
                let data = file.readData(ofLength: Int(length))
                return .raw(206, "Partial Content", [
                    "Content-Type": mime, "Content-Length": String(length),
                    "Content-Range": "bytes \(start)-\(end)/\(size)", "Accept-Ranges": "bytes"
                ], { writer in try? writer.write(data) })
            } else {
                let file = try FileHandle(forReadingFrom: url)
                return .raw(200, "OK", [
                    "Content-Type": mime,
                    "Content-Length": String(size),
                    "Accept-Ranges": "bytes"
                ], { writer in
                    defer { file.closeFile() }
                    let chunkSize = 512 * 1024
                    while true {
                        let chunk = file.readData(ofLength: chunkSize)
                        if chunk.isEmpty { break }
                        try? writer.write(chunk)
                    }
                })
            }
        } catch { return .internalServerError }
    }

    private func getIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    guard let name = interface.ifa_name, let cStringName = String(cString: name, encoding: .utf8) else { continue }
                    if cStringName.starts(with: "en") {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST)); getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        let ip = String(cString: hostname); if !ip.isEmpty { address = ip; break }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
    
    private func parseRangeHeader(_ header: String, totalSize: UInt64) -> (UInt64, UInt64)? {
        guard header.hasPrefix("bytes="), totalSize > 0 else { return nil }
        let components = header.dropFirst(6).split(separator: "-")
        guard let startStr = components.first, let start = UInt64(startStr) else { return nil }
        let end = (components.count > 1 && !components[1].isEmpty) ? min(UInt64(components[1]) ?? 0, totalSize - 1) : totalSize - 1
        return start <= end ? (start, end) : nil
    }

    private enum ThumbQuality { case high, low }
    
    private func generateThumbnailData(for url: URL, type: MediaType, quality: ThumbQuality) async -> Data? {
        let size: CGSize = quality == .high ? CGSize(width: 400, height: 400) : CGSize(width: 50, height: 50)
        let compression = quality == .high ? 0.8 : 0.1
        
        if type == .photo {
            return generateImageThumbnail(url: url, targetSize: size, compression: compression)
        } else {
            return await generateVideoThumbnail(url: url, targetSize: size, compression: compression)
        }
    }
    
    private func generateImageThumbnail(url: URL, targetSize: CGSize, compression: Double) -> Data? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(targetSize.width, targetSize.height),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: .zero)
        return cropAndResize(nsImage: nsImage, targetSize: targetSize, compression: compression)
    }

    private func generateVideoThumbnail(url: URL, targetSize: CGSize, compression: Double) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        
        var attempts: [Double] = [1.0, 3.0, 5.0, 10.0, 20.0, 30.0, 60.0]
        
        if duration < 5 {
            attempts.insert(0.0, at: 0)
        }
        
        let validAttempts = attempts.filter { $0 < duration }
        
        var bestCGImage: CGImage? = nil
        var fallbackImage: CGImage? = nil
        
        for seconds in validAttempts {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                if fallbackImage == nil { fallbackImage = cgImage }
                
                if !isImagePredominantlyBlack(image: cgImage) {
                    bestCGImage = cgImage
                    break
                }
            }
        }
        
        if let cgImage = bestCGImage ?? fallbackImage {
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            return cropAndResize(nsImage: nsImage, targetSize: targetSize, compression: compression)
        }
        return nil
    }
    
    private func cropAndResize(nsImage: NSImage, targetSize: CGSize, compression: Double) -> Data? {
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        let originalSize = nsImage.size
        let dim = min(originalSize.width, originalSize.height)
        let x = (originalSize.width - dim) / 2
        let y = (originalSize.height - dim) / 2
        let cropRect = CGRect(x: x, y: y, width: dim, height: dim)
        nsImage.draw(in: CGRect(origin: .zero, size: targetSize), from: cropRect, operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        
        guard let tiff = newImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }
    
    private var placeholderData: Data {
        let img = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!
        return img.tiffRepresentation!
    }
}

// MARK: - Shared Data Models & MimeType
struct RemoteAlbumInfo: Codable { let id: String; let name: String; let videoCount: Int; let type: String? }
struct AccessLogEntry: Identifiable, Hashable { let id = UUID(); let date: Date; let ip: String; let method: String; let path: String; let authorized: Bool }
struct RemoteVideoInfo: Codable { let id: String; let filename: String; let duration: TimeInterval; let importDate: Date; let creationDate: Date?; let mediaType: String? }
private struct MimeType {
    static func forPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4": return "video/mp4"; case "mov": return "video/quicktime"; case "m4v": return "video/x-m4v"
        case "jpg", "jpeg": return "image/jpeg"; case "png": return "image/png"; case "heic": return "image/heic"; case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}
