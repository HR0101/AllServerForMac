import Foundation

/// アプリが使用しているストレージ容量の内訳を表すModelです．
struct StorageUsage: Equatable {
  let videosSize: Int64
  let proxiesSize: Int64
  let downloadsSize: Int64
  let appTotalSize: Int64

  static let zero = StorageUsage(
    videosSize: 0,
    proxiesSize: 0,
    downloadsSize: 0,
    appTotalSize: 0
  )
}
