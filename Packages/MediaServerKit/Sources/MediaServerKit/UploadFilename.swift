import Foundation

/// アップロードファイル名の安全化．パストラバーサルと非メディアファイルの書き込みを防ぐ．
public enum UploadFilename {
  /// アップロードを許可するメディア拡張子
  public static let defaultAllowedExtensions: Set<String> = [
    "mp4", "mov", "m4v", "avi", "jpg", "jpeg", "png", "heic", "webp", "gif", "tiff"
  ]

  /// パス区切りを除去し，メディア拡張子のみ許可する．
  /// 不正（空・"."/".."・隠しファイル・非許可拡張子）の場合は nil を返す．
  public static func sanitize(
    _ raw: String,
    allowedExtensions: Set<String> = defaultAllowedExtensions
  ) -> String? {
    var name = (raw as NSString).lastPathComponent
    name = name.replacingOccurrences(of: "/", with: "")
      .replacingOccurrences(of: "\\", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix(".") else { return nil }
    if name.count > 255 { name = String(name.suffix(255)) }
    let ext = (name as NSString).pathExtension.lowercased()
    guard allowedExtensions.contains(ext) else { return nil }
    return name
  }
}
