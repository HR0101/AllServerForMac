import Foundation

/// サイドバーで選択できる画面を表すアプリ層のModelです．
enum NavigationSelection: Hashable {
  case home
  case favorites
  /// 途中でやめた動画だけを、最後に再生した順に並べる画面。
  /// ブラウザ UI の「続きを見る」タブと同じ中身（保管庫が `/sync` で共有されているため）。
  case continueWatching
  case history
  case trash
  case sceneExtraction
  case album(UUID)
  /// アルバム名の "/" 区切りで表現されるフォルダ。実体を持たないためIDではなく
  /// パス文字列で指す。動画ツリーと画像ツリーは別建てで同名フォルダが両立しうるので、
  /// どちらのツリーのフォルダかを isPhoto で区別する。
  case folder(path: String, isPhoto: Bool)
}
