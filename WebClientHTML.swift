import Foundation

enum WebClientHTML {
    static let page = #"""
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

                    /* YouTube風 縦向きレイアウト（上部で再生・下で他の動画を探す） */
                    .up-next { display: none; }
                    @media (orientation: portrait) {
                        #player-modal.mode-video { background: var(--bg-color); }
                        #player-modal.mode-video .media-container {
                            flex: none; width: 100%; height: auto; aspect-ratio: 16 / 9; background: #000;
                        }
                        #player-modal.mode-video video { height: 100%; max-height: none; }
                        #player-modal.mode-video .up-next {
                            display: block; flex: 1 1 auto; min-height: 0; overflow-y: auto;
                            -webkit-overflow-scrolling: touch; background: var(--bg-color); padding-bottom: 60px;
                        }
                    }
                    .un-head { color: var(--text-secondary); font-size: 13px; font-weight: 600; padding: 12px 16px 6px; letter-spacing: 0.5px; }
                    .un-item { display: flex; gap: 10px; padding: 8px 12px; cursor: pointer; align-items: flex-start; }
                    .un-item:active { background: rgba(255,255,255,0.06); }
                    .un-item.current { background: rgba(217,186,115,0.14); }
                    .un-thumb-wrap { position: relative; width: 150px; flex: none; }
                    .un-thumb { width: 100%; aspect-ratio: 16 / 9; object-fit: cover; border-radius: 8px; background: #000; display: block; }
                    .un-dur { position: absolute; bottom: 5px; right: 5px; background: rgba(0,0,0,0.8); color: #fff; font-size: 11px; font-weight: bold; padding: 1px 5px; border-radius: 4px; }
                    .un-info { flex: 1; min-width: 0; padding-top: 2px; }
                    .un-title { color: #fff; font-size: 13px; line-height: 1.35; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
                    .un-meta { color: var(--text-secondary); font-size: 11px; margin-top: 4px; }
                    .un-item.current .un-title { color: var(--accent-color); }

                    /* Selection mode */
                    .tool-btn { background: rgba(255,255,255,0.05); border:1px solid rgba(255,255,255,0.1); color:#fff; padding:0 16px; border-radius:12px; font-size:14px; cursor:pointer; white-space:nowrap; }
                    .tool-btn.active { background: var(--accent-color); color:#000; font-weight:bold; }
                    .card .check { position:absolute; top:8px; left:8px; width:24px; height:24px; border-radius:50%; background:var(--accent-color); color:#000; display:none; justify-content:center; align-items:center; font-weight:bold; z-index:3; box-shadow:0 2px 6px rgba(0,0,0,0.4); }
                    .card.selected { outline:3px solid var(--accent-color); outline-offset:-3px; }
                    .card.selected .check { display:flex; }
                    .select-actions { display:none; gap:12px; align-items:center; margin-bottom:16px; flex-wrap:wrap; }
                    .select-actions .act { background: var(--accent-color); color:#000; border:none; padding:10px 16px; border-radius:12px; font-weight:bold; cursor:pointer; }
                    .select-actions .act.ghost { background: rgba(255,255,255,0.1); color:#fff; }
                    .select-actions .ss-clip { width:56px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.15); color:#fff; padding:8px; border-radius:8px; text-align:center; }

                    /* Multi & Slideshow modals */
                    #multi-modal, #slideshow-modal { display:none; position:fixed; inset:0; background:#000; z-index:1000; flex-direction:column; }
                    .multi-grid { flex:1; display:grid; gap:4px; padding:4px; padding-bottom:72px; min-height:0; }
                    .multi-grid.cols-1 { grid-template-columns: 1fr; }
                    .multi-grid.cols-2 { grid-template-columns: repeat(2, 1fr); }
                    .multi-grid.cols-3 { grid-template-columns: repeat(3, 1fr); }
                    .multi-video { width:100%; height:100%; object-fit:contain; background:#000; border-radius:6px; min-height:0; min-width:0; }
                    .multi-controls, .ss-controls { position:absolute; bottom:0; left:0; width:100%; display:flex; gap:10px; align-items:center; padding:12px 16px; background:linear-gradient(to top, rgba(0,0,0,0.85), transparent); z-index:1001; }
                    .multi-controls button, .ss-controls button { background:rgba(255,255,255,0.18); color:#fff; border:none; width:44px; height:44px; border-radius:22px; font-size:16px; cursor:pointer; flex:none; }
                    .multi-controls input[type=range] { flex:1; }
                    .ss-title { position:absolute; top:0; left:0; width:100%; padding:16px 20px; padding-right:60px; color:#fff; font-weight:bold; text-shadow:0 2px 4px #000; z-index:1001; background:linear-gradient(to bottom, rgba(0,0,0,0.8), transparent); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }

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
                        <button class="tool-btn" id="select-btn" onclick="toggleSelectMode()">選択</button>
                    </div>
                    <div class="select-actions" id="select-actions">
                        <span><b id="select-count">0</b> 本選択中</span>
                        <button class="act" onclick="startMulti()">⊞ 同時再生</button>
                        <label style="color:var(--text-secondary);font-size:13px;">秒/枚 <input class="ss-clip" id="ss-clip" type="number" min="1" max="60" value="15"></label>
                        <button class="act" onclick="startSlideshow()">▷ スライドショー</button>
                        <button class="act ghost" onclick="clearSelection()">選択解除</button>
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
                    <div class="up-next" id="up-next"></div>
                </div>

                <div id="multi-modal">
                    <div class="multi-grid" id="multi-grid"></div>
                    <div class="multi-controls">
                        <button onclick="multiTogglePlay()" title="再生/一時停止">⏯</button>
                        <button onclick="multiSeek(-10)" title="10秒戻る">⏪</button>
                        <button onclick="multiSeek(10)" title="10秒進む">⏩</button>
                        <button onclick="multiRandom()" title="ランダム位置">🔀</button>
                        <input type="range" id="multi-slider" min="0" max="1000" value="0" oninput="multiSliderInput(this.value)">
                        <button onclick="multiToggleMute()" title="ミュート切替">🔊</button>
                        <button onclick="closeMulti()" title="閉じる">✕</button>
                    </div>
                </div>

                <div id="slideshow-modal">
                    <div class="ss-title" id="ss-title"></div>
                    <video id="ss-video" playsinline style="width:100%;height:100%;object-fit:contain;background:#000;"></video>
                    <div class="ss-controls">
                        <button onclick="ssPrev()" title="前のクリップ">⏮</button>
                        <button onclick="ssTogglePlay()" title="再生/一時停止">⏯</button>
                        <button onclick="ssNext()" title="次のクリップ">⏭</button>
                        <button onclick="closeSlideshow()" title="閉じる">✕</button>
                    </div>
                </div>

                <script>
                    let currentRawVideos = [];
                    let currentFilteredVideos = [];
                    let currentAlbums = [];
                    let currentAlbumName = "";
                    let currentMediaIndex = 0;
                    let selectedQuality = "1080p";

                    // 同時再生・スライドショー用
                    let selectMode = false;
                    let selectedIds = new Set();
                    let multiPlayers = [];
                    let multiTimer = null;
                    let ssVids = [], ssIndex = 0, ssTimer = null, ssClip = 15;

                    // XSS対策: innerHTML に差し込む前にユーザー入力（ファイル名・アルバム名）をエスケープする
                    function esc(s) {
                        return String(s).replace(/[&<>"']/g, function(c) {
                            return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];
                        });
                    }

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

                    function showAlbumsView(skipPushState = false) {
                        if (!skipPushState) {
                            history.pushState({ view: 'albums' }, '', window.location.pathname);
                        }
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
                            currentAlbums = albums;
                            
                            let libHtml = '<div class="section-title">ライブラリ</div><div class="grid">';
                            let vidHtml = '<div class="section-title">動画アルバム</div><div class="grid">';
                            let phoHtml = '<div class="section-title">写真アルバム</div><div class="grid">';
                            
                            let hasVid = false, hasPho = false;

                            albums.forEach((album, index) => {
                                const thumbHtml = album.coverVideoID
                                    ? `<img class="thumb" src="/thumbnail/${encodeURIComponent(album.coverVideoID)}" loading="lazy" style="position:absolute; width:100%; height:100%; object-fit:cover;">`
                                    : `<div class="icon-center">${album.type === 'photo' ? '🖼️' : '📁'}</div>`;
                                const cardHtml = `
                                    <div class="card" onclick="loadVideos(${index})">
                                        <div class="thumb-container">
                                            ${thumbHtml}
                                            <div class="badge-count">${album.videoCount}</div>
                                        </div>
                                        <div class="title" style="color: ${album.type === 'photo' ? '#ff9f0a' : '#fff'}">${esc(album.name)}</div>
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

                    async function loadVideos(albumIndex, skipPushState = false) {
                        const album = currentAlbums[albumIndex];
                        if (!album) return;
                        if (!skipPushState) {
                            history.pushState({ view: 'videos', albumIndex: albumIndex }, '', '#' + album.id);
                        }
                        const albumId = album.id;
                        currentAlbumName = album.name;
                        document.getElementById('albums-view').style.display = 'none';
                        document.getElementById('videos-view').style.display = 'block';
                        document.getElementById('back-btn').style.display = 'block';
                        document.getElementById('page-title').innerText = album.name;
                        document.getElementById('search-input').value = "";
                        resetSelection();

                        const grid = document.getElementById('videos-grid');
                        grid.innerHTML = '<p style="grid-column: 1/-1; text-align:center; color:#888;">読み込み中...</p>';

                        try {
                            const res = await fetch(`/albums/${encodeURIComponent(albumId)}/videos`);
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
                                <div class="card" data-id="${video.id}" onclick="cardClick(${index})">
                                    <div class="check">✓</div>
                                    <div class="thumb-container">
                                        <img class="thumb" src="/thumbnail/${encodeURIComponent(video.id)}" loading="lazy" onerror="this.src='data:image/svg+xml;utf8,<svg xmlns=\\'http://www.w3.org/2000/svg\\'><rect width=\\'100%\\' height=\\'100%\\' fill=\\'%23111\\'/></svg>'">
                                        ${durBadge}
                                        <div class="badge-type">${typeIcon}</div>
                                    </div>
                                    <div class="title">${esc(video.filename)}</div>
                                </div>
                            `;
                        });
                        grid.innerHTML = html;
                        updateSelectionUI();
                    }

                    function openMedia(index) {
                        if (index < 0 || index >= currentFilteredVideos.length) return;
                        const modal = document.getElementById('player-modal');
                        const wasOpen = modal.style.display === 'flex';
                        currentMediaIndex = index;
                        const media = currentFilteredVideos[index];
                        const isPhoto = media.mediaType === 'photo';

                        modal.classList.toggle('mode-photo', isPhoto);
                        modal.classList.toggle('mode-video', !isPhoto);

                        document.getElementById('player-filename').innerText = media.filename;
                        const container = document.getElementById('media-container');
                        
                        const oldMedia = document.getElementById('main-media');
                        if (oldMedia) oldMedia.remove();
                        
                        if (isPhoto) {
                            document.getElementById('quality-select').style.display = 'none';
                            const img = document.createElement('img');
                            img.id = 'main-media';
                            img.className = 'photo-viewer';
                            img.src = `/video/${encodeURIComponent(media.id)}`;
                            container.insertBefore(img, container.children[1]);
                        } else {
                            document.getElementById('quality-select').style.display = 'block';
                            const video = document.createElement('video');
                            video.id = 'main-media';
                            video.controls = true;
                            video.playsInline = true;
                            video.src = `/video/${encodeURIComponent(media.id)}?q=${selectedQuality}`;
                            
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
                        
                        modal.style.display = 'flex';

                        // YouTube風: 縦向きのとき下部に他の動画リストを表示
                        if (!wasOpen || !document.getElementById('up-next').hasChildNodes()) {
                            renderUpNext();
                        } else {
                            updateUpNextHighlight();
                        }
                    }

                    function renderUpNext() {
                        const list = document.getElementById('up-next');
                        let html = '<div class="un-head">再生中・他のメディア</div>';
                        currentFilteredVideos.forEach((v, i) => {
                            const isPhoto = v.mediaType === 'photo';
                            const dur = !isPhoto && v.duration > 0 ? `<div class="un-dur">${formatDuration(v.duration)}</div>` : '';
                            const cur = i === currentMediaIndex ? ' current' : '';
                            html += `
                                <div class="un-item${cur}" data-idx="${i}" onclick="openMedia(${i})">
                                    <div class="un-thumb-wrap">
                                        <img class="un-thumb" src="/thumbnail/${encodeURIComponent(v.id)}" loading="lazy" onerror="this.style.visibility='hidden'">
                                        ${dur}
                                    </div>
                                    <div class="un-info">
                                        <div class="un-title">${esc(v.filename)}</div>
                                        <div class="un-meta">${isPhoto ? '📷 写真' : '🎥 動画'}</div>
                                    </div>
                                </div>`;
                        });
                        list.innerHTML = html;
                        scrollCurrentIntoView();
                    }

                    function updateUpNextHighlight() {
                        document.querySelectorAll('#up-next .un-item').forEach(el => {
                            el.classList.toggle('current', Number(el.dataset.idx) === currentMediaIndex);
                        });
                        scrollCurrentIntoView();
                    }

                    function scrollCurrentIntoView() {
                        const el = document.querySelector('#up-next .un-item.current');
                        if (el) el.scrollIntoView({ block: 'nearest' });
                    }

                    function changeQuality(q) {
                        selectedQuality = q;
                        const media = currentFilteredVideos[currentMediaIndex];
                        if (media && media.mediaType !== 'photo') {
                            const video = document.getElementById('main-media');
                            const currentTime = video.currentTime;
                            const isPaused = video.paused;
                            
                            video.src = `/video/${encodeURIComponent(media.id)}?q=${q}`;
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

                    // ===== 選択モード =====
                    function toggleSelectMode() {
                        selectMode = !selectMode;
                        document.getElementById('select-btn').classList.toggle('active', selectMode);
                        document.getElementById('select-actions').style.display = selectMode ? 'flex' : 'none';
                        if (!selectMode) { selectedIds.clear(); updateSelectionUI(); }
                    }
                    function resetSelection() {
                        selectMode = false;
                        selectedIds.clear();
                        const btn = document.getElementById('select-btn');
                        if (btn) btn.classList.remove('active');
                        const act = document.getElementById('select-actions');
                        if (act) act.style.display = 'none';
                    }
                    function cardClick(index) {
                        if (selectMode) toggleSelect(index); else openMedia(index);
                    }
                    function toggleSelect(index) {
                        const v = currentFilteredVideos[index];
                        if (!v || v.mediaType === 'photo') return; // 動画のみ
                        if (selectedIds.has(v.id)) selectedIds.delete(v.id); else selectedIds.add(v.id);
                        updateSelectionUI();
                    }
                    function clearSelection() { selectedIds.clear(); updateSelectionUI(); }
                    function updateSelectionUI() {
                        document.querySelectorAll('.card').forEach(c => {
                            const id = c.getAttribute('data-id');
                            if (id && selectedIds.has(id)) c.classList.add('selected'); else c.classList.remove('selected');
                        });
                        const cnt = document.getElementById('select-count');
                        if (cnt) cnt.innerText = selectedIds.size;
                    }
                    function selectedVideoList() {
                        return currentFilteredVideos.filter(v => selectedIds.has(v.id) && v.mediaType !== 'photo');
                    }

                    // ===== 同時再生（同期グリッド） =====
                    function startMulti() {
                        const vids = selectedVideoList().slice(0, 9);
                        if (vids.length < 2) { alert('動画を2本以上選択してください'); return; }
                        openMulti(vids);
                    }
                    function columnsFor(n) { return n <= 1 ? 1 : (n <= 4 ? 2 : 3); }
                    function openMulti(vids) {
                        clearInterval(multiTimer);
                        const grid = document.getElementById('multi-grid');
                        grid.className = 'multi-grid cols-' + columnsFor(vids.length);
                        grid.innerHTML = vids.map(v => `<video class="multi-video" src="/video/${encodeURIComponent(v.id)}?q=${selectedQuality}" playsinline muted></video>`).join('');
                        document.getElementById('multi-modal').style.display = 'flex';
                        multiPlayers = Array.from(grid.querySelectorAll('video'));
                        multiPlayers.forEach(p => p.play().catch(() => {}));
                        const slider = document.getElementById('multi-slider');
                        multiTimer = setInterval(() => {
                            const lead = multiLead();
                            if (lead && lead.duration) slider.value = Math.round((lead.currentTime / lead.duration) * 1000);
                        }, 300);
                    }
                    function multiLead() {
                        let lead = null, max = -1;
                        multiPlayers.forEach(p => { const d = p.duration || 0; if (d > max) { max = d; lead = p; } });
                        return lead || multiPlayers[0];
                    }
                    function multiTogglePlay() {
                        const playing = multiPlayers.some(p => !p.paused);
                        multiPlayers.forEach(p => playing ? p.pause() : p.play().catch(() => {}));
                    }
                    function multiSeek(s) {
                        multiPlayers.forEach(p => { p.currentTime = Math.max(0, Math.min(p.duration || 0, p.currentTime + s)); });
                    }
                    function multiSeekPct(pct) {
                        multiPlayers.forEach(p => { if (p.duration) p.currentTime = p.duration * pct; });
                    }
                    function multiSliderInput(v) { multiSeekPct(v / 1000); }
                    function multiRandom() {
                        let shortest = Infinity;
                        multiPlayers.forEach(p => { if (p.duration && p.duration < shortest) shortest = p.duration; });
                        if (!isFinite(shortest)) return;
                        const t = Math.random() * shortest;
                        multiPlayers.forEach(p => p.currentTime = t);
                    }
                    function multiToggleMute() {
                        const anyUnmuted = multiPlayers.some(p => !p.muted);
                        multiPlayers.forEach(p => p.muted = anyUnmuted);
                    }
                    function closeMulti() {
                        clearInterval(multiTimer);
                        multiPlayers.forEach(p => { p.pause(); p.removeAttribute('src'); p.load(); });
                        multiPlayers = [];
                        document.getElementById('multi-modal').style.display = 'none';
                    }

                    // ===== スライドショー =====
                    function startSlideshow() {
                        const vids = selectedVideoList();
                        if (vids.length < 2) { alert('動画を2本以上選択してください'); return; }
                        ssClip = Math.max(1, Math.min(60, parseInt(document.getElementById('ss-clip').value) || 15));
                        ssVids = vids; ssIndex = 0;
                        document.getElementById('slideshow-modal').style.display = 'flex';
                        ssPlayClip();
                    }
                    function ssPlayClip() {
                        clearTimeout(ssTimer);
                        if (ssIndex < 0) ssIndex = ssVids.length - 1;
                        if (ssIndex >= ssVids.length) ssIndex = 0;
                        const v = ssVids[ssIndex];
                        const video = document.getElementById('ss-video');
                        document.getElementById('ss-title').innerText = (ssIndex + 1) + ' / ' + ssVids.length + '   ' + v.filename;
                        video.src = `/video/${encodeURIComponent(v.id)}?q=${selectedQuality}`;
                        video.onloadedmetadata = () => {
                            const dur = video.duration || 0;
                            video.currentTime = (dur > ssClip) ? Math.random() * (dur - ssClip) : 0;
                            video.play().catch(() => { video.muted = true; video.play().catch(() => {}); });
                            clearTimeout(ssTimer);
                            ssTimer = setTimeout(ssNext, ssClip * 1000);
                        };
                        video.onended = ssNext;
                    }
                    function ssNext() { ssIndex++; ssPlayClip(); }
                    function ssPrev() { ssIndex--; ssPlayClip(); }
                    function ssTogglePlay() {
                        const video = document.getElementById('ss-video');
                        if (video.paused) { video.play().catch(() => {}); ssTimer = setTimeout(ssNext, ssClip * 1000); }
                        else { video.pause(); clearTimeout(ssTimer); }
                    }
                    function closeSlideshow() {
                        clearTimeout(ssTimer);
                        const video = document.getElementById('ss-video');
                        video.pause(); video.removeAttribute('src'); video.load();
                        document.getElementById('slideshow-modal').style.display = 'none';
                    }

                    // 同時再生・スライドショーのキーボード操作
                    document.addEventListener('keydown', (e) => {
                        const multiOpen = document.getElementById('multi-modal').style.display === 'flex';
                        const ssOpen = document.getElementById('slideshow-modal').style.display === 'flex';
                        if (!multiOpen && !ssOpen) return;
                        if (document.activeElement.tagName === 'INPUT') return;
                        if (e.key === 'Escape') { e.preventDefault(); multiOpen ? closeMulti() : closeSlideshow(); return; }
                        if (multiOpen) {
                            if (e.key >= '0' && e.key <= '9') { e.preventDefault(); multiSeekPct(parseInt(e.key) / 10); return; }
                            switch (e.key.toLowerCase()) {
                                case ' ': case 'k': e.preventDefault(); multiTogglePlay(); break;
                                case 'j': e.preventDefault(); multiSeek(-5); break;
                                case 'l': e.preventDefault(); multiSeek(5); break;
                                case 'h': e.preventDefault(); multiSeek(-10); break;
                                case ';': e.preventDefault(); multiSeek(10); break;
                                case 'r': e.preventDefault(); multiRandom(); break;
                            }
                        } else if (ssOpen) {
                            switch (e.key) {
                                case 'ArrowRight': e.preventDefault(); ssNext(); break;
                                case 'ArrowLeft': e.preventDefault(); ssPrev(); break;
                                case ' ': case 'k': case 'K': e.preventDefault(); ssTogglePlay(); break;
                            }
                        }
                    });

                    window.addEventListener('popstate', (e) => {
                        if (e.state && e.state.view === 'videos') {
                            loadVideos(e.state.albumIndex, true);
                        } else {
                            showAlbumsView(true);
                        }
                    });

                    showAlbumsView(true);
                </script>
            </body>
            </html>
            """#
}
