import CoreGraphics
import Foundation
import ImageIO

// MARK: - 見た目が似ているメディアを探すための知覚ハッシュ
//
// 既存の「重複チェック」はファイルの中身が1バイトも違わないものだけを見つける。
// こちらは「作り直した書き出し」「解像度違い」「軽く加工した別バージョン」のように
// ファイルとしては別物だが見た目がほぼ同じ、というものを見つけるためのもの。
//
// 手法は dHash（差分ハッシュ）。画像を 9x8 のグレースケールまで潰し、
// 横に隣り合う画素の明暗を比べて 64 ビットにする。
// 明るさ全体の変化や軽い圧縮では値が変わらず、構図が変わると大きく変わる。

struct PerceptualHash: Equatable, Hashable {
    let bits: UInt64

    /// 何ビット違うか（0＝完全に同じ見た目、64＝正反対）。
    func distance(to other: PerceptualHash) -> Int {
        (bits ^ other.bits).nonzeroBitCount
    }
}

enum PerceptualHasher {
    /// 比較する格子の大きさ。横は隣との差を取るぶん1つ多く読む。
    private static let rows = 8
    private static let columns = 8

    /// 画像ファイルから知覚ハッシュを求める。読めなければ nil。
    /// ファイルIOと画素走査だけなので、バックグラウンドから並行して呼んでよい。
    nonisolated static func hash(forImageAt url: URL) -> PerceptualHash? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            // 縮小してから潰すので、元画像をフルサイズで展開しなくて済む。
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return hash(of: cgImage)
    }

    nonisolated static func hash(of cgImage: CGImage) -> PerceptualHash? {
        let width = columns + 1
        let height = rows
        var pixels = [UInt8](repeating: 0, count: width * height)

        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            // 透過部分を黒として扱わないよう、白で塗ってから描く。
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var bits: UInt64 = 0
        var bitIndex = 0
        for y in 0..<height {
            for x in 0..<columns {
                let left = pixels[y * width + x]
                let right = pixels[y * width + x + 1]
                if left > right { bits |= (1 << UInt64(bitIndex)) }
                bitIndex += 1
            }
        }
        return PerceptualHash(bits: bits)
    }
}

// MARK: - 似ているもの同士のまとめ上げ

enum SimilarityGrouping {
    /// `hashes` を、距離が `maxDistance` 以内でつながるもの同士のグループへまとめる。
    ///
    /// A と B が似ていて B と C も似ていれば、A と C を直接比べなくても同じグループにする
    /// （書き出しを重ねた系列は少しずつずれていくため、直接比較だけだと分断されてしまう）。
    /// 2件以上になったグループだけを、元の並び順を保って返す。
    static func groups<ID: Hashable>(
        of hashes: [(id: ID, hash: PerceptualHash)],
        maxDistance: Int
    ) -> [[ID]] {
        guard hashes.count > 1 else { return [] }

        var parent = Array(0..<hashes.count)
        func root(_ index: Int) -> Int {
            var current = index
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }
        func union(_ a: Int, _ b: Int) {
            let rootA = root(a), rootB = root(b)
            if rootA != rootB { parent[rootB] = rootA }
        }

        for i in 0..<hashes.count {
            for j in (i + 1)..<hashes.count where hashes[i].hash.distance(to: hashes[j].hash) <= maxDistance {
                union(i, j)
            }
        }

        // 元の並び順を保ったままグループへ振り分ける。
        var buckets: [Int: [ID]] = [:]
        var order: [Int] = []
        for index in 0..<hashes.count {
            let key = root(index)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(hashes[index].id)
        }
        return order.compactMap { key in
            guard let bucket = buckets[key], bucket.count > 1 else { return nil }
            return bucket
        }
    }
}
