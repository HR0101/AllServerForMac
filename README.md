# AllServerForMac（Mac 動画サーバー）

自宅の Mac を「個人用メディアサーバー」にする SwiftUI 製 macOS アプリです。Mac 内の動画・写真を同一 Wi‑Fi 上の iPhone アプリ（[VideoPlayer](../VideoPlayer)）やブラウザから閲覧・再生できます。

> ペアになるクライアント: iOS アプリ **VideoPlayer**（Bonjour で自動検出）

---

## 主な機能

- **HTTP 配信サーバー**（[Swifter](https://github.com/httpswift/swifter) ベース）でアルバム / 動画 / 写真 / サムネイルを配信
- **Bonjour 公開**（`_myvideoserver._tcp.`）で、クライアントが LAN 内のサーバーを自動検出
- **ブラウザ UI** 内蔵（`/` にアクセスするとそのまま閲覧可能）。iOS / Android 版と同じ **ホーム / ショート / アルバム** の 3 タブ構成で、Mac は左サイドレール、スマホは下タブバーに自動で切り替わる（[詳細](#ブラウザ-ui3-タブ)）
- **アルバム管理**（作成・削除・動画の移動、`ALL VIDEOS` / `ALL PHOTOS` 仮想アルバム）
- **サムネイル自動生成**（動画はフレーム抽出、AVFoundation 使用）
- **PIN 認証**：Web/クライアントからのアクセスに 6 桁 PIN を要求（ヘッダ `X-Auth-PIN` / Cookie `pin` / クエリ `pin` の 3 経路に対応）
- **アクセスログ**（直近 200 件、IP・メソッド・パス・認可結果）
- **1080p オンデマンド変換**：クライアントが「1080p」を選んだ時だけ低画質プロキシをその場で生成し、視聴終了で自動削除（常に 1 本分のみ保持しストレージを圧迫しない）
- **自動停止タイマー**：指定時間で無操作なら完全終了して省電力
- **スケジュール起動/停止**：毎日決まった時刻に起動・終了（`launchd` の LaunchAgent + スリープ起床は `pmset`）
- **ストレージ管理画面**（容量集計、孤立プロキシの掃除、Finder で開く）

---

## 動作環境

- macOS 15.5 以降
- Xcode（Swift / SwiftUI）
- 依存: Swifter（Swift Package Manager で導入済み）
- App Sandbox: **無効**（`launchctl` / `pmset` / LaunchAgent 書き込みのため）。エンタイトルメントは `com.apple.developer.networking.multicast` のみ。

---

## ビルドと起動

1. `AllServerForMac.xcodeproj` を Xcode で開く
2. ターゲット `AllServerForMac` を実行（▶）
3. アプリ画面で **ポート番号**（既定 8080）を確認し「開始」を押す
4. 同じ Wi‑Fi 上の iPhone で VideoPlayer を開くと、サーバーが自動的に一覧に出ます

> スケジュール起動を使う場合は、ビルドしたアプリを `/Applications` など**固定の場所**へ配置してから設定画面で「適用」してください（plist にアプリのパスを書き込むため）。

---

## データの保存場所

| 種類 | パス |
|---|---|
| ライブラリ DB | `~/Movies/MacVideoServerData/library.json` |
| 取り込み動画 | `~/Movies/MacVideoServerData/Videos/` |
| サムネイル | `~/Movies/MacVideoServerData/Thumbnails/` |
| プロキシ（一時） | `~/Movies/MacVideoServerData/Proxies/` |
| ダウンロード取込先 | `~/Downloads/VideoServerForMac_Media/` |

---

## HTTP API（抜粋）

すべて PIN 認証が有効なときは認可が必要です（`/` とサムネイルの一部を除く）。

| メソッド | パス | 説明 |
|---|---|---|
| GET | `/` | ブラウザ用 Web UI |
| GET | `/albums` | アルバム一覧（JSON） |
| GET | `/album/:id/videos` | アルバム内のメディア一覧（JSON） |
| GET | `/video/:id?q=original\|1080p` | 動画ストリーム（プロキシがあれば配信、無ければオリジナル） |
| GET | `/video/:id/prepare?q=1080p` | 1080p プロキシをオンデマンド生成し、進捗を返す（`{state, progress}`） |
| DELETE | `/video/:id/proxy` | オンデマンドプロキシを全削除（視聴終了時のクリーンアップ） |
| GET | `/thumbnail/:id` | サムネイル（JPEG） |
| GET | `/server/status` | 稼働時間（JSON） |
| POST | `/server/shutdown` | サーバーを完全終了 |
| POST | `/albums/create` | アルバム作成 |
| DELETE | `/albums/:id` | アルバム削除 |
| POST | `/move` | 動画をアルバム間で移動 |
| POST | `/deleteVideos` | 動画削除 |

---

## ブラウザ UI（3 タブ）

`/` を開くと、iOS / Android クライアントと同じ 3 タブの画面が出ます。実体は
`Features/Server/Services/WebClientHTML.swift` の生文字列 1 本（HTML + CSS + JS）で、
外部アセットはありません。**Web プレイヤーを直すときはこの文字列を編集します。**

| タブ | 中身 | 元になっているクライアント側の画面 |
|---|---|---|
| ホーム | `ALL VIDEOS` をシャッフルした YouTube 風フィード（16:9 の大サムネ＋タイトル＋アルバム名・投稿からの経過時間）。数本おきに「おすすめショート」の横スクロール棚を挟む | `RemoteVideoListView`（`albumID == "HOME"`） |
| ショート | 全動画をシャッフルし、1 本ごとに**ランダムな開始位置から 60 秒**だけ再生する縦型プレイヤー。スワイプ / ホイール / ↑↓ で送り | `RemoteShortsPlayerView`（`albumID == "SHORTS"`） |
| アルバム | 従来のアルバム一覧 → 詳細グリッド（検索・並べ替え・アルバム単位のショート再生） | `AlbumListView` |

棚を挟む位置（1 本目の次、以降 4〜10 本おき）と「ショート＝60 秒以下の動画」の判定は
iOS 版の `isShortsShelfIndex` / `isShortVideo` と同じ規則にしてあります。

### スマホと Mac の出し分け

**1 つの HTML をメディアクエリ（境界 900px）で切り替えます**。ユーザーエージェント判定はしません。

| | スマホ（〜900px） | Mac / 広い画面（901px〜） |
|---|---|---|
| ナビ | 画面下のタブバー（`env(safe-area-inset-bottom)` 対応） | 左サイドレール 240px（901〜1099px はアイコン主体の 76px ミニレール） |
| ホーム | 1 列・端から端までのサムネ | `auto-fill` の複数列（1 列あたり最小 310px） |
| 検索 | 虫めがねを押すと展開 | 上部バーに常時表示 |
| 再生画面 | 上部に 16:9 固定＋下に「次の動画」が縦スクロール | 左に大きなプレイヤー、右に 400px の再生リスト |
| ショート | 全画面（上部バーは隠れ、下タブバーは残る）・操作ボタンは右下に重ねる | 中央に 9:16 の枠、操作ボタンは枠の右外 |
| サムネのプレビュー | なし（タップで再生） | カーソルを 0.7 秒乗せるとミュートで再生 |

### 補足

- サムネイルは iOS 版と同じ URL（`/thumbnail/:id?original=true`）を使うので、サーバー側の生成キャッシュを共有します。
- 一覧は 12 件ずつの遅延描画（`IntersectionObserver`）で、大きなライブラリでも初期表示が重くなりません。
- 画質切り替えは `?q=` を差し替えるだけで、`/video/:id/prepare` は呼びません。プロキシはサーバー全体で 1 本しか保持できず、ブラウザから生成すると視聴中の iOS クライアントのプロキシを壊すためです（プロキシが既にあればそれを使います）。

---

## ソース構成

macOSアプリは，機能単位のMVVM構成です．画面を追加・変更するときは，まず対象の`Features`配下を確認してください．複数機能から共有する実装だけを`Common`へ配置します．

```text
AllServerForMac/
├── App/
│   ├── Models/          # アプリ全体の画面選択など
│   ├── ViewModels/      # Feature間の依存を組み立てるAppViewModel
│   └── Views/           # ルート画面とウインドウ設定
├── Common/
│   ├── DesignSystem/    # 色，余白，共通ViewModifier
│   ├── Utilities/       # 画像処理，排他制御などの汎用処理
│   └── Views/           # 複数Featureで使う共通View
└── Features/
    ├── Dashboard/
    ├── Library/
    ├── MediaAnalysis/
    ├── Navigation/
    ├── Playback/
    ├── Server/
    ├── Settings/
    └── Storage/
```

各Featureは，必要に応じて次のフォルダを持ちます．

| フォルダ | 役割 |
|---|---|
| `Models/` | 永続化データ，値オブジェクト，画面状態の型 |
| `ViewModels/` | 画面状態とユーザー操作を扱う`ObservableObject` |
| `Views/` | SwiftUIによる表示と入力イベントの受け渡し |
| `Services/` | HTTP，ファイルI/O，メディア変換などの副作用 |
| `Components/` | Feature内だけで共有する小さなViewや再生部品 |

主要な依存関係は，`AppViewModel`が`LibraryViewModel`，`ServerViewModel`，`PlaybackCoordinator`，`AppSettings`を生成し，`ContentView`から各Featureへ渡す形です．Viewは表示とイベント通知を担当し，ライブラリ操作，サーバー制御，ストレージ集計などの状態変更はViewModelまたはServiceへ集約します．Feature固有の型を`Common`へ置かず，`Common`から`Features`へは依存させない方針です．

| 主な実装 | 役割 |
|---|---|
| `App/AllServerForMacApp.swift` | アプリのエントリーポイント |
| `App/ViewModels/AppViewModel.swift` | アプリ全体の依存関係と画面選択の管理 |
| `Features/Library/ViewModels/LibraryViewModel.swift` | ライブラリ状態の基点 |
| `Features/Library/ViewModels/LibraryViewModel+*.swift` | 取り込み，リンクフォルダ，重複検出，保存などの責務別処理 |
| `Features/Server/ViewModels/ServerViewModel.swift` | HTTPサーバー，認証，Bonjour，起動・停止状態の管理 |
| `Features/Playback/ViewModels/` | 動画，写真，分割再生，スライドショーの再生状態 |
| `Features/Storage/ViewModels/StorageViewModel.swift` | 容量集計とストレージ整理操作 |

---

## セキュリティ / 注意点

- **ローカル LAN 専用**を想定しています（通信は平文 HTTP）。インターネットへ直接公開しないでください。
- PIN はアプリ画面に表示され、再生成も可能です。クライアント側はキーチェーン/設定に PIN を保持します。
- スケジュール起動で `pmset repeat cancel` を使うと、**他に設定済みの繰り返し起床スケジュールも消えます**（個人利用なら通常問題ありません）。
- スリープ起床は電源接続が前提です（ノートのバッテリー駆動では起床しません）。

---

## 更新履歴

### 2026-07-06 データ保護・堅牢化アップデート

公開品質を目指した集中的な監査で、データ消失につながる問題と「想定しにくいバグ」を修正。

**データ保護（クレームレベルの修正）**

- `library.json` 破損時に空のライブラリで上書きしてしまう問題を修正。壊れたファイルは `library.corrupted-<日時>.json` に必ず退避し、**3世代ローテーションのバックアップ**（`library.backup.json` / `.2` / `.3`）から自動復元する。空に近いデータや新しいスキーマのデータではバックアップを更新しない（汚染防止）
- ライブラリが空の状態で孤児ファイル整理（`cleanUpOrphanedFiles`）が走ると `Videos/` 内の実ファイルを全削除しうるカスケードをガードで遮断
- リモート（iOS/Web）から「すべての動画/画像から外す」を実行すると実ファイルまで完全削除されていた経路を**ゴミ箱行き**に変更。完全削除は明示的な「完全に削除」操作のみ
- ライブラリから削除したとき、**アプリ管理外の元ファイル（フォルダインポートの参照元）には一切触れない**よう変更（以前は Finder のゴミ箱へ移動していた）
- アプリ内の削除操作全般で「ゴミ箱に入れる / 完全に削除」を必ず確認ダイアログで選択させるよう統一
- **二重起動検出**（`flock`）: Xcode 実行と通常起動などが同じライブラリを同時に開いた場合、後から起動した側は保存を一切行わず警告して終了（後勝ち上書きによるサイレント消失防止）
- 保存書き込みを専用直列キュー＋世代番号で直列化し、デバウンス保存とフラッシュ保存の追い越しレース（古い内容が後から勝つ）を排除。完全削除の直後はデバウンスを待たず即時書き込み

**想定しにくいバグの修正**

- パス判定の `hasPrefix` 境界バグ（`VideoServerForMac_Media_backup` のような兄弟フォルダをアプリ管理と誤判定）を修正
- リンク切れシンボリックリンクが毎起動修復に失敗し続ける問題（`fileExists` がリンクを辿る仕様との非対称）を修正
- 変更系 API（アルバム作成/削除/移動/完全削除）が反映前に成功応答を返し、直後の取得に古い状態が返る問題を修正（反映完了を待って応答）
- HTTP ルートが videos / albums を別々のロックで読むことによる不整合応答を、単一スナップショットの原子的読み取りに統合
- サムネイル/プロキシのファイル名をパース済み UUID の正規形で統一（大文字小文字を区別するボリューム対策）
- `fileHash` に計算時点のファイル更新日時を持たせ、中身が変わったファイルの古いハッシュを使い続けない（重複チェックの誤判定防止）
- `getIPAddress` が Parallels/Docker 等の仮想ブリッジを拾う問題を修正（en 番号の小さい順を優先、リンクローカル除外）
- ゴミ箱の `trashedDate` が時計変更で未来になった場合に現在時刻へ丸めて自己修復
- アクセスログに PIN がクエリごと平文で残る問題を修正（`pin=****` にマスク）
- Bonjour 公開失敗・名前衝突リネームをステータス表示で可視化（`didNotPublish` 実装）
- `library.json` に `schemaVersion` を導入。新しい形式のデータを旧ビルドの書き戻しから守る
- 大量インポート中の進捗表示が1件ごとに全体再描画を起こしていた問題を修正（25件ごとに間引き）
- `/server/status` が `maxUploadBytes` を公開し、クライアントが送信前にサイズ超過を弾けるように（Swifter はボディを全てメモリ展開するため、サーバー側チェックだけではメモリ枯渇を防げない）

**新機能**

- **詳細設定シート**（サイドバーの歯車アイコン）: インポート時コピー/参照の切替、ゴミ箱自動削除期限（なし/30日/90日）、リンク切れ自動整理、認証オフ時も削除系 API に PIN 要求、サーバー表示名、アップロード上限、自動重複チェック間隔、インポート並列数、サムネイルキャッシュ上限、エクスポート形式
- **エクスポート機能**: 選択メディア/アルバム/フォルダ丸ごとを、アルバム階層とファイル名を再現して任意フォルダへコピー書き出し（元ファイル紛失に備える安全弁）
- サイドバー: アルバムの複数選択→新規フォルダにまとめる、フォルダへのドラッグ＆ドロップ移動、フォルダタイトルクリックで開閉、選択中アルバムの自動展開

---

## ライセンス / クレジット

個人プロジェクト。HTTP サーバーに [Swifter](https://github.com/httpswift/swifter) を利用しています。
