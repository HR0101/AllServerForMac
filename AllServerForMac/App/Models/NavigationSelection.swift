import Foundation

/// サイドバーで選択できる画面を表すアプリ層のModelです．
enum NavigationSelection: Hashable {
  case home
  case favorites
  case history
  case trash
  case album(UUID)
  /// アルバム名の "/" 区切りで表現されるフォルダ。実体を持たないためIDではなく
  /// パス文字列で指す。動画ツリーと画像ツリーは別建てで同名フォルダが両立しうるので、
  /// どちらのツリーのフォルダかを isPhoto で区別する。
  case folder(path: String, isPhoto: Bool)
}
