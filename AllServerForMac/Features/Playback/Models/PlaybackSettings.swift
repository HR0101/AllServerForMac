import Combine
import Foundation
import SwiftUI

/// 再生し終わったときの動き。ブラウザ UI の「リピート」と同じ3段階。
enum PlaybackRepeatMode: String, CaseIterable, Identifiable {
    case off
    case one
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "リピートなし"
        case .one: return "1本をリピート"
        case .all: return "リストをリピート"
        }
    }

    var symbolName: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    /// なし → 1本 → 全体 → なし の順に一巡する。
    var next: PlaybackRepeatMode {
        switch self {
        case .off: return .one
        case .one: return .all
        case .all: return .off
        }
    }
}

/// 通常再生の設定（自動再生・リピート・シャッフル・再生速度）。
///
/// ブラウザ UI が `mms_playback` に持っているものと同じ役割。ただし端末ごとの好みなので
/// `/sync`（視聴位置・履歴）では共有せず、Mac 側は UserDefaults に持つ。
@MainActor
final class PlaybackSettings: ObservableObject {

    /// 選べる再生速度。ブラウザ UI と同じ 0.5〜2 倍。
    static let availableRates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// 再生し終わったら次の動画へ進むか。
    @Published var autoPlayNext: Bool {
        didSet { defaults.set(autoPlayNext, forKey: Keys.autoPlayNext) }
    }
    /// リストの末尾での折り返し方（`.one` は自動再生の設定に関わらず効く）。
    @Published var repeatMode: PlaybackRepeatMode {
        didSet { defaults.set(repeatMode.rawValue, forKey: Keys.repeatMode) }
    }
    /// 次の動画を並び順ではなく無作為に選ぶ。
    @Published var isShuffleEnabled: Bool {
        didSet { defaults.set(isShuffleEnabled, forKey: Keys.shuffle) }
    }
    @Published var rate: Double {
        didSet { defaults.set(rate, forKey: Keys.rate) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let autoPlayNext = "playback.autoPlayNext"
        static let repeatMode = "playback.repeatMode"
        static let shuffle = "playback.shuffle"
        static let rate = "playback.rate"
    }

    init() {
        // 未設定なら「終わったら次へ」。動画アプリとしてはこちらが素直な既定。
        autoPlayNext = defaults.object(forKey: Keys.autoPlayNext) as? Bool ?? true
        repeatMode = defaults.string(forKey: Keys.repeatMode)
            .flatMap(PlaybackRepeatMode.init(rawValue:)) ?? .off
        isShuffleEnabled = defaults.bool(forKey: Keys.shuffle)
        // 未設定の double は 0 になる。そのまま使うと再生が止まるので等倍に倒す。
        rate = Self.normalizedRate(defaults.object(forKey: Keys.rate) as? Double ?? 1.0)
    }

    /// 段階リストのいずれかへ吸着させる。中途半端な値が残っていると
    /// メニューの選択がどこにも当たらず「速度が選べない」ように見える。
    static func normalizedRate(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1.0 }
        return availableRates.min { abs($0 - value) < abs($1 - value) } ?? 1.0
    }

    /// いまの速度を段階リストの上下へ1つ動かす。
    func stepRate(by steps: Int) {
        let rates = Self.availableRates
        let currentIndex = rates.firstIndex { abs($0 - rate) < 0.01 }
            ?? rates.firstIndex { $0 > rate }
            ?? rates.count - 1
        rate = rates[min(max(currentIndex + steps, 0), rates.count - 1)]
    }

    /// 「1×」「1.25×」のような表示。末尾の 0 は落とす。
    static func label(forRate value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }

    var rateLabel: String { Self.label(forRate: rate) }
}
