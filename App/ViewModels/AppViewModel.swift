import Combine
import Foundation

/// アプリ全体で共有する機能別ViewModelを生成し，画面遷移を管理します．
///
/// 各機能のViewModelはこの型が所有し，View側で直接生成しません．
/// 子ViewModelは必要なViewが個別に監視し，ルート画面への一括通知は行いません．
@MainActor
final class AppViewModel: ObservableObject {
  @Published var selection: NavigationSelection? = .home

  let dataManager: LibraryViewModel
  let webServerManager: ServerViewModel
  let playbackCoordinator: PlaybackCoordinator
  let appSettings: AppSettings

  convenience init() {
    self.init(
      dataManager: LibraryViewModel(),
      playbackCoordinator: PlaybackCoordinator(),
      appSettings: AppSettings()
    )
  }

  init(
    dataManager: LibraryViewModel,
    playbackCoordinator: PlaybackCoordinator,
    appSettings: AppSettings
  ) {
    self.dataManager = dataManager
    self.webServerManager = ServerViewModel(dataManager: dataManager)
    self.playbackCoordinator = playbackCoordinator
    self.appSettings = appSettings
  }
}
