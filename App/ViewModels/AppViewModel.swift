import Combine
import Foundation

/// アプリ全体で共有する機能別ViewModelを生成し，画面遷移を管理します．
///
/// 各機能のViewModelはこの型が所有し，View側で直接生成しません．
/// 子ViewModelの変更は`ContentView`へ転送し，従来と同じ更新タイミングを保ちます．
@MainActor
final class AppViewModel: ObservableObject {
  @Published var selection: NavigationSelection? = .home

  let dataManager: LibraryViewModel
  let webServerManager: ServerViewModel
  let playbackCoordinator: PlaybackCoordinator
  let appSettings: AppSettings

  private var cancellables = Set<AnyCancellable>()

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

    forwardChildChanges()
  }

  private func forwardChildChanges() {
    dataManager.objectWillChange
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)

    webServerManager.objectWillChange
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)

    playbackCoordinator.objectWillChange
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)

    appSettings.objectWillChange
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)
  }
}
