import Combine
import Foundation

struct RemotePlaybackSnapshot: Codable, Sendable {
  let isAvailable: Bool
  let videoID: String?
  let title: String?
  let currentTime: Double
  let duration: Double
  let isPlaying: Bool
  let volume: Double
  let isMuted: Bool
  let canPlayPrevious: Bool
  let canPlayNext: Bool

  nonisolated static let idle = RemotePlaybackSnapshot(
    isAvailable: false,
    videoID: nil,
    title: nil,
    currentTime: 0,
    duration: 0,
    isPlaying: false,
    volume: 1,
    isMuted: false,
    canPlayPrevious: false,
    canPlayNext: false
  )
}

enum RemotePlaybackAction: String, Codable, Sendable {
  case play
  case pause
  case togglePlayback
  case seekTo
  case seekBy
  case previous
  case next
  case setVolume
  case toggleMute
  case close
}

struct RemotePlaybackCommandRequest: Codable, Sendable {
  let action: RemotePlaybackAction
  let value: Double?
}

struct RemotePlaybackOpenRequest: Codable, Sendable {
  let videoID: String
  let albumID: String?
}

@MainActor
final class RemotePlaybackSession: ObservableObject {
  nonisolated let snapshot = LockedBox(RemotePlaybackSnapshot.idle)

  private weak var activeViewModel: VideoPlayerViewModel?
  private weak var playbackCoordinator: PlaybackCoordinator?
  private var subscriptions = Set<AnyCancellable>()

  init(playbackCoordinator: PlaybackCoordinator) {
    self.playbackCoordinator = playbackCoordinator
  }

  func attach(_ viewModel: VideoPlayerViewModel) {
    activeViewModel = viewModel
    subscriptions.removeAll()

    viewModel.$currentVideo
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$currentTime
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$duration
      .sink { [weak self] _ in self?.refreshSnapshot() }
      .store(in: &subscriptions)
    viewModel.$isPlaybackPlaying
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

  func detach(_ viewModel: VideoPlayerViewModel) {
    guard activeViewModel === viewModel else { return }
    subscriptions.removeAll()
    activeViewModel = nil
    snapshot.value = .idle
  }

  func open(playlist: [VideoItem], current: VideoItem) {
    playbackCoordinator?.playSingle(playlist: playlist, current: current)
  }

  @discardableResult
  func perform(_ request: RemotePlaybackCommandRequest) -> Bool {
    guard let viewModel = activeViewModel else { return false }

    switch request.action {
    case .play:
      viewModel.play()
    case .pause:
      viewModel.pause()
    case .togglePlayback:
      viewModel.playPause()
    case .seekTo:
      guard let value = request.value, value.isFinite else { return false }
      viewModel.seek(toSeconds: value)
    case .seekBy:
      guard let value = request.value, value.isFinite else { return false }
      viewModel.seek(by: value)
    case .previous:
      guard viewModel.canPlayPreviousVideo else { return false }
      viewModel.playPreviousVideo()
    case .next:
      guard viewModel.canPlayNextVideo else { return false }
      viewModel.playNextVideo()
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

    let filename = viewModel.currentVideo.originalFilename
    let title = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    snapshot.value = RemotePlaybackSnapshot(
      isAvailable: true,
      videoID: viewModel.currentVideo.id.uuidString,
      title: title,
      currentTime: viewModel.currentTime,
      duration: viewModel.duration,
      isPlaying: viewModel.isPlaybackPlaying,
      volume: Double(viewModel.volume),
      isMuted: viewModel.isMuted,
      canPlayPrevious: viewModel.canPlayPreviousVideo,
      canPlayNext: viewModel.canPlayNextVideo
    )
  }
}
