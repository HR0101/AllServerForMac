import Combine
import Foundation

// MARK: - 差分切り替え再生のリモコン（iPhone から Mac を操作する）
//
// 通常再生の `RemotePlaybackSession` と同じ形。違うのは「いま何本の差分を抱えていて、
// そのどれを見せているか」を持ち帰るところで、リモコン側はその一覧から1本を選ぶ。
//
// 差分を何本も同時にデコードするのは Mac の仕事なので、本数の上限は Mac 側（9本）のまま。
// iPhone で同じことをすると帯域とデコーダが足りないため、iPhone 内で完結する
// `RemoteVariantPlayerViewModel` のほうは 4 本に絞ってある。Mac へ飛ばすぶんにはその制約がない。

struct RemoteVariantSnapshot: Codable, Sendable {
  struct Item: Codable, Sendable {
    let id: String
    let title: String
  }

  let isAvailable: Bool
  let variants: [Item]
  /// いま Mac の画面に出ている差分の番号。
  let activeIndex: Int
  let currentTime: Double
  let duration: Double
  let isPlaying: Bool
  let hasReachedEnd: Bool
  let isAutoSwitching: Bool
  /// 次の自動切り替えまでの残り秒。リモコン側のカウントダウンにそのまま使う。
  let secondsUntilSwitch: Double
  let minInterval: Double
  let maxInterval: Double
  let avoidsImmediateRepeat: Bool
  let volume: Double
  let isMuted: Bool

  nonisolated static let idle = RemoteVariantSnapshot(
    isAvailable: false,
    variants: [],
    activeIndex: 0,
    currentTime: 0,
    duration: 0,
    isPlaying: false,
    hasReachedEnd: false,
    isAutoSwitching: false,
    secondsUntilSwitch: 0,
    minInterval: 0,
    maxInterval: 0,
    avoidsImmediateRepeat: true,
    volume: 1,
    isMuted: false
  )
}

enum RemoteVariantAction: String, Codable, Sendable {
  case play
  case pause
  case togglePlayback
  case seekTo
  case seekBy
  /// `value` に差分の番号（0 始まり）。
  case showVariant
  case nextVariant
  case previousVariant
  case randomVariant
  /// `value` が 0 以外なら自動切り替えを入れる。
  case setAutoSwitching
  case setMinInterval
  case setMaxInterval
  case setAvoidsImmediateRepeat
  case setVolume
  case toggleMute
  case close
}

struct RemoteVariantCommandRequest: Codable, Sendable {
  let action: RemoteVariantAction
  let value: Double?
}

struct RemoteVariantOpenRequest: Codable, Sendable {
  /// 重ねて走らせる差分の並び。先頭が最初に見える1本になる。
  let videoIDs: [String]
}

@MainActor
final class RemoteVariantSession: ObservableObject {
  nonisolated let snapshot = LockedBox(RemoteVariantSnapshot.idle)

  private weak var activeViewModel: VariantSwitchPlayerViewModel?
  private weak var playbackCoordinator: PlaybackCoordinator?
  private var subscriptions = Set<AnyCancellable>()

  init(playbackCoordinator: PlaybackCoordinator) {
    self.playbackCoordinator = playbackCoordinator
  }

  func attach(_ viewModel: VariantSwitchPlayerViewModel) {
    activeViewModel = viewModel
    subscriptions.removeAll()

    // カウントダウンは 0.1 秒ごとに動く。リモコンの残り秒表示がそれに追従できるよう、
    // ここでも素直に拾っておく（書き込むのはロック付きの箱ひとつなので安い）。
    viewModel.$variants
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$activeIndex
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$commonCurrentTime
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$commonDuration
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$isPlaying
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$hasReachedEnd
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$secondsUntilSwitch
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$isAutoSwitching
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$minInterval
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$maxInterval
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$avoidsImmediateRepeat
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$volume
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$isMuted
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)

    refreshSnapshot()
  }

  func detach(_ viewModel: VariantSwitchPlayerViewModel) {
    guard activeViewModel === viewModel else { return }
    subscriptions.removeAll()
    activeViewModel = nil
    snapshot.value = .idle
  }

  /// iPhone から渡された差分を Mac の全画面で走らせる。
  func open(videos: [VideoItem]) {
    playbackCoordinator?.playVariantSwitch(videos)
  }

  @discardableResult
  func perform(_ request: RemoteVariantCommandRequest) -> Bool {
    guard let viewModel = activeViewModel else { return false }

    switch request.action {
    case .play:
      if !viewModel.isPlaying { viewModel.togglePlayPause() }
    case .pause:
      if viewModel.isPlaying { viewModel.togglePlayPause() }
    case .togglePlayback:
      viewModel.togglePlayPause()
    case .seekTo:
      guard let value = request.value, value.isFinite, viewModel.commonDuration > 0 else {
        return false
      }
      // スライダーと同じ経路を通す（割合で渡すと全プレイヤーが同じ位置へ揃う）。
      viewModel.commonCurrentTime = min(max(value, 0), viewModel.commonDuration)
      viewModel.sliderEditingChanged(isEditing: false)
    case .seekBy:
      guard let value = request.value, value.isFinite else { return false }
      viewModel.seek(by: value)
    case .showVariant:
      guard let value = request.value, value.isFinite else { return false }
      let index = Int(value)
      guard viewModel.variants.indices.contains(index) else { return false }
      viewModel.showVariant(at: index)
    case .nextVariant:
      guard viewModel.variantCount > 1 else { return false }
      viewModel.showNextVariant()
    case .previousVariant:
      guard viewModel.variantCount > 1 else { return false }
      viewModel.showPreviousVariant()
    case .randomVariant:
      guard viewModel.variantCount > 1 else { return false }
      viewModel.showRandomVariant()
    case .setAutoSwitching:
      guard let value = request.value else { return false }
      viewModel.isAutoSwitching = value != 0
    case .setMinInterval:
      guard let value = request.value, value.isFinite else { return false }
      viewModel.setMinInterval(value)
    case .setMaxInterval:
      guard let value = request.value, value.isFinite else { return false }
      viewModel.setMaxInterval(value)
    case .setAvoidsImmediateRepeat:
      guard let value = request.value else { return false }
      viewModel.avoidsImmediateRepeat = value != 0
    case .setVolume:
      guard let value = request.value, value.isFinite else { return false }
      viewModel.volume = Float(min(max(value, 0), 1))
    case .toggleMute:
      viewModel.isMuted.toggle()
    case .close:
      playbackCoordinator?.close()
    }

    refreshSnapshot()
    return true
  }

  private func refreshSnapshot() {
    guard let viewModel = activeViewModel else {
      snapshot.value = .idle
      return
    }

    snapshot.value = RemoteVariantSnapshot(
      isAvailable: !viewModel.variants.isEmpty,
      variants: viewModel.variants.map { variant in
        RemoteVariantSnapshot.Item(
          id: variant.id.uuidString,
          title: URL(fileURLWithPath: variant.title)
            .deletingPathExtension()
            .lastPathComponent
        )
      },
      activeIndex: viewModel.activeIndex,
      currentTime: viewModel.commonCurrentTime,
      duration: viewModel.commonDuration,
      isPlaying: viewModel.isPlaying,
      hasReachedEnd: viewModel.hasReachedEnd,
      isAutoSwitching: viewModel.isAutoSwitching,
      secondsUntilSwitch: viewModel.secondsUntilSwitch,
      minInterval: viewModel.minInterval,
      maxInterval: viewModel.maxInterval,
      avoidsImmediateRepeat: viewModel.avoidsImmediateRepeat,
      volume: Double(viewModel.volume),
      isMuted: viewModel.isMuted
    )
  }
}
