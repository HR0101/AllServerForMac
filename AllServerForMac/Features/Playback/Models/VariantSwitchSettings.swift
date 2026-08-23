import Foundation

/// 差分切り替え再生の切り替え間隔まわりの設定。
///
/// プレイヤーを閉じるたびに入れ直したくない値なので UserDefaults に置く。
/// 既定の 3〜6 秒は、これまで ffmpeg で「切り替えまとめ」を焼いていたときの間隔に合わせている。
enum VariantSwitchSettings {
    static let minIntervalKey = "variantSwitch.minInterval"
    static let maxIntervalKey = "variantSwitch.maxInterval"
    static let autoSwitchKey = "variantSwitch.autoSwitchEnabled"
    static let avoidRepeatKey = "variantSwitch.avoidsImmediateRepeat"

    static let defaultMinInterval: Double = 3
    static let defaultMaxInterval: Double = 6

    /// 0.5秒より上は従来の0.5秒刻み，それ以下だけ細かく調整する。
    static let fineIntervalThreshold: Double = 0.5
    static let fineIntervalStep: Double = 0.1
    static let coarseIntervalStep: Double = 0.5
    static let allowedRange: ClosedRange<Double> = 0.1...60

    static var minInterval: Double {
        get { readInterval(minIntervalKey, fallback: defaultMinInterval) }
        set { UserDefaults.standard.set(clamp(newValue), forKey: minIntervalKey) }
    }

    static var maxInterval: Double {
        get { max(readInterval(maxIntervalKey, fallback: defaultMaxInterval), minInterval) }
        set { UserDefaults.standard.set(clamp(newValue), forKey: maxIntervalKey) }
    }

    static var isAutoSwitchEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoSwitchKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoSwitchKey) }
    }

    /// 同じバージョンが2回続けて選ばれるのを避けるか。
    /// 避けないと「切り替えたのに何も変わらない」瞬間が混ざる。
    static var avoidsImmediateRepeat: Bool {
        get { UserDefaults.standard.object(forKey: avoidRepeatKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: avoidRepeatKey) }
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
    }

    /// 増加時は0.5秒未満，減少時は0.5秒以下にいる間だけ0.1秒刻みにする。
    /// これにより，境界では `1.0 → 0.5 → 0.4` と `0.4 → 0.5 → 1.0` になる。
    static func adjustedInterval(_ value: Double, increasing: Bool) -> Double {
        let usesFineStep = increasing
            ? value < fineIntervalThreshold
            : value <= fineIntervalThreshold
        let step = usesFineStep ? fineIntervalStep : coarseIntervalStep
        let adjustedValue = value + (increasing ? step : -step)
        return clamp((adjustedValue * 10).rounded() / 10)
    }

    private static func readInterval(_ key: String, fallback: Double) -> Double {
        guard let stored = UserDefaults.standard.object(forKey: key) as? Double else { return fallback }
        return clamp(stored)
    }
}
