import Combine
import Foundation

/// ストレージ管理画面の状態と操作を提供するViewModelです．
@MainActor
final class StorageViewModel: ObservableObject {
  @Published private(set) var usage: StorageUsage = .zero
  @Published private(set) var isOptimizing = false
  @Published private(set) var optimizationMessage = ""
  @Published var isShowingResultAlert = false
  @Published private(set) var resultMessage = ""

  private let libraryViewModel: LibraryViewModel
  private var refreshTask: Task<Void, Never>?
  private var optimizationTask: Task<Void, Never>?

  init(libraryViewModel: LibraryViewModel) {
    self.libraryViewModel = libraryViewModel
  }

  func refreshUsage() {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      guard let self else { return }
      let sizes = await libraryViewModel.getStorageUsage()
      guard !Task.isCancelled else { return }
      usage = StorageUsage(
        videosSize: sizes.videosSize,
        proxiesSize: sizes.proxiesSize,
        downloadsSize: sizes.downloadsSize,
        appTotalSize: sizes.appTotalSize
      )
    }
  }

  func cleanupMissingFiles() {
    let count = libraryViewModel.cleanupMissingFiles()
    optimizationMessage = "ファイルが見つからないメディアを \(count) 件削除しました．"
    isOptimizing = true

    optimizationTask?.cancel()
    optimizationTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      self?.isOptimizing = false
      self?.refreshUsage()
    }
  }

  func removeDuplicates() {
    optimizationTask?.cancel()
    isOptimizing = true
    optimizationMessage = "重複しているメディアを解析し，ゴミ箱へ移動しています..."

    optimizationTask = Task { [weak self] in
      guard let self else { return }
      let removedCount = await libraryViewModel.removeDuplicateVideos()
      guard !Task.isCancelled else { return }

      isOptimizing = false
      resultMessage = "\(removedCount) 件の重複メディアを検知し，ゴミ箱へ移動しました．"
      isShowingResultAlert = true
      refreshUsage()
    }
  }

  func openDataFolder() {
    libraryViewModel.openAppRootFolderInFinder()
  }

  func openTemporaryFolder() {
    libraryViewModel.openTempFolderInFinder()
  }

  func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}
