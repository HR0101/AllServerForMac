import Foundation

// MARK: - ファイル名の近さ
//
// 差分動画は「同じ題を少しだけ言い換えた」名前になりやすい
// （`ミカが負ける動画` / `水着ミカが負ける動画` / `ミカが負ける動画『ミカのセリフ』`）。
// フレームを起こす前から手に入る手がかりなので、フレームの判定を補う材料に使う。
//
// 実ファイル名で 4 通りの指標（最長共通部分・文字バイグラム・レーベンシュタイン・前後一致）を
// 測り比べたところ、最長共通部分文字列を Dice で正規化したものがいちばんよく分かれた:
//
// | 関係 | 値 |
// |---|---|
// | 差分どうし | 0.57 〜 0.94 |
// | 同じ動きだが別キャラ | 0.41 〜 0.67 |
// | 無関係 | 0.00 〜 0.42 |
//
// つまり **「無関係かどうか」ははっきり分かれるが、「別キャラかどうか」は分からない**。
// `水着ミカが負ける動画` と `水着ヒフミが負ける動画` は 1 語しか違わないので、
// 衣装違いと同じくらい近く出てしまう。そこはフレームの距離（差分 2〜9 に対し
// 別キャラは 14〜19）が得意なので、この値は単独では使わず、
// フレーム側のしきい値を少し動かす補助として `VariantVideoDetector` が使う。

enum TitleSimilarity {
    /// 比べる前にそろえておく形。拡張子を落とし、全角/半角・大文字小文字・濁点の
    /// 表記ゆれを畳んでから文字の並びにする。
    static func normalized(_ filename: String) -> [Character] {
        let stem = (filename as NSString).deletingPathExtension
        let folded = stem
            .precomposedStringWithCanonicalMapping
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: nil)
        return Array(folded)
    }

    /// 0（共通部分なし）〜 1（同じ）。
    /// いちばん長く連続して一致する部分の長さを、両方の長さで割る（Dice）。
    ///
    /// 連続の長さを見るのが要点で、`水着` と `全裸` のように差し替えが端にあると
    /// 芯がまるごと残って高くなり、`ミカ` と `ヒフミ` のように真ん中で変わると芯が割れて低くなる。
    static func score(_ lhs: [Character], _ rhs: [Character]) -> Double {
        let total = lhs.count + rhs.count
        guard total > 0 else { return 0 }
        return 2.0 * Double(longestCommonSubstringLength(lhs, rhs)) / Double(total)
    }

    static func score(_ lhs: String, _ rhs: String) -> Double {
        score(normalized(lhs), normalized(rhs))
    }

    /// いちばん長く連続して一致する部分の長さ。
    /// 行を1本だけ持ち回すので、必要なメモリは短いほうの長さに比例するだけ。
    private static func longestCommonSubstringLength(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: rhs.count + 1)
        var current = previous
        var best = 0

        for i in 1...lhs.count {
            for j in 1...rhs.count {
                if lhs[i - 1] == rhs[j - 1] {
                    current[j] = previous[j - 1] + 1
                    if current[j] > best { best = current[j] }
                } else {
                    current[j] = 0
                }
            }
            swap(&previous, &current)
        }
        return best
    }
}
