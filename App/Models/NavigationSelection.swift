import Foundation

/// サイドバーで選択できる画面を表すアプリ層のModelです．
enum NavigationSelection: Hashable {
  case home
  case favorites
  case trash
  case album(UUID)
}
