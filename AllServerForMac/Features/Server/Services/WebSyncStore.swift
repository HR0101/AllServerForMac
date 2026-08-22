import Foundation

/// ブラウザクライアントの「視聴位置・お気に入り・履歴」を1か所に束ねる保管庫。
///
/// library.json に相乗りさせていないのは次の4点による:
/// 1. library.json は LibraryViewModel.saveData() が MainActor から世代カウンタ付きで
///    デバウンス保存している。HTTP ワーカースレッドが同じファイルに書くと、その世代管理の
///    外側からの上書きになりライブラリ本体をサイレントに壊しうる。
/// 2. 被害範囲が違う。こちらが消えて失うのは視聴位置と履歴だけで済む。
/// 3. 更新頻度が3桁違う（再生中は数秒おき）。相乗りさせると再生のたびに動画数千件の JSON を書き直す。
/// 4. library.json は iOS クライアントとも共有する「ライブラリの契約」。個人の閲覧状態は別レイヤー。
///
/// すべての読み書きを1本のシリアルキューに閉じてあるので、read-modify-write のマージが
/// サーバー側で不可分に完結する。2つのブラウザが交互に PUT しても取りこぼさないのはこのため。
final class WebSyncStore: @unchecked Sendable {

    // MARK: - ドキュメント形

    struct ProgressEntry: Codable {
        var t: Double
        var at: Double

        init(t: Double, at: Double) { self.t = t; self.at = at }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            t = try c.decodeIfPresent(Double.self, forKey: .t) ?? 0
            at = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
        }
    }

    struct MarkEntry: Codable {
        var on: Bool
        var at: Double

        init(on: Bool, at: Double) { self.on = on; self.at = at }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? false
            at = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
        }
    }

    struct ShortMarkEntry: Codable {
        var on: Bool
        var t: Double
        var at: Double

        init(on: Bool, t: Double, at: Double) { self.on = on; self.t = t; self.at = at }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? false
            t = try c.decodeIfPresent(Double.self, forKey: .t) ?? 0
            at = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
        }
    }

    struct HistoryEntry: Codable {
        var id: String
        var at: Double

        init(id: String, at: Double) { self.id = id; self.at = at }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            at = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
        }
    }

    /// 全フィールドが省略可。部分的な送信や古いクライアントを 400 で弾かず、欠損は空として扱う。
    struct SyncDoc: Codable {
        var schemaVersion: Int = 1
        /// サーバー時刻(ms)。クライアントは表示にもキャッシュ判定にも使わない、デバッグ用。
        var updatedAt: Double = 0
        var progress: [String: ProgressEntry] = [:]
        var favorites: [String: MarkEntry] = [:]
        var history: [HistoryEntry] = []
        /// 履歴から個別削除した時刻。古い端末の履歴で削除済み項目が復活するのを防ぐ。
        var historyRemoved: [String: Double] = [:]
        var shortsFavs: [String: ShortMarkEntry] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
            progress = try c.decodeIfPresent([String: ProgressEntry].self, forKey: .progress) ?? [:]
            favorites = try c.decodeIfPresent([String: MarkEntry].self, forKey: .favorites) ?? [:]
            history = try c.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
            historyRemoved = try c.decodeIfPresent([String: Double].self, forKey: .historyRemoved) ?? [:]
            shortsFavs = try c.decodeIfPresent([String: ShortMarkEntry].self, forKey: .shortsFavs) ?? [:]
        }
    }

    // MARK: - 上限
    // バグった／悪意あるクライアントに websync.json を無限に太らせないための歯止め。
    // progress はトゥームストーン（t:0）を残す方式で単調増加するので、この上限だけが唯一の歯止め。
    private static let maxProgress = 500
    private static let maxHistory = 200
    private static let maxFavorites = 5000
    private static let maxShortsFavs = 2000
    /// お気に入りの「外した記録」を捨ててよくなるまでの猶予（90日）。
    /// これより新しい on:false は残さないと、他端末の古い配列で解除が巻き戻る。
    private static let tombstoneTTLms: Double = 90 * 24 * 60 * 60 * 1000
    /// 受信 at の未来方向のクランプ幅。時計が進んだ端末が全衝突に勝ち続けるのを止める。
    /// 過去方向にクランプしないのは、オフライン端末の正当に古いタイムスタンプを潰さないため。
    private static let futureSkewToleranceMs: Double = 60_000

    // MARK: - 状態

    private let fileURL: URL
    private let backupURL: URL
    private let rootURL: URL
    private let persistenceEnabled: Bool
    /// HTTP ワーカースレッドから呼ばれるため DispatchQueue.main は一切使わない。
    private let queue = DispatchQueue(label: "com.allserverformac.websync", qos: .utility)
    private var doc = SyncDoc()

    init(rootURL: URL, persistenceEnabled: Bool = true) {
        self.rootURL = rootURL
        self.fileURL = rootURL.appendingPathComponent("websync.json")
        self.backupURL = rootURL.appendingPathComponent("websync.backup.json")
        self.persistenceEnabled = persistenceEnabled
        guard persistenceEnabled else { return }
        queue.sync { self.load() }
    }

    // MARK: - 公開 API

    /// GET /sync 用。エンコード済み JSON を返す。
    func snapshotData() -> Data {
        return queue.sync { encode(doc) }
    }

    /// PUT /sync 用。クライアントの全体像を受け取り、マージ結果を返す。
    /// read-modify-write をこのキューの中に閉じるのがこのクラスの存在理由。
    func merge(incoming: SyncDoc) -> Data {
        return queue.sync {
            let now = Date().timeIntervalSince1970 * 1000
            var merged = doc
            mergeProgress(into: &merged, incoming: incoming, now: now)
            mergeFavorites(into: &merged, incoming: incoming, now: now)
            mergeShortsFavs(into: &merged, incoming: incoming, now: now)
            mergeHistory(into: &merged, incoming: incoming, now: now)
            applyLimits(&merged, now: now)
            merged.schemaVersion = 1
            merged.updatedAt = now
            doc = merged
            let data = encode(merged)
            save(data)
            return data
        }
    }

    // MARK: - マージ規則（すべてキー単位の LWW レジスタ）

    /// 未来方向だけクランプした受信 at。
    private func clamp(_ at: Double, now: Double) -> Double {
        let ceiling = now + Self.futureSkewToleranceMs
        return at > ceiling ? ceiling : at
    }

    private func mergeProgress(into merged: inout SyncDoc, incoming: SyncDoc, now: Double) {
        for (id, entry) in incoming.progress {
            let at = clamp(entry.at, now: now)
            // 同値は incoming 勝ちにして、同一ミリ秒での書き直しが落ちないようにする
            if let stored = merged.progress[id], stored.at > at { continue }
            merged.progress[id] = ProgressEntry(t: entry.t, at: at)
        }
    }

    private func mergeFavorites(into merged: inout SyncDoc, incoming: SyncDoc, now: Double) {
        for (id, entry) in incoming.favorites {
            let at = clamp(entry.at, now: now)
            if let stored = merged.favorites[id], stored.at > at { continue }
            merged.favorites[id] = MarkEntry(on: entry.on, at: at)
        }
    }

    private func mergeShortsFavs(into merged: inout SyncDoc, incoming: SyncDoc, now: Double) {
        for (id, entry) in incoming.shortsFavs {
            let at = clamp(entry.at, now: now)
            if let stored = merged.shortsFavs[id], stored.at > at { continue }
            merged.shortsFavs[id] = ShortMarkEntry(on: entry.on, t: entry.t, at: at)
        }
    }

    /// 履歴本体と個別削除記録をそれぞれ LWW でマージし，削除より新しく再生された項目だけを残す。
    private func mergeHistory(into merged: inout SyncDoc, incoming: SyncDoc, now: Double) {
        var best: [String: Double] = [:]
        for e in merged.history where !e.id.isEmpty {
            if (best[e.id] ?? -1) < e.at { best[e.id] = e.at }
        }
        for e in incoming.history where !e.id.isEmpty {
            let at = clamp(e.at, now: now)
            if (best[e.id] ?? -1) < at { best[e.id] = at }
        }
        for (id, removedAt) in incoming.historyRemoved where !id.isEmpty {
            let at = clamp(removedAt, now: now)
            if (merged.historyRemoved[id] ?? -1) < at {
                merged.historyRemoved[id] = at
            }
        }
        best = best.filter { id, playedAt in
            playedAt > (merged.historyRemoved[id] ?? -1)
        }
        merged.history = best.map { HistoryEntry(id: $0.key, at: $0.value) }
            .sorted { $0.at > $1.at }
    }

    private func applyLimits(_ merged: inout SyncDoc, now: Double) {
        if merged.history.count > Self.maxHistory {
            merged.history = Array(merged.history.prefix(Self.maxHistory))
        }
        merged.historyRemoved = merged.historyRemoved.filter {
            now - $0.value < Self.tombstoneTTLms
        }

        if merged.progress.count > Self.maxProgress {
            let keep = merged.progress.sorted { $0.value.at > $1.value.at }.prefix(Self.maxProgress)
            var trimmed: [String: ProgressEntry] = [:]
            for kv in keep { trimmed[kv.key] = kv.value }
            merged.progress = trimmed
        }

        // 期限切れの「外した記録」を先に落としてから件数で切る。
        // on:true を先に残すのは、解除の記録より現役のお気に入りの方が失って困るため。
        merged.favorites = merged.favorites.filter { $0.value.on || now - $0.value.at < Self.tombstoneTTLms }
        if merged.favorites.count > Self.maxFavorites {
            let keep = merged.favorites.sorted { a, b in
                if a.value.on != b.value.on { return a.value.on }
                return a.value.at > b.value.at
            }.prefix(Self.maxFavorites)
            var trimmed: [String: MarkEntry] = [:]
            for kv in keep { trimmed[kv.key] = kv.value }
            merged.favorites = trimmed
        }

        merged.shortsFavs = merged.shortsFavs.filter { $0.value.on || now - $0.value.at < Self.tombstoneTTLms }
        if merged.shortsFavs.count > Self.maxShortsFavs {
            let keep = merged.shortsFavs.sorted { a, b in
                if a.value.on != b.value.on { return a.value.on }
                return a.value.at > b.value.at
            }.prefix(Self.maxShortsFavs)
            var trimmed: [String: ShortMarkEntry] = [:]
            for kv in keep { trimmed[kv.key] = kv.value }
            merged.shortsFavs = trimmed
        }
    }

    // MARK: - 永続化（すべて queue の中からのみ呼ぶ）

    private func encode(_ value: SyncDoc) -> Data {
        let encoder = JSONEncoder()
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    private func load() {
        guard persistenceEnabled else { return }
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            if let decoded = try? JSONDecoder().decode(SyncDoc.self, from: data) {
                doc = decoded
                return
            }
            // 壊れた正本は上書きせずに残す。原因調査ができないと同じ事故を繰り返す。
            let stamp = Int(Date().timeIntervalSince1970)
            let corruptedURL = rootURL.appendingPathComponent("websync.corrupted-\(stamp).json")
            try? data.write(to: corruptedURL, options: .atomic)
            print("⚠️ [SYNC] websync.json が破損していたため \(corruptedURL.lastPathComponent) へ退避しました。")

            if let backup = try? Data(contentsOf: backupURL),
               let decoded = try? JSONDecoder().decode(SyncDoc.self, from: backup) {
                doc = decoded
                print("♻️ [SYNC] websync.backup.json から復旧しました。")
                return
            }
            doc = SyncDoc()
            return
        }
        // ファイルなし／空は初回起動の正常系。空から始めても、各クライアントは自分のローカルと
        // マージしてから返すので、次に繋いだ端末が中身を戻してくれる。
        doc = SyncDoc()
    }

    private func save(_ data: Data) {
        guard persistenceEnabled else { return }
        // 直前の正本を1世代だけ退避する。ローテーションを増やさないのは、失っても
        // 各クライアントの localStorage から復元できる軽いデータだから。
        if let previous = try? Data(contentsOf: fileURL), !previous.isEmpty {
            try? previous.write(to: backupURL, options: .atomic)
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
