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
        case .single, .multi, .variantSwitch, .slideshow, .splitPlay: return true
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
    func playSingle(playlist: [VideoItem], current: VideoItem) {
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
        let shuffled = videos.filter { $0.mediaType == .video }.shuffled()
        guard let first = shuffled.first else { return }
        isMiniPlayerActive = false
        mode = .single(playlist: shuffled, current: first)
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
