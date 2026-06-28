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

                    /* Shorts Modal */
                    #shorts-modal { display:none; position:fixed; inset:0; background:#000; z-index:1000; flex-direction:column; overflow:hidden; }
                    .shorts-video-container { flex:1; position:relative; width:100%; height:100%; display:flex; justify-content:center; align-items:center; }
                    .shorts-video-container video { width:100%; height:100%; object-fit:contain; outline:none; transition: transform 0.1s; }
                    .shorts-ui { position:absolute; bottom:40px; left:20px; right:90px; color:#fff; text-shadow:0 2px 4px #000; pointer-events:none; }
                    .shorts-ui-title { font-size:16px; font-weight:bold; margin-bottom:8px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
                    .shorts-progress-container { width:100%; height:8px; background:rgba(255,255,255,0.3); border-radius:4px; cursor:pointer; margin-bottom:12px; position:relative; pointer-events:auto; }
                    .shorts-progress-bar { height:100%; background:var(--accent-color); border-radius:4px; width:0%; pointer-events:none; }
                    .shorts-ui-controls { display:flex; align-items:center; gap:12px; pointer-events:auto; }
                    .shorts-ui-controls input[type=range] { flex:1; }
                    .shorts-controls { position:absolute; right:20px; bottom:40px; display:flex; flex-direction:column; gap:24px; pointer-events:auto; }
                    .shorts-btn { width:50px; height:50px; background:rgba(255,255,255,0.2); border-radius:25px; display:flex; justify-content:center; align-items:center; color:#fff; font-size:24px; cursor:pointer; backdrop-filter:blur(8px); }
                    .shorts-close { position:absolute; top:20px; left:20px; width:40px; height:40px; background:rgba(0,0,0,0.5); color:#fff; font-size:24px; display:flex; justify-content:center; align-items:center; border-radius:20px; cursor:pointer; z-index:1001; pointer-events:auto; }

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
                    <div style="flex:1"></div>
                    <button class="tool-btn" id="global-shorts-btn" onclick="startGlobalShorts()" style="background:var(--accent-color); color:#000; font-weight:bold;">おすすめショート</button>
                </div>

                <div class="container" id="albums-view">
                    <div id="library-section"></div>
                    <div id="video-albums-section"></div>
                    <div id="photo-albums-section"></div>
                    <div id="face-albums-section"></div>
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
                        <button class="tool-btn" id="analyze-btn" onclick="analyzeAlbumFaces()">顔解析</button>
                        <button class="tool-btn" id="rename-face-btn" onclick="renameFaceGroup()" style="display:none;">名前変更</button>
                        <button class="tool-btn" id="shorts-btn" onclick="startShorts()">🎞 ショート再生</button>
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

                <div id="shorts-modal">
                    <div class="shorts-close" onclick="closeShorts()">✕</div>
                    <div class="shorts-video-container" id="shorts-container" onclick="toggleShortsPlay()">
                        <div id="shorts-video-wrapper" style="width:100%; height:100%; display:flex; justify-content:center; align-items:center;">
                            <video id="shorts-video" playsinline loop></video>
                        </div>
                    </div>
                    <div class="shorts-ui">
                        <div class="shorts-ui-title" id="shorts-title"></div>
                        <div class="shorts-progress-container" id="shorts-progress" onclick="seekShorts(event)">
                            <div class="shorts-progress-bar" id="shorts-progress-bar"></div>
                        </div>
                    </div>
                    <div class="shorts-controls">
                        <div class="shorts-btn" onclick="toggleShortsSettings()">⚙️</div>
                        <div class="shorts-btn" onclick="prevShorts()">▲</div>
                        <div class="shorts-btn" onclick="nextShorts()">▼</div>
                    </div>
                    <div id="shorts-settings-popup" style="display:none; position:absolute; bottom:120px; right:80px; background:rgba(30,30,30,0.9); padding:16px; border-radius:12px; backdrop-filter:blur(10px); z-index:1002; pointer-events:auto; color:white; width:200px; box-shadow:0 10px 30px rgba(0,0,0,0.5);">
                        <div style="font-size:14px; font-weight:bold; margin-bottom:12px; text-align:center;">🔍 サイズ調整</div>
                        <input type="range" id="shorts-zoom" min="0" max="100" value="100" oninput="updateShortsZoom()" style="width:100%;">
                    </div>
                </div>

                <script>
                    let currentRawVideos = [];
                    let currentFilteredVideos = [];
                    let currentAlbums = [];
                    let currentAlbumName = "";
                    let currentMediaIndex = 0;
                    let selectedQuality = "1080p";

                    // ショート用
                    let shortsVids = [];
                    let shortsIndex = 0;
                    let shortsClipStartTime = 0;
                    const SHORTS_CLIP_DURATION = 60;

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
                        document.getElementById('global-shorts-btn').style.display = 'block';
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
                            let faceHtml = '<div class="section-title">顔認識グループ</div><div class="grid">';
                            
                            let hasVid = false, hasPho = false, hasFace = false;

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
                                if (album.name.startsWith("👤 ")) {
                                    faceHtml += cardHtml;
                                    hasFace = true;
                                } else if (album.name === "ALL VIDEOS" || album.name === "ALL PHOTOS" || album.type === "mixed") {
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
                            document.getElementById('face-albums-section').innerHTML = hasFace ? faceHtml + '</div>' : '';
                            
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
                        document.getElementById('global-shorts-btn').style.display = 'none';
                        document.getElementById('page-title').innerText = album.name;
                        document.getElementById('search-input').value = "";
                        
                        if (album.name.startsWith("👤 ")) {
                            document.getElementById('rename-face-btn').style.display = 'inline-block';
                            document.getElementById('analyze-btn').style.display = 'none';
                        } else {
                            document.getElementById('rename-face-btn').style.display = 'none';
                            document.getElementById('analyze-btn').style.display = 'inline-block';
                        }

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

                    async function analyzeAlbumFaces() {
                        const album = currentAlbums[history.state.albumIndex];
                        if(!album) return;
                        if(confirm("このアルバム内の未解析の動画をサーバー側で顔解析しますか？")) {
                            fetch(`/albums/${encodeURIComponent(album.id)}/analyzeFaces`, { method: 'POST' });
                            alert("サーバーで解析を開始しました。しばらく経ってから「顔認識グループ」を確認してください。");
                        }
                    }

                    async function renameFaceGroup() {
                        const album = currentAlbums[history.state.albumIndex];
                        if(!album || !album.name.startsWith("👤 ")) return;
                        const newName = prompt("新しい名前を入力してください", album.name.replace("👤 ", ""));
                        if(newName && newName.trim() !== "") {
                            await fetch(`/faces/${encodeURIComponent(album.id)}/rename`, {
                                method: 'POST',
                                headers: {'Content-Type': 'application/json'},
                                body: JSON.stringify({ name: newName.trim() })
                            });
                            alert("名前を変更しました！");
                            loadAlbums();
                            document.getElementById('page-title').innerText = "👤 " + newName.trim();
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
                                <div class="card" data-id="${video.id}" onclick="openMedia(${index})">
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

                    // ===== ショート再生機能 =====
                    async function startGlobalShorts() {
                        const allVideosAlbum = currentAlbums.find(a => a.name === "ALL VIDEOS");
                        if (!allVideosAlbum) { alert("ALL VIDEOSアルバムが見つかりません"); return; }
                        try {
                            const res = await fetch(`/albums/${encodeURIComponent(allVideosAlbum.id)}/videos`);
                            if (res.status === 401) { showLogin(); return; }
                            let vids = await res.json();
                            vids = vids.filter(v => v.mediaType !== 'photo');
                            for (let i = vids.length - 1; i > 0; i--) {
                                const j = Math.floor(Math.random() * (i + 1));
                                [vids[i], vids[j]] = [vids[j], vids[i]];
                            }
                            if (vids.length === 0) { alert('再生できる動画がありません'); return; }
                            shortsVids = vids;
                            shortsIndex = 0;
                            document.getElementById('shorts-modal').style.display = 'flex';
                            playShorts();
                        } catch(e) {
                            alert('全動画の取得に失敗しました');
                        }
                    }

                    function startShorts() {
                        shortsVids = currentFilteredVideos.filter(v => v.mediaType !== 'photo');
                        if (shortsVids.length === 0) {
                            alert('再生できる動画がありません');
                            return;
                        }
                        shortsIndex = 0;
                        document.getElementById('shorts-modal').style.display = 'flex';
                        playShorts();
                    }

                    function playShorts() {
                        const v = shortsVids[shortsIndex];
                        const video = document.getElementById('shorts-video');
                        document.getElementById('shorts-title').innerText = (shortsIndex + 1) + " / " + shortsVids.length + " - " + v.filename;
                        
                        if (v.duration > SHORTS_CLIP_DURATION) {
                            shortsClipStartTime = Math.random() * (v.duration - SHORTS_CLIP_DURATION);
                        } else {
                            shortsClipStartTime = 0;
                        }
                        
                        video.src = `/video/${encodeURIComponent(v.id)}?q=${selectedQuality}`;
                        video.play().catch(e => console.log("Auto-play blocked", e));
                    }

                    function nextShorts() {
                        if (shortsIndex < shortsVids.length - 1) {
                            shortsIndex++;
                            playShorts();
                        }
                    }

                    function prevShorts() {
                        if (shortsIndex > 0) {
                            shortsIndex--;
                            playShorts();
                        }
                    }

                    function toggleShortsPlay() {
                        // Close settings if open
                        const settings = document.getElementById('shorts-settings-popup');
                        if (settings.style.display === 'block') {
                            settings.style.display = 'none';
                            return;
                        }
                        const video = document.getElementById('shorts-video');
                        if (video.paused) video.play(); else video.pause();
                    }

                    function toggleShortsSettings() {
                        const popup = document.getElementById('shorts-settings-popup');
                        popup.style.display = popup.style.display === 'none' ? 'block' : 'none';
                    }

                    function closeShorts() {
                        document.getElementById('shorts-settings-popup').style.display = 'none';
                        const video = document.getElementById('shorts-video');
                        video.pause();
                        video.removeAttribute('src');
                        video.load();
                        document.getElementById('shorts-modal').style.display = 'none';
                    }

                    function updateShortsZoom() {
                        const video = document.getElementById('shorts-video');
                        const slider = document.getElementById('shorts-zoom');
                        const wrapper = document.getElementById('shorts-video-wrapper');
                        
                        const val = parseInt(slider.value) / 100.0;
                        if (val === 0) {
                            video.style.transform = 'scale(1)';
                            return;
                        }
                        
                        const viewAspect = wrapper.clientWidth / wrapper.clientHeight;
                        const videoAspect = (video.videoWidth && video.videoHeight) ? (video.videoWidth / video.videoHeight) : viewAspect;
                        
                        let fillScale = 1.0;
                        if (videoAspect > viewAspect) {
                            fillScale = wrapper.clientHeight / (wrapper.clientWidth / videoAspect);
                        } else {
                            fillScale = wrapper.clientWidth / (wrapper.clientHeight * videoAspect);
                        }
                        fillScale = Math.max(1.0, fillScale);
                        const finalScale = 1.0 + (fillScale - 1.0) * val;
                        video.style.transform = `scale(${finalScale})`;
                    }

                    function seekShorts(e) {
                        const container = document.getElementById('shorts-progress');
                        const rect = container.getBoundingClientRect();
                        const x = e.clientX - rect.left;
                        const pct = Math.max(0, Math.min(1, x / rect.width));
                        const video = document.getElementById('shorts-video');
                        if(video.duration) {
                            const clipLen = Math.min(video.duration, SHORTS_CLIP_DURATION);
                            video.currentTime = shortsClipStartTime + pct * clipLen;
                        }
                    }

                    document.getElementById('shorts-video').addEventListener('timeupdate', (e) => {
                        const video = e.target;
                        if(video.duration) {
                            if (video.currentTime - shortsClipStartTime >= SHORTS_CLIP_DURATION) {
                                nextShorts();
                                return;
                            }
                            const clipLen = Math.min(video.duration, SHORTS_CLIP_DURATION);
                            const currentInClip = Math.max(0, video.currentTime - shortsClipStartTime);
                            const pct = Math.min(100, (currentInClip / clipLen) * 100);
                            document.getElementById('shorts-progress-bar').style.width = pct + '%';
                        }
                    });

                    document.getElementById('shorts-video').addEventListener('loadedmetadata', (e) => {
                        e.target.currentTime = shortsClipStartTime;
                        updateShortsZoom();
                    });

                    window.addEventListener('resize', () => {
                        if (document.getElementById('shorts-modal').style.display === 'flex') {
                            updateShortsZoom();
                        }
                    });

                    // スワイプ & ホイールでショート操作
                    document.getElementById('shorts-container').addEventListener('wheel', (e) => {
                        e.preventDefault(); // 画面スクロール防止
                        if(e.deltaY > 50) nextShorts();
                        else if(e.deltaY < -50) prevShorts();
                    });

                    let touchStartY = 0;
                    const shortsModal = document.getElementById('shorts-modal');
                    shortsModal.addEventListener('touchstart', e => touchStartY = e.changedTouches[0].screenY);
                    shortsModal.addEventListener('touchend', e => {
                        let dy = e.changedTouches[0].screenY - touchStartY;
                        if(dy < -50) nextShorts();
                        else if(dy > 50) prevShorts();
                    });

                    document.addEventListener('keydown', (e) => {
                        const shortsOpen = document.getElementById('shorts-modal').style.display === 'flex';
                        if (shortsOpen) {
                            if (e.key === 'Escape') { e.preventDefault(); closeShorts(); return; }
                            if (e.key === 'ArrowUp') { e.preventDefault(); prevShorts(); return; }
                            if (e.key === 'ArrowDown') { e.preventDefault(); nextShorts(); return; }
                            if (e.key === ' ') { e.preventDefault(); toggleShortsPlay(); return; }
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
