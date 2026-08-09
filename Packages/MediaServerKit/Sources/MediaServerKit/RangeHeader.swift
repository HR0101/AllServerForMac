import Foundation

/// HTTP `Range` ヘッダの解析．動画シーク再生（206 Partial Content）で使う純粋関数．
public enum RangeHeader {
  /// `"bytes=start-end"` 形式を解析し，両端を含む `(start, end)` バイト範囲を返す．
  /// - end 省略時は末尾まで．end がサイズ超過なら末尾にクランプ．
  /// - 不正・反転・サイズ 0 の場合は nil．
  public static func parse(_ header: String, totalSize: UInt64) -> (UInt64, UInt64)? {
    guard header.hasPrefix("bytes="), totalSize > 0 else { return nil }
    let components = header.dropFirst(6).split(separator: "-")
    guard let startStr = components.first, let start = UInt64(startStr) else { return nil }
    let end = (components.count > 1 && !components[1].isEmpty)
      ? min(UInt64(components[1]) ?? 0, totalSize - 1)
      : totalSize - 1
    return start <= end ? (start, end) : nil
  }
}
