import Foundation
import Swifter

extension ServerViewModel {

    // MARK: - 視聴位置・お気に入り・履歴の同期ルート
    // 1600行級に育っている WebServerRoutes.swift をこれ以上太らせないため別ファイルに置く。
    func setupSyncRoutes() {

        // 1MiB はおおよそ1.2万エントリ相当。progress 500 / history 200 / favorites 5000 の
        // 設計上限に対して十分な余裕があり、暴走したクライアントのメモリ展開も止められる。
        let maxSyncBytes = 1_048_576

        server.get["/sync"] = protected { [weak self] _ -> HttpResponse in
            guard let self = self else { return .internalServerError }
            let data = self.syncStore.snapshotData()
            // 端末間の同期状態がプロキシやブラウザにキャッシュされると同期の意味を失う
            let headers = ["Content-Type": "application/json", "Cache-Control": "no-store"]
            return .raw(200, "OK", headers, { try? $0.write([UInt8](data)) })
        }

        // PUT はクライアントの「全体像」を受け取り、サーバー保管分とマージした結果を返す。
        // マージをサーバーの read-modify-write に閉じないと、
        // 「A が GET →（B が PUT）→ A が PUT」で B の書き込みが消える。
        // 応答にマージ結果を載せるので、クライアントは PUT 直後に追加の GET をしなくてよい。
        let syncWrite: (HttpRequest) -> HttpResponse = { [weak self] request -> HttpResponse in
            guard let self = self else { return .internalServerError }
            guard request.body.count <= maxSyncBytes else {
                return .raw(413, "Payload Too Large", ["Content-Type": "text/plain"], { try? $0.write(Array("Sync payload too large".utf8)) })
            }
            guard let doc = try? JSONDecoder().decode(WebSyncStore.SyncDoc.self, from: Data(request.body)) else {
                return .badRequest(.text("Invalid sync body"))
            }
            return .ok(.data(self.syncStore.merge(incoming: doc), contentType: "application/json"))
        }

        // 閲覧状態の更新にすぎずライブラリの実体は消さないので protected（protectedDestructive ではない）
        server.put["/sync"] = protected(syncWrite)
        // navigator.sendBeacon は必ず POST になる。ページ離脱時の最後の1回を受けるためのエイリアス。
        // 将来 POST /sync に別の意味を持たせないこと。
        server.post["/sync"] = protected(syncWrite)
    }
}
