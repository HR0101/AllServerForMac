import Combine
import Foundation

enum VariantPlaybackAlignmentMode: Equatable {
  case sameTime
  case content
}

// MARK: - Playback coordinator
//
// 元アプリ同様、再生中はウィンドウ全体をプレイヤーに差し替える（シートではなく全画面）。
// どのモードを表示中かを一元管理し、各プレイヤーは close() で元のライブラリ画面へ戻る。
@MainActor
final class PlaybackCoordinator: ObservableObject {
    enum LibraryScope: Equatable {
        case album(UUID)
        case favorites
        case continueWatching
        case history
        case trash
    }

    struct LibraryReturnState {
        let scope: LibraryScope
        let selectedMediaIDs: Set<UUID>
        let focusedMediaID: UUID?
        let selectionAnchorMediaID: UUID?
        let scrollTargetMediaID: UUID?
        let searchText: String
    }

    enum Mode: Equatable {
        case single(playlist: [VideoItem], current: VideoItem)
        case tour(PlaybackTourSession)
        case multi([VideoItem])
        case variantSwitch([VideoItem], alignment: VariantPlaybackAlignmentMode)
        case slideshow([VideoItem])
        case splitPlay(video: VideoItem, splitCount: Int)
        case photos(playlist: [VideoItem], current: VideoItem)
    }

    @Published var mode: Mode? {
        didSet {
            // 新しいプレイヤーは再生状態から始まる。前のプレイヤーの一時停止を持ち越さない。
            isActivePlayerPlaying = true
            refreshSleepBlocker()
        }
    }
    private(set) var singleStartTime: Double?
    @Published private(set) var libraryReturnState: LibraryReturnState?
    /// 通常再生をIキーで右下に小さくたたみ、アルバム一覧を裏に表示している間 true。
    @Published var isMiniPlayerActive = false
    /// 「差分動画を探す」を出しているアルバム。出していなければ nil。
    /// 差分再生中も探索画面そのものを背後に残すため、再生中もここは立てたままにする。
    @Published private(set) var variantFinderAlbumID: UUID?
    /// 探索を開いた時点の表示順。実体は ContentView が現在のライブラリから引き直すので、
    /// 再生中に削除した動画は背後の探索画面にも反映される。
    @Published private(set) var variantFinderItemIDs: [UUID] = []
    /// 探索画面を開いたときに最初に表示する検索方式．
    @Published private(set) var variantFinderAlignmentMode: VariantPlaybackAlignmentMode = .sameTime

    /// 一覧を開いたときのウィンドウの大きさ。探索オーバーレイをそこへ合わせるために控える。
    var variantFinderHostSize: CGSize?

    var isPresenting: Bool { mode != nil }

    // MARK: - 再生中のスリープ抑止

    private let sleepBlocker = ScreenSleepBlocker(reason: "動画を再生中です")
    /// いま開いているプレイヤーが実際に再生中か。プレイヤー側から setPlaybackActive で伝える。
    private var isActivePlayerPlaying = true

    /// 写真ビューアは自動で進まないので、開いているだけで画面を起こし続けない。
    /// それ以外（通常再生・同時再生・差分切り替え・スライドショー・分割再生）は
    /// 無操作でも映像が流れ続けるため、抑止の対象にする。
    private static func blocksSleep(_ mode: Mode?) -> Bool {
        switch mode {
        case .none, .photos: return false
        case .single, .tour, .multi, .variantSwitch, .slideshow, .splitPlay: return true
        }
    }

    /// プレイヤーの再生／一時停止に追従させる。一時停止したまま離席したときに
    /// 画面が点きっぱなしにならないよう、再生していない間は抑止を解く。
    func setPlaybackActive(_ playing: Bool) {
        guard isActivePlayerPlaying != playing else { return }
        isActivePlayerPlaying = playing
        refreshSleepBlocker()
    }

    private func refreshSleepBlocker() {
        sleepBlocker.setActive(Self.blocksSleep(mode) && isActivePlayerPlaying)
    }

    var isPlayingOverVariantFinder: Bool {
        guard variantFinderAlbumID != nil else { return false }
        if case .variantSwitch = mode { return true }
        return false
    }

    func openVariantFinder(
        albumID: UUID,
        itemIDs: [UUID],
        hostSize: CGSize?,
        alignmentMode: VariantPlaybackAlignmentMode = .sameTime
    ) {
        variantFinderHostSize = hostSize ?? variantFinderHostSize
        variantFinderItemIDs = itemIDs
        variantFinderAlignmentMode = alignmentMode
        variantFinderAlbumID = albumID
    }

    func closeVariantFinder() {
        variantFinderAlbumID = nil
        variantFinderItemIDs = []
        variantFinderAlignmentMode = .sameTime
        variantFinderHostSize = nil
    }

    /// 通常再生（再生リスト＋開始位置を指定）
    func playSingle(playlist: [VideoItem], current: VideoItem, startAt: Double? = nil) {
        singleStartTime = startAt
        let videos = playlist.filter { $0.mediaType == .video }
        let start = (videos.contains(current) ? current : videos.first) ?? current
        isMiniPlayerActive = false
        mode = .single(playlist: videos.isEmpty ? [current] : videos, current: start)
    }

    /// 表示中リストをシャッフルしてランダム再生
    func playRandom(from videos: [VideoItem]) {
        // 差分一覧はライブラリ上のオーバーレイなので，背後に残ったRキーや
        // ツールバーの操作で通常プレイヤーを重ねない．
        guard variantFinderAlbumID == nil else { return }
        singleStartTime = nil
        let shuffled = videos.filter { $0.mediaType == .video }.shuffled()
        guard let first = shuffled.first else { return }
        isMiniPlayerActive = false
        mode = .single(playlist: shuffled, current: first)
    }

    func startTour(_ session: PlaybackTourSession) {
      guard !session.entries.isEmpty, variantFinderAlbumID == nil else { return }
      isMiniPlayerActive = false
      mode = .tour(session)
    }

    /// 同時同期再生（2〜9本、9本超は先頭9本）
    func playMulti(_ videos: [VideoItem]) {
        let items = videos.filter { $0.mediaType == .video }
        guard items.count >= 2 else { return }
        mode = .multi(Array(items.prefix(9)))
    }

    /// 差分切り替え再生（2〜9本）。全部を同期で走らせたまま、見せる1本だけを差し替える。
    /// 本数ぶん同時にデコードし続けるので、同時再生と同じく9本を上限にする。
    ///
    /// 一覧から開始した場合も含め、ウィンドウ全体を占有して再生する。
    /// 探索画面から始めた場合は ContentView がその画面を背後に残し、プレイヤーだけを上へ重ねる。
    func playVariantSwitch(_ videos: [VideoItem]) {
        let items = videos.filter { $0.mediaType == .video }
        guard items.count >= 2 else { return }
        isMiniPlayerActive = false
        mode = .variantSwitch(Array(items.prefix(9)), alignment: .sameTime)
    }

    /// 尺が異なる動画の共通場面を探し，動画ごとの開始位置を補正して差分再生する．
    func playContentAlignedVariantSwitch(_ videos: [VideoItem]) {
        let items = videos.filter { $0.mediaType == .video }
        guard items.count >= 2 else { return }
        isMiniPlayerActive = false
        mode = .variantSwitch(Array(items.prefix(9)), alignment: .content)
    }

    /// スライドショー（2本以上）
    func startSlideshow(_ videos: [VideoItem]) {
        let items = videos.filter { $0.mediaType == .video }
        guard items.count >= 2 else { return }
        mode = .slideshow(items)
    }

    /// 分割再生（1本の動画をN分割してグリッドで同期再生）
    func playSplit(video: VideoItem, splitCount: Int) {
        guard video.mediaType == .video else { return }
        mode = .splitPlay(video: video, splitCount: min(max(splitCount, 2), 9))
    }

    /// 画像をウィンドウ全体で表示（動画の全画面再生に相当）
    func viewPhotos(playlist: [VideoItem], current: VideoItem) {
        let photos = playlist.filter { $0.mediaType == .photo }
        let start = (photos.contains(current) ? current : photos.first) ?? current
        mode = .photos(playlist: photos.isEmpty ? [current] : photos, current: start)
    }

    func close() {
        mode = nil
        isMiniPlayerActive = false
    }

    /// プレイヤーを閉じたあとに一覧の選択状態と表示位置を復元できるよう記録する。
    func rememberLibraryState(_ state: LibraryReturnState) {
        libraryReturnState = state
    }

    /// 全画面の画像ビューア内で表示対象が変わった場合，戻り先の選択だけを追従させる。
    func updateLibraryReturnSelection(mediaID: UUID) {
        guard let state = libraryReturnState else { return }
        libraryReturnState = LibraryReturnState(
            scope: state.scope,
            selectedMediaIDs: [mediaID],
            focusedMediaID: mediaID,
            selectionAnchorMediaID: mediaID,
            scrollTargetMediaID: state.scrollTargetMediaID,
            searchText: state.searchText
        )
    }

    /// 一覧側で復帰処理を終えたら呼ぶ。
    func clearLibraryReturnState() {
        libraryReturnState = nil
    }
}

// MARK: - 区間を一巡する再生リスト

struct PlaybackTourEntry: Identifiable, Equatable {
  let id: UUID
  let video: VideoItem
  let start: Double
  let end: Double
}

struct PlaybackTourSession: Identifiable, Equatable {
  enum Kind: Equatable {
    case preview
    case scenes
    case channels
    case mix(Mood)
    case timed
    case highlights
  }
  enum Mood: String, CaseIterable {
    case short = "短く楽しむ"
    case unseen = "未視聴を発掘"
    case favorites = "お気に入り中心"
  }
  struct Channel: Identifiable, Equatable {
    let id: UUID
    let name: String
    let videos: [VideoItem]
  }
  let id = UUID()
  let kind: Kind
  let entries: [PlaybackTourEntry]

  let channels: [Channel]
  let requestedSeconds: Double?

  var title: String {
    switch kind {
    case .preview: return "プレビュー巡回"
    case .scenes: return "シーンシャッフル"
    case .channels: return "マイチャンネル"
    case .mix(let mood): return mood.rawValue
    case .timed: return "時間ぴったり再生"
    case .highlights: return "ストックした場面"
    }
  }

  init(kind: Kind, entries: [PlaybackTourEntry], channels: [Channel] = [], requestedSeconds: Double? = nil) {
    self.kind = kind
    self.entries = entries
    self.channels = channels
    self.requestedSeconds = requestedSeconds
  }

  static func preview(videos: [VideoItem], seconds: Double) throws -> PlaybackTourSession {
    guard seconds.isFinite, seconds > 0 else { throw PlaybackTourError.invalidRange }
    let entries = eligibleVideos(videos).shuffled().map { video in
      let length = min(seconds, video.duration)
      let start = Double.random(in: 0...max(0, video.duration - length))
      return PlaybackTourEntry(id: UUID(), video: video, start: start, end: start + length)
    }
    guard !entries.isEmpty else { throw PlaybackTourError.noVideos }
    return PlaybackTourSession(kind: .preview, entries: entries)
  }

  static func scenes(videos: [VideoItem], urlForVideo: (VideoItem) -> URL?,
    defaults: UserDefaults = .standard) throws -> PlaybackTourSession {
    let saved = try AcceptedSceneStore.load(defaults: defaults)
    let entries = eligibleVideos(videos).flatMap { video -> [PlaybackTourEntry] in
      guard let url = urlForVideo(video) else { return [] }
      return (saved[AcceptedSceneStore.sourceKey(url)] ?? []).compactMap { candidate in
        guard candidate.userLabel == .accepted,
              candidate.startTime.isFinite, candidate.endTime.isFinite else { return nil }
        let start = max(0, candidate.startTime)
        let end = min(video.duration, candidate.endTime)
        guard end > start else { return nil }
        return PlaybackTourEntry(id: UUID(), video: video, start: start, end: end)
      }
    }.shuffled()
    guard !entries.isEmpty else { throw PlaybackTourError.noScenes }
    return PlaybackTourSession(kind: .scenes, entries: entries)
  }

  static func channelSession(albums: [Album], videos: [VideoItem]) throws -> PlaybackTourSession {
    let byID = Dictionary(eligibleVideos(videos).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let channels = albums.filter {
      $0.name != LibraryViewModel.allVideosAlbumName && $0.name != LibraryViewModel.allPhotosAlbumName
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.compactMap { album -> Channel? in
      let items = album.videoIDs.compactMap { byID[$0] }
      return items.isEmpty ? nil : Channel(id: album.id, name: album.name, videos: items)
    }
    let entries = channels.compactMap { channel -> PlaybackTourEntry? in
      guard let video = channel.videos.randomElement() else { return nil }
      let start = Double.random(in: 0...max(0, video.duration - min(15, video.duration)))
      return PlaybackTourEntry(id: UUID(), video: video, start: start, end: video.duration)
    }
    guard !entries.isEmpty else { throw PlaybackTourError.noChannels }
    return PlaybackTourSession(kind: .channels, entries: entries, channels: channels)
  }

  static func mix(videos: [VideoItem], mood: Mood, seenIDs: Set<UUID>) throws -> PlaybackTourSession {
    let available = eligibleVideos(videos)
    let items: [VideoItem]
    switch mood {
    case .short: items = available.filter { $0.duration <= 180 }
    case .unseen: items = available.filter { !seenIDs.contains($0.id) }
    case .favorites: items = available.filter(\.isFavorite)
    }
    guard !items.isEmpty else { throw PlaybackTourError.noMoodMatches }
    let preview = try preview(videos: items, seconds: mood == .short ? 30 : 60)
    return PlaybackTourSession(kind: .mix(mood), entries: preview.entries)
  }

  /// 同じ動画を一巡したら再利用し，最後の区間だけを短くして合計時間を合わせます．
  static func timed(videos: [VideoItem], seconds: Double) throws -> PlaybackTourSession {
    let minimumDuration = 0.5
    let maximumSeconds = 3600.0
    let items = eligibleVideos(videos).filter { $0.duration >= minimumDuration }.shuffled()
    guard !items.isEmpty else { throw PlaybackTourError.noVideos }
    guard seconds.isFinite, seconds > 0, seconds <= maximumSeconds else { throw PlaybackTourError.invalidRange }
    var entries: [PlaybackTourEntry] = []
    var remaining = seconds
    var cursor = 0
    while remaining > 0.000001 {
      let video = items[cursor % items.count]
      let length = min(video.duration, remaining)
      entries.append(PlaybackTourEntry(id: UUID(), video: video, start: 0, end: length))
      remaining -= length
      cursor += 1
    }
    return PlaybackTourSession(kind: .timed, entries: entries, requestedSeconds: seconds)
  }

  static func highlights(videos: [VideoItem], urlForVideo: (VideoItem) -> URL?,
    defaults: UserDefaults = .standard) throws -> PlaybackTourSession {
    let stored = try AcceptedSceneStore.load(defaults: defaults, key: HighlightStore.defaultsKey)
    let entries = eligibleVideos(videos).flatMap { video -> [PlaybackTourEntry] in
      guard let url = urlForVideo(video) else { return [] }
      return (stored[AcceptedSceneStore.sourceKey(url)] ?? []).compactMap { scene in
        let start = max(0, scene.startTime)
        let end = min(video.duration, scene.endTime)
        guard start.isFinite, end.isFinite, end > start else { return nil }
        return PlaybackTourEntry(id: UUID(), video: video, start: start, end: end)
      }
    }.shuffled()
    guard !entries.isEmpty else { throw PlaybackTourError.noHighlights }
    return PlaybackTourSession(kind: .highlights, entries: entries)
  }

  private static func eligibleVideos(_ videos: [VideoItem]) -> [VideoItem] {
    var seen = Set<UUID>()
    return videos.filter {
      $0.mediaType == .video && !$0.isInTrash && $0.duration.isFinite && $0.duration > 0
        && seen.insert($0.id).inserted
    }
  }
}

enum PlaybackTourError: LocalizedError {
  case noVideos
  case noChannels
  case noMoodMatches
  case noHighlights
  case noScenes
  case invalidRange
  case missingFile
  case unplayable

  var errorDescription: String? {
    switch self {
    case .noChannels: return "動画を含むアルバムがありません．アルバムに動画を追加してください．"
    case .noMoodMatches: return "この気分に合う動画がありません．3分以内の動画・未視聴・お気に入りの条件や，表示中の一覧を確認してください．"
    case .noHighlights: return "ストックした場面がありません．再生中に「場面を保存」を押してください．"
    case .noVideos: return "再生時間が分かる動画がありません．動画を含む一覧から開始してください．"
    case .noScenes: return "採用済みのシーンがありません．動画の「シーン抽出」で区間を採用してから，もう一度開始してください．"
    case .invalidRange: return "有効な再生区間がありません．シーンの開始・終了位置を確認してください．"
    case .missingFile: return "元の動画が見つかりません．保存先を接続するか，次の項目へ進んでください．"
    case .unplayable: return "この動画を再生できません．ファイル形式を確認するか，次の項目へ進んでください．"
    }
  }
}
