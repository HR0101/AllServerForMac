import Foundation

// MARK: - フレーム指紋の置き場
//
// 4K の動画から指紋を1本ぶん作るのに数秒かかる（時刻ぴったりのフレームを6枚起こすため、
// 毎回キーフレームから復号し直すことになる）。探すたびに作り直していると、
// 一度再生して戻ってきただけで数十秒待たされる。
//
// 指紋はファイルの中身だけで決まるので、中身が変わっていない限り使い回してよい。
// 中身が変わったかどうかは、実ファイルのサイズと更新日時で見る
// （`fileHash` は全バイト読むので、この用途には高すぎる）。
//
// 保存先は library.json と同じ `~/Movies/MacVideoServerData/`。あくまで作り直せる副産物なので、
// 読めなければ黙って空から始め、書けなければ黙って諦める（探索そのものは成立する）。
actor VariantSignatureStore {
    /// ファイルが同じものかを見分ける印。
    struct Stamp: Equatable, Sendable {
        var size: Int64
        var modified: Date?

        /// 更新日時はファイルシステムによって丸め方が違うので、1秒までは同じとみなす。
        func matches(_ other: Stamp) -> Bool {
            guard size == other.size else { return false }
            switch (modified, other.modified) {
            case (nil, nil): return true
            case let (lhs?, rhs?): return abs(lhs.timeIntervalSince(rhs)) < 1
            default: return false
            }
        }
    }

    private struct Entry: Codable {
        var size: Int64
        var modified: Double?
        /// 16進で持つ。`UInt64` を JSON の数値で往復させると桁が落ちうる。
        var hashes: [String]
        /// 最後に使った時刻。上限を超えたときに古いものから捨てるために持つ。
        var used: Double
    }

    private struct Payload: Codable {
        var scheme: String
        var entries: [String: Entry]
    }

    /// 取り出し方が変わったら、前に作った指紋は比べられない（同じ位置のフレーム同士でないと
    /// 突き合わせに意味がないため）。サンプル位置そのものを印にして、変えたら丸ごと捨てる。
    private static var schemeID: String {
        "1|" + VariantFrameSampler.samplePositions.map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    /// 残す上限。1件あたり数百バイトなので、大きめでも数MBに収まる。
    private static let maxEntries = 20_000

    private let fileURL: URL
    private var entries: [String: Entry] = [:]
    private var isLoaded = false
    private var isDirty = false

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("VariantSignatures.json")
    }

    // MARK: - 読み書き

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        guard payload.scheme == Self.schemeID else { return }
        entries = payload.entries
    }

    /// 覚えている指紋を返す。印が合わないもの（差し替えられたファイル）は捨てて nil を返す。
    func signature(for id: UUID, stamp: Stamp) -> VideoFrameSignature? {
        loadIfNeeded()
        let key = id.uuidString
        guard let entry = entries[key] else { return nil }

        let stored = Stamp(size: entry.size, modified: entry.modified.map(Date.init(timeIntervalSince1970:)))
        guard stored.matches(stamp) else {
            entries[key] = nil
            isDirty = true
            return nil
        }

        let bits = entry.hashes.compactMap { UInt64($0, radix: 16) }
        guard bits.count == entry.hashes.count, !bits.isEmpty else {
            entries[key] = nil
            isDirty = true
            return nil
        }

        entries[key]?.used = Date().timeIntervalSince1970
        isDirty = true
        return VideoFrameSignature(hashes: bits.map { PerceptualHash(bits: $0) })
    }

    func store(_ signature: VideoFrameSignature, for id: UUID, stamp: Stamp) {
        loadIfNeeded()
        entries[id.uuidString] = Entry(
            size: stamp.size,
            modified: stamp.modified?.timeIntervalSince1970,
            hashes: signature.hashes.map { String($0.bits, radix: 16) },
            used: Date().timeIntervalSince1970
        )
        isDirty = true
    }

    /// 書き出す。作り直せる副産物なので、失敗しても黙って諦める。
    func save() {
        guard isDirty else { return }
        isDirty = false

        if entries.count > Self.maxEntries {
            // 使った順に並べて、古いほうから捨てる。
            let keep = entries.sorted { $0.value.used > $1.value.used }.prefix(Self.maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }

        let payload = Payload(scheme: Self.schemeID, entries: entries)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
