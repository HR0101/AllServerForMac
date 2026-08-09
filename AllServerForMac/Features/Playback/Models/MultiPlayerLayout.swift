import Foundation

/// タイルの並び。行ごとに、その行へ左から並べるプレイヤーの添字を持つ。
///
/// 画面の組み立てと、音の定位（左のタイルは左から鳴らす）の計算が必ず同じ配置を見るように、
/// 配置の定義はここ1か所だけにする。
enum MultiPlayerLayout {
    static func rows(for count: Int) -> [[Int]] {
        switch count {
        case 2: return [[0], [1]]
        case 3: return [[0, 1], [2]]
        case 4: return [[0, 1], [2, 3]]
        case 5: return [[0, 1, 2], [3, 4]]
        case 6: return [[0, 1], [2, 3], [4, 5]]
        case 7: return [[0, 1, 2], [3, 4], [5, 6]]
        case 8: return [[0, 1, 2], [3, 4, 5], [6, 7]]
        case 9: return [[0, 1, 2], [3, 4, 5], [6, 7, 8]]
        default: return count > 0 ? [Array(0..<count)] : []
        }
    }

    /// 配置から決まる既定の定位。-1（左端）〜 +1（右端）。
    /// 1列しかない行は中央（0）。3列なら左 -1 / 中央 0 / 右 +1 になる。
    static func defaultPans(for count: Int) -> [Int: Float] {
        var result: [Int: Float] = [:]
        for row in rows(for: count) {
            guard row.count > 1 else {
                row.forEach { result[$0] = 0 }
                continue
            }
            for (column, index) in row.enumerated() {
                result[index] = Float(column) / Float(row.count - 1) * 2 - 1
            }
        }
        return result
    }
}
