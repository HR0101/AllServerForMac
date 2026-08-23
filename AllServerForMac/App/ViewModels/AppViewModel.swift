import Combine
import Foundation

/// アプリ全体で共有する機能別ViewModelを生成し，画面遷移を管理します．
///
/// 各機能のViewModelはこの型が所有し，View側で直接生成しません．
/// 子ViewModelは必要なViewが個別に監視し，ルート画面への一括通知は行いません．
@MainActor
final class AppViewModel: ObservableObject {
  @Published var selection: NavigationSelection? = .home
  @Published var isShowingPreferences = false
  @Published var isShowingStorageManager = false
  @Published var isShowingAccessLog = false
  @Published private(set) var isServerRunning = false
  @Published private(set) var currentServerURL: String?

  let dataManager: LibraryViewModel
  /// 差分動画の探索結果。再生でライブラリ画面ごと差し替わっても、
  /// 見つけたグループと選んだ組み合わせを持ち越せるようここが持つ。
  let variantFinder = VariantVideoViewModel()
  let webServerManager: ServerViewModel
  let playbackCoordinator: PlaybackCoordinator
  let remotePlaybackSession: RemotePlaybackSession
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
    self.playbackCoordinator = playbackCoordinator
    let remotePlaybackSession = RemotePlaybackSession(
      playbackCoordinator: playbackCoordinator
    )
    self.remotePlaybackSession = remotePlaybackSession
    self.webServerManager = ServerViewModel(
      dataManager: dataManager,
      remotePlaybackSession: remotePlaybackSession
    )
    self.appSettings = appSettings

    webServerManager.$serverStartTime
      .map { $0 != nil }
      .removeDuplicates()
      .assign(to: &$isServerRunning)

    webServerManager.$serverURL
      .removeDuplicates()
      .assign(to: &$currentServerURL)
  }
}
