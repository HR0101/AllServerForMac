import Foundation

/// PIN 認証の総当たり対策に使う純粋関数群．状態（IP 別の失敗回数）は呼び出し側が保持する．
public enum PINSecurity {
  /// タイミング攻撃を避けるため，長さ・内容を定数時間で比較する．
  public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let ab = Array(a.utf8), bb = Array(b.utf8)
    guard ab.count == bb.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
    return diff == 0
  }

  /// 連続失敗 `failCount` 回に対するロックアウト秒数．`maxAttempts` 未満なら nil（ロックしない）．
  /// しきい値到達後は 30s → 60s → 120s … と倍増し，最大 1 時間でキャップする．
  public static func lockoutDelay(failCount: Int, maxAttempts: Int = 5) -> TimeInterval? {
    guard failCount >= maxAttempts else { return nil }
    let over = failCount - maxAttempts
    return min(3600.0, 30.0 * pow(2.0, Double(over)))
  }
}
