import AVFoundation
import CoreGraphics
import Foundation

// MARK: - 差分動画（同じ映像の衣装違い・状態違い）の検出
//
// 「似ているものを探す」(`SimilarMediaViewModel`) はサムネイル1枚だけを見て、
// ほぼ同じものを消す候補として拾う。こちらは目的が逆で、
// 「同じ尺・同じ動きで、絵の一部だけが差し替わった別バージョン」を **残したまま** 見つける。
// 見つけたグループはそのまま差分切り替え再生（`VariantSwitchPlayerView`）へ渡す。
//
// 判定は2段階。
//  1. 尺で束ねる。差分書き出しは同じタイムラインから出すので尺がフレーム単位で揃う。
//     ここで大半の組み合わせが落ちるため、重いフレーム展開をごく一部にだけ絞れる。
//  2. 束の中だけで、同じ相対位置から取った数フレームの知覚ハッシュを突き合わせる。
//     衣装や肌の差し替えは dHash の一部ビットしか動かさないので、
//     まったく別の動画（距離 20〜30 前後）とははっきり差が付く。
//  そのうえで、ファイル名の近さ（`TitleSimilarity`）でしきい値を少し上下させる。
//  名前は「無関係かどうか」をよく言い当てる一方で「別キャラかどうか」は言い当てられないので、
//  主役はあくまでフレームで、名前は効き幅を絞った補助に留めている。

/// 動画1本ぶんの指紋。同じ相対位置から取った複数フレームの知覚ハッシュを、その順番のまま持つ。
struct VideoFrameSignature: Equatable, Sendable {
    let hashes: [PerceptualHash]

    /// 同じ位置のフレームどうしを突き合わせた平均ハミング距離（0〜64）。
    /// 枚数が違うものは位置が対応しないので比較しない。
    func averageDistance(to other: VideoFrameSignature) -> Double? {
        guard !hashes.isEmpty, hashes.count == other.hashes.count else { return nil }
        let total = zip(hashes, other.hashes).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        return Double(total) / Double(hashes.count)
    }
}

enum VariantFrameSampler {
    /// フレームを取り出す位置（尺に対する割合）。
    /// 先頭と末尾は黒フレームやフェードで潰れて、どの動画も同じ絵になってしまうため避ける。
    static let samplePositions: [Double] = [0.08, 0.24, 0.40, 0.56, 0.72, 0.88]

    /// 動画から指紋を作る。1枚でも取れなければ位置が対応しなくなるので nil を返す。
    ///
    /// 比べたいのは構図だけなので `maximumSize` で小さく起こす（4K のまま展開すると
    /// 1枚あたり数十MB になり、数本ぶんでメモリも時間も一気に膨らむ）。
    /// 一方で時刻の誤差は許さない。近いフレームで代用されると、同じ位置を比べているつもりが
    /// 動きのぶんだけずれて、本物の差分どうしでも距離が開いてしまう。
    nonisolated static func signature(forVideoAt url: URL, duration: TimeInterval) async -> VideoFrameSignature? {
        guard duration > 0 else { return nil }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var hashes: [PerceptualHash] = []
        hashes.reserveCapacity(samplePositions.count)
        for position in samplePositions {
            if Task.isCancelled { return nil }
            let time = CMTime(seconds: duration * position, preferredTimescale: 600)
            guard let cgImage = try? await generator.image(at: time).image,
                  let hash = PerceptualHasher.hash(of: cgImage) else { return nil }
            hashes.append(hash)
        }
        return VideoFrameSignature(hashes: hashes)
    }
}

enum VariantVideoDetector {
    /// 束の中の1本ぶんの手がかり。フレームの指紋と、そろえ済みのファイル名。
    struct Fingerprint: Sendable {
        let signature: VideoFrameSignature
        let title: [Character]

        init(signature: VideoFrameSignature, filename: String) {
            self.signature = signature
            self.title = TitleSimilarity.normalized(filename)
        }
    }

    /// 名前がどれだけ遠くても、これ以下のしきい値までは締めない。
    /// 名前を付け替えただけの差分（フレームはほぼ一致）を取りこぼさないための下限。
    static let minimumThreshold: Double = 2

    /// 名前の近さでしきい値を上下させたもの。0.5 を中立に、近ければ足し、遠ければ引く。
    ///
    /// `influence` で効き幅を抑えているのは、名前だけでは差分（0.57〜0.94）と
    /// 別キャラ（0.41〜0.67）が重なって見分けられないため。
    /// 名前の近さだけでフレームの隔たり（差分 2〜9 に対し別キャラ 14〜19）を
    /// 埋め切れない大きさに留めておく必要がある。
    static func effectiveThreshold(
        base: Double,
        titleSimilarity: Double,
        influence: Double
    ) -> Double {
        max(minimumThreshold, base + influence * (titleSimilarity - 0.5) * 2)
    }

    /// 2本が同じ映像の別バージョンかどうか。
    static func isVariantPair(
        _ lhs: Fingerprint,
        _ rhs: Fingerprint,
        maxAverageDistance: Double,
        titleInfluence: Double
    ) -> Bool {
        guard let distance = lhs.signature.averageDistance(to: rhs.signature) else { return false }
        let threshold = effectiveThreshold(
            base: maxAverageDistance,
            titleSimilarity: TitleSimilarity.score(lhs.title, rhs.title),
            influence: titleInfluence
        )
        return distance <= threshold
    }

    /// 尺が `tolerance` 秒以内で揃うものを1つの束にする。
    ///
    /// 尺の昇順に見ていき、束の先頭からの差が `tolerance` を超えたところで束を切る。
    /// 「隣どうしの差」で切ると、わずかな差が積み重なった長い鎖が1つの束になってしまう。
    /// 2件以上になった束だけを返す（1件だけの尺は差分の相手がいない）。
    static func durationBuckets(
        of items: [VideoItem],
        tolerance: TimeInterval
    ) -> [[VideoItem]] {
        let sorted = items.filter { $0.mediaType == .video && $0.duration > 0 }
            .sorted { $0.duration < $1.duration }
        guard sorted.count > 1 else { return [] }

        var buckets: [[VideoItem]] = []
        var current: [VideoItem] = []
        var anchor: TimeInterval = 0

        for item in sorted {
            if current.isEmpty || item.duration - anchor <= tolerance {
                if current.isEmpty { anchor = item.duration }
                current.append(item)
            } else {
                if current.count > 1 { buckets.append(current) }
                current = [item]
                anchor = item.duration
            }
        }
        if current.count > 1 { buckets.append(current) }
        return buckets
    }

    /// 束を、差分どうしとみなせるものでつながるグループへまとめる。
    /// フレームの指紋が取れなかったものは、名前がどれだけ近くても対象にしない
    /// （名前だけでは根拠として弱く、別キャラを引き込んでしまう）。
    static func groups(
        in bucket: [VideoItem],
        fingerprints: [UUID: Fingerprint],
        maxAverageDistance: Double,
        titleInfluence: Double
    ) -> [[VideoItem]] {
        let entries: [(id: UUID, value: Fingerprint)] = bucket.compactMap { item in
            guard let fingerprint = fingerprints[item.id] else { return nil }
            return (id: item.id, value: fingerprint)
        }
        guard entries.count > 1 else { return [] }

        let grouped = SimilarityGrouping.groups(of: entries) { lhs, rhs in
            isVariantPair(
                lhs, rhs,
                maxAverageDistance: maxAverageDistance,
                titleInfluence: titleInfluence
            )
        }

        let itemsByID = Dictionary(bucket.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        return grouped.compactMap { ids in
            let items = ids.compactMap { itemsByID[$0] }
            return items.count > 1 ? items : nil
        }
    }

    /// グループがどれくらいの根拠でまとまったのかを画面に出すための実測値。
    struct GroupStats: Equatable {
        var frameDistance: ClosedRange<Double>
        var titleSimilarity: ClosedRange<Double>
    }

    static func stats(for items: [VideoItem], fingerprints: [UUID: Fingerprint]) -> GroupStats? {
        let found = items.compactMap { fingerprints[$0.id] }
        guard found.count > 1 else { return nil }

        var distances: [Double] = []
        var similarities: [Double] = []
        for i in 0..<found.count {
            for j in (i + 1)..<found.count {
                if let distance = found[i].signature.averageDistance(to: found[j].signature) {
                    distances.append(distance)
                }
                similarities.append(TitleSimilarity.score(found[i].title, found[j].title))
            }
        }
        guard let lowDistance = distances.min(), let highDistance = distances.max(),
              let lowTitle = similarities.min(), let highTitle = similarities.max() else { return nil }
        return GroupStats(
            frameDistance: lowDistance...highDistance,
            titleSimilarity: lowTitle...highTitle
        )
    }
}
