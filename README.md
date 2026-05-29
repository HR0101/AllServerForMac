# AllServerForMac（Mac 動画サーバー）

自宅の Mac を「個人用メディアサーバー」にする SwiftUI 製 macOS アプリです。Mac 内の動画・写真を同一 Wi‑Fi 上の iPhone アプリ（[VideoPlayer](../VideoPlayer)）やブラウザから閲覧・再生できます。

> ペアになるクライアント: iOS アプリ **VideoPlayer**（Bonjour で自動検出）

---

## 主な機能

- **HTTP 配信サーバー**（[Swifter](https://github.com/httpswift/swifter) ベース）でアルバム / 動画 / 写真 / サムネイルを配信
- **Bonjour 公開**（`_myvideoserver._tcp.`）で、クライアントが LAN 内のサーバーを自動検出
- **ブラウザ UI** 内蔵（`/` にアクセスするとそのまま閲覧可能）
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

## ソース構成

| ファイル | 役割 |
|---|---|
| `AllServerForMacApp.swift` | アプリのエントリーポイント |
| `ContentView.swift` | メイン UI（サーバー設定・セキュリティ・スケジュール・アクセスログ） |
| `WebServerManager.swift` | HTTP サーバー、ルーティング、認証、Bonjour、スケジュール起動/停止 |
| `VideoDataManager.swift` | ライブラリ管理、取り込み、サムネイル、オンデマンドプロキシ生成 |
| `MacVideoThumbnailView.swift` | サムネイル表示用ビュー |
| `StorageManagerView.swift` | ストレージ管理画面 |

---

## セキュリティ / 注意点

- **ローカル LAN 専用**を想定しています（通信は平文 HTTP）。インターネットへ直接公開しないでください。
- PIN はアプリ画面に表示され、再生成も可能です。クライアント側はキーチェーン/設定に PIN を保持します。
- スケジュール起動で `pmset repeat cancel` を使うと、**他に設定済みの繰り返し起床スケジュールも消えます**（個人利用なら通常問題ありません）。
- スリープ起床は電源接続が前提です（ノートのバッテリー駆動では起床しません）。

---

## ライセンス / クレジット

個人プロジェクト。HTTP サーバーに [Swifter](https://github.com/httpswift/swifter) を利用しています。
