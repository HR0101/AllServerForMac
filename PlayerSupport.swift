import SwiftUI
import AVKit
import AVFoundation
import CoreMedia
import Combine

// MARK: - Playback coordinator
//
// 元アプリ同様、再生中はウィンドウ全体をプレイヤーに差し替える（シートではなく全画面）。
// どのモードを表示中かを一元管理し、各プレイヤーは close() で元のライブラリ画面へ戻る。
@MainActor
final class PlaybackCoordinator: ObservableObject {
    enum Mode: Equatable {
        case single(playlist: [VideoItem], current: VideoItem)
        case multi([VideoItem])
        case slideshow([VideoItem])
        case splitPlay(video: VideoItem, splitCount: Int)
        case photos(playlist: [VideoItem], current: VideoItem)
    }

    @Published var mode: Mode?
    @Published var returnToMediaID: UUID?

    var isPresenting: Bool { mode != nil }

    /// 通常再生（再生リスト＋開始位置を指定）
    func playSingle(playlist: [VideoItem], current: VideoItem) {
        let videos = playlist.filter { $0.mediaType == .video }
        let start = (videos.contains(current) ? current : videos.first) ?? current
        mode = .single(playlist: videos.isEmpty ? [current] : videos, current: start)
    }

    /// 表示中リストをシャッフルしてランダム再生
    func playRandom(from videos: [VideoItem]) {
        let shuffled = videos.filter { $0.mediaType == .video }.shuffled()
        guard let first = shuffled.first else { return }
        mode = .single(playlist: shuffled, current: first)
    }

    /// 同時同期再生（2〜9本、9本超は先頭9本）
    func playMulti(_ videos: [VideoItem]) {
        let items = videos.filter { $0.mediaType == .video }
        guard items.count >= 2 else { return }
        mode = .multi(Array(items.prefix(9)))
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

    func close() { mode = nil }

    /// プレイヤーを閉じたあとに一覧側で復帰させたい項目を記録する。
    func rememberReturnTarget(mediaID: UUID) {
        returnToMediaID = mediaID
    }

    /// 一覧側で復帰処理を終えたら呼ぶ。
    func clearReturnTarget() {
        returnToMediaID = nil
    }
}

// MARK: - AVKit-safe player surface
//
// SwiftUI の VideoPlayer は _AVKit_SwiftUI のみ参照され AVKit 本体がリンクされず
// 実行時クラッシュするため、各プレイヤーモードはこの AVPlayerView ラッパーを共有して使う。
struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer?
    // .inline は再生コントロール（シークバー）を画面最下部に沿って表示する。
    // .floating だと中央寄りに浮いて動画に被るため inline を既定にしている。
    var controlsStyle: AVPlayerViewControlsStyle = .inline
    var showsFullScreenToggleButton: Bool = true
    var allowsPictureInPicturePlayback: Bool = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = controlsStyle
        view.showsFullScreenToggleButton = showsFullScreenToggleButton
        view.allowsPictureInPicturePlayback = allowsPictureInPicturePlayback
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

// MARK: - プレイヤー共通UI（閉じる・ショートカットヘルプ）

/// プレイヤー画面の隅に重ねる「ヘルプ」「閉じる」ボタンの組。
/// 全プレイヤーで見た目と操作感を揃える。
struct PlayerCornerControls: View {
    @Binding var showShortcutHelp: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                showShortcutHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("キーボードショートカット一覧（?キー）")
            .accessibilityLabel("キーボードショートカット一覧")

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("閉じる（Esc）")
            .accessibilityLabel("プレイヤーを閉じる")
        }
        .padding()
    }
}

/// キーボードショートカットの一覧パネル。?キーまたはヘルプボタンで表示し、
/// クリックか Esc / ? で閉じる。
struct ShortcutHelpPanel: View {
    let title: String
    let shortcuts: [(key: String, action: String)]
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(title, systemImage: "keyboard")
                        .font(.headline)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("ヘルプを閉じる")
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, item in
                        GridRow {
                            Text(item.key)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .gridColumnAlignment(.trailing)
                            Text(item.action)
                                .font(.body)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 24)
        }
        .transition(.opacity)
    }
}

// MARK: - ユーザー設定可能なショートカット

/// プレイヤーで設定できるキー。修飾キーは使わず、単独キーだけを対象にする。
struct MediaShortcutKey: RawRepresentable, Hashable, Identifiable {
    let rawValue: String

    static let space = MediaShortcutKey(rawValue: "space")
    static let k = MediaShortcutKey(rawValue: "k")
    static let j = MediaShortcutKey(rawValue: "j")
    static let h = MediaShortcutKey(rawValue: "h")
    static let l = MediaShortcutKey(rawValue: "l")
    static let g = MediaShortcutKey(rawValue: "g")
    static let r = MediaShortcutKey(rawValue: "r")
    static let f = MediaShortcutKey(rawValue: "f")
    static let m = MediaShortcutKey(rawValue: "m")
    static let semicolon = MediaShortcutKey(rawValue: "semicolon")
    static let quote = MediaShortcutKey(rawValue: "quote")
    static let returnKey = MediaShortcutKey(rawValue: "return")
    static let leftArrow = MediaShortcutKey(rawValue: "leftArrow")
    static let rightArrow = MediaShortcutKey(rawValue: "rightArrow")
    static let upArrow = MediaShortcutKey(rawValue: "upArrow")
    static let downArrow = MediaShortcutKey(rawValue: "downArrow")
    static let delete = MediaShortcutKey(rawValue: "delete")

    var id: String { rawValue }

    var displayName: String {
        switch rawValue {
        case Self.space.rawValue: return "Space"
        case Self.semicolon.rawValue: return ";"
        case Self.quote.rawValue: return "'"
        case Self.returnKey.rawValue: return "Return"
        case Self.leftArrow.rawValue: return "←"
        case Self.rightArrow.rawValue: return "→"
        case Self.upArrow.rawValue: return "↑"
        case Self.downArrow.rawValue: return "↓"
        case Self.delete.rawValue: return "Delete"
        default:
            if rawValue.count == 1 {
                return rawValue.uppercased()
            }
            return rawValue
        }
    }

    func matches(_ press: KeyPress) -> Bool {
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) || press.modifiers.contains(.option) {
            return false
        }

        switch rawValue {
        case Self.space.rawValue: return press.key == .space
        case Self.semicolon.rawValue: return press.key == ";"
        case Self.quote.rawValue: return press.key == "'"
        case Self.returnKey.rawValue: return press.key == .return
        case Self.leftArrow.rawValue: return press.key == .leftArrow
        case Self.rightArrow.rawValue: return press.key == .rightArrow
        case Self.upArrow.rawValue: return press.key == .upArrow
        case Self.downArrow.rawValue: return press.key == .downArrow
        case Self.delete.rawValue: return press.key == "\u{7F}" || press.key == "\u{F728}"
        default:
            return String(press.key.character).lowercased() == rawValue
        }
    }

    static func captured(from press: KeyPress) -> MediaShortcutKey? {
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) || press.modifiers.contains(.option) {
            return nil
        }

        switch press.key {
        case .escape:
            return nil
        case .space:
            return .space
        case .return:
            return .returnKey
        case .leftArrow:
            return .leftArrow
        case .rightArrow:
            return .rightArrow
        case .upArrow:
            return .upArrow
        case .downArrow:
            return .downArrow
        case "\u{7F}", "\u{F728}":
            return .delete
        case ";":
            return .semicolon
        case "'":
            return .quote
        default:
            let rawValue = String(press.key.character).lowercased()
            guard rawValue.count == 1, rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return nil
            }
            return MediaShortcutKey(rawValue: rawValue)
        }
    }
}

enum MediaShortcutAction: String, CaseIterable, Identifiable {
    case videoPlayPause
    case videoPreviousItem
    case videoNextItem
    case videoSeekBack15
    case videoSeekBack10
    case videoSeekBack5
    case videoSeekForward5
    case videoSeekForward10
    case videoSeekForward15
    case videoRandomSeek
    case photoPrevious
    case photoNext
    case photoToggleMangaMode
    case photoDelete
    case photoClose
    case libraryOpenFocused
    case libraryMoveLeft
    case libraryMoveRight
    case libraryMoveUp
    case libraryMoveDown
    case libraryOpenExternal
    case libraryRevealInFinder
    case libraryToggleFavorite
    case libraryDelete
    case libraryMoveToTrash
    case libraryRestoreFromTrash
    case libraryExport
    case libraryImport
    case libraryRandomPlay
    case libraryMultiPlay
    case librarySlideshow
    case librarySplitPlay
    case libraryDuplicateCheck
    case libraryRemoveFromAlbum
    case libraryEmptyTrash

    var id: String { rawValue }

    var storageKey: String {
        "mediaShortcut.\(rawValue)"
    }

    var settingsTitle: String {
        switch self {
        case .videoPlayPause: return "動画: 再生・一時停止"
        case .videoPreviousItem: return "動画: 前の項目"
        case .videoNextItem: return "動画: 次の項目"
        case .videoSeekBack15: return "動画: 15秒戻る"
        case .videoSeekBack10: return "動画: 10秒戻る"
        case .videoSeekBack5: return "動画: 5秒戻る"
        case .videoSeekForward5: return "動画: 5秒進む"
        case .videoSeekForward10: return "動画: 10秒進む"
        case .videoSeekForward15: return "動画: 15秒進む"
        case .videoRandomSeek: return "動画: ランダム位置"
        case .photoPrevious: return "画像: 前の画像"
        case .photoNext: return "画像: 次の画像"
        case .photoToggleMangaMode: return "画像: 漫画モード切替"
        case .photoDelete: return "画像: 削除"
        case .photoClose: return "画像: 全画面表示／閉じる"
        case .libraryOpenFocused: return "一覧: 開く"
        case .libraryMoveLeft: return "一覧: 左へ移動"
        case .libraryMoveRight: return "一覧: 右へ移動"
        case .libraryMoveUp: return "一覧: 上へ移動"
        case .libraryMoveDown: return "一覧: 下へ移動"
        case .libraryOpenExternal: return "一覧: 外部アプリで開く"
        case .libraryRevealInFinder: return "一覧: Finderで表示"
        case .libraryToggleFavorite: return "一覧: お気に入り切替"
        case .libraryDelete: return "一覧: 削除"
        case .libraryMoveToTrash: return "一覧: ゴミ箱に入れる"
        case .libraryRestoreFromTrash: return "一覧: 元に戻す"
        case .libraryExport: return "一覧: エクスポート"
        case .libraryImport: return "一覧: インポート"
        case .libraryRandomPlay: return "一覧: ランダム再生"
        case .libraryMultiPlay: return "一覧: 同時再生"
        case .librarySlideshow: return "一覧: スライドショー"
        case .librarySplitPlay: return "一覧: 分割再生"
        case .libraryDuplicateCheck: return "一覧: 重複チェック"
        case .libraryRemoveFromAlbum: return "一覧: アルバムから外す"
        case .libraryEmptyTrash: return "一覧: ゴミ箱を空にする"
        }
    }

    var helpAction: String {
        switch self {
        case .videoPlayPause: return "再生・一時停止"
        case .videoPreviousItem: return "前の動画へ"
        case .videoNextItem: return "次の動画へ"
        case .videoSeekBack15: return "15秒戻る"
        case .videoSeekBack10: return "10秒戻る"
        case .videoSeekBack5: return "5秒戻る"
        case .videoSeekForward5: return "5秒進む"
        case .videoSeekForward10: return "10秒進む"
        case .videoSeekForward15: return "15秒進む"
        case .videoRandomSeek: return "ランダムな位置へジャンプ"
        case .photoPrevious: return "前の画像へ"
        case .photoNext: return "次の画像へ"
        case .photoToggleMangaMode: return "漫画モードを切り替え"
        case .photoDelete: return "現在の画像を削除"
        case .photoClose: return "全画面表示／画像ビューアを閉じる"
        case .libraryOpenFocused: return "選択中の動画・画像を開く"
        case .libraryMoveLeft: return "左の項目へ移動"
        case .libraryMoveRight: return "右の項目へ移動"
        case .libraryMoveUp: return "上の項目へ移動"
        case .libraryMoveDown: return "下の項目へ移動"
        case .libraryOpenExternal: return "外部アプリで開く"
        case .libraryRevealInFinder: return "Finderで表示"
        case .libraryToggleFavorite: return "お気に入りを切り替え"
        case .libraryDelete: return "削除方法を選ぶ"
        case .libraryMoveToTrash: return "ゴミ箱に入れる"
        case .libraryRestoreFromTrash: return "ゴミ箱から元に戻す"
        case .libraryExport: return "選択項目をエクスポート"
        case .libraryImport: return "ファイルをインポート"
        case .libraryRandomPlay: return "ランダム再生"
        case .libraryMultiPlay: return "選択動画を同時再生"
        case .librarySlideshow: return "選択動画でスライドショー"
        case .librarySplitPlay: return "選択動画を分割再生"
        case .libraryDuplicateCheck: return "重複チェックを実行"
        case .libraryRemoveFromAlbum: return "選択項目をアルバムから外す"
        case .libraryEmptyTrash: return "ゴミ箱を空にする"
        }
    }

    var defaultKey: MediaShortcutKey {
        defaultKeys[0]
    }

    var defaultKeys: [MediaShortcutKey] {
        switch self {
        case .videoPlayPause: return [.space, .k]
        case .videoPreviousItem: return [.leftArrow]
        case .videoNextItem: return [.rightArrow]
        case .videoSeekBack15: return [.g]
        case .videoSeekBack10: return [.h]
        case .videoSeekBack5: return [.j]
        case .videoSeekForward5: return [.l]
        case .videoSeekForward10: return [.semicolon]
        case .videoSeekForward15: return [.quote]
        case .videoRandomSeek: return [.r]
        case .photoPrevious: return [.leftArrow]
        case .photoNext: return [.rightArrow]
        case .photoToggleMangaMode: return [.m]
        case .photoDelete: return [.delete]
        case .photoClose: return [.f]
        case .libraryOpenFocused: return [.returnKey]
        case .libraryMoveLeft: return [.leftArrow]
        case .libraryMoveRight: return [.rightArrow]
        case .libraryMoveUp: return [.upArrow]
        case .libraryMoveDown: return [.downArrow]
        case .libraryOpenExternal: return [MediaShortcutKey(rawValue: "o")]
        case .libraryRevealInFinder: return [MediaShortcutKey(rawValue: "f")]
        case .libraryToggleFavorite: return [MediaShortcutKey(rawValue: "v")]
        case .libraryDelete: return [.delete]
        case .libraryMoveToTrash: return [MediaShortcutKey(rawValue: "t")]
        case .libraryRestoreFromTrash: return [MediaShortcutKey(rawValue: "u")]
        case .libraryExport: return [MediaShortcutKey(rawValue: "e")]
        case .libraryImport: return [MediaShortcutKey(rawValue: "i")]
        case .libraryRandomPlay: return [.r]
        case .libraryMultiPlay: return [MediaShortcutKey(rawValue: "m")]
        case .librarySlideshow: return [MediaShortcutKey(rawValue: "s")]
        case .librarySplitPlay: return [MediaShortcutKey(rawValue: "p")]
        case .libraryDuplicateCheck: return [MediaShortcutKey(rawValue: "d")]
        case .libraryRemoveFromAlbum: return [MediaShortcutKey(rawValue: "a")]
        case .libraryEmptyTrash: return [MediaShortcutKey(rawValue: "x")]
        }
    }

    static let videoActions: [MediaShortcutAction] = [
        .videoPlayPause,
        .videoPreviousItem,
        .videoNextItem,
        .videoSeekBack15,
        .videoSeekBack10,
        .videoSeekBack5,
        .videoSeekForward5,
        .videoSeekForward10,
        .videoSeekForward15,
        .videoRandomSeek
    ]

    static let photoActions: [MediaShortcutAction] = [
        .photoPrevious,
        .photoNext,
        .photoToggleMangaMode,
        .photoDelete,
        .photoClose
    ]

    static let libraryActions: [MediaShortcutAction] = [
        .libraryOpenFocused,
        .libraryMoveLeft,
        .libraryMoveRight,
        .libraryMoveUp,
        .libraryMoveDown,
        .libraryOpenExternal,
        .libraryRevealInFinder,
        .libraryToggleFavorite,
        .libraryDelete,
        .libraryMoveToTrash,
        .libraryRestoreFromTrash,
        .libraryExport,
        .libraryImport,
        .libraryRandomPlay,
        .libraryMultiPlay,
        .librarySlideshow,
        .librarySplitPlay,
        .libraryDuplicateCheck,
        .libraryRemoveFromAlbum,
        .libraryEmptyTrash
    ]
}

enum MediaShortcutSettings {
    static let versionKey = "mediaShortcut.settingsVersion"

    static func keys(for action: MediaShortcutAction) -> [MediaShortcutKey] {
        let storedValue = UserDefaults.standard.object(forKey: action.storageKey)

        if let rawValues = storedValue as? [String] {
            let keys = rawValues.map { MediaShortcutKey(rawValue: $0) }
            return keys.isEmpty ? action.defaultKeys : uniqueKeys(keys)
        }

        if let rawValue = storedValue as? String {
            return [MediaShortcutKey(rawValue: rawValue)]
        }

        return action.defaultKeys
    }

    static func matches(_ action: MediaShortcutAction, press: KeyPress) -> Bool {
        keys(for: action).contains { $0.matches(press) }
    }

    static func shortcutList(
        for actions: [MediaShortcutAction],
        extraItems: [(key: String, action: String)] = []
    ) -> [(key: String, action: String)] {
        actions.map { action in
            (keys(for: action).map(\.displayName).joined(separator: " / "), action.helpAction)
        } + extraItems
    }

    static func setKeys(_ keys: [MediaShortcutKey], for action: MediaShortcutAction) {
        let normalizedKeys = uniqueKeys(keys)
        let keysToSave = normalizedKeys.isEmpty ? action.defaultKeys : normalizedKeys
        UserDefaults.standard.set(keysToSave.map(\.rawValue), forKey: action.storageKey)
        bumpVersion()
    }

    static func addKey(_ key: MediaShortcutKey, for action: MediaShortcutAction) {
        var currentKeys = keys(for: action)
        guard !currentKeys.contains(key) else { return }
        currentKeys.append(key)
        setKeys(currentKeys, for: action)
    }

    static func removeKey(_ key: MediaShortcutKey, for action: MediaShortcutAction) {
        let currentKeys = keys(for: action)
        guard currentKeys.count > 1 else { return }
        setKeys(currentKeys.filter { $0 != key }, for: action)
    }

    static func resetDefaults() {
        for action in MediaShortcutAction.allCases {
            UserDefaults.standard.set(action.defaultKeys.map(\.rawValue), forKey: action.storageKey)
        }
        bumpVersion()
    }

    static func bumpVersion() {
        let current = UserDefaults.standard.integer(forKey: versionKey)
        UserDefaults.standard.set(current + 1, forKey: versionKey)
    }

    private static func uniqueKeys(_ keys: [MediaShortcutKey]) -> [MediaShortcutKey] {
        var seen: Set<MediaShortcutKey> = []
        var result: [MediaShortcutKey] = []
        for key in keys where !seen.contains(key) {
            seen.insert(key)
            result.append(key)
        }
        return result
    }
}

struct MediaShortcutSettingsSection: View {
    @AppStorage(MediaShortcutSettings.versionKey) private var settingsVersion = 0

    var body: some View {
        Section("ショートカットキー") {
            VStack(alignment: .leading, spacing: 8) {
                Text("一覧")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(MediaShortcutAction.libraryActions) { action in
                    MediaShortcutAssignmentRow(action: action)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("動画")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(MediaShortcutAction.videoActions) { action in
                    MediaShortcutAssignmentRow(action: action)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("画像")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(MediaShortcutAction.photoActions) { action in
                    MediaShortcutAssignmentRow(action: action)
                }
            }

            if hasDuplicateAssignments {
                Label("同じキーが複数の操作に割り当てられています。画面ごとの先に判定された操作が優先されます。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("既定値に戻す") {
                MediaShortcutSettings.resetDefaults()
            }
        }
    }

    private var hasDuplicateAssignments: Bool {
        _ = settingsVersion
        let libraryDuplicates = hasDuplicateKeys(in: MediaShortcutAction.libraryActions)
        let videoDuplicates = hasDuplicateKeys(in: MediaShortcutAction.videoActions)
        let photoDuplicates = hasDuplicateKeys(in: MediaShortcutAction.photoActions)
        return libraryDuplicates || videoDuplicates || photoDuplicates
    }

    private func hasDuplicateKeys(in actions: [MediaShortcutAction]) -> Bool {
        let rawValues = actions.flatMap { MediaShortcutSettings.keys(for: $0).map(\.rawValue) }
        return Set(rawValues).count != rawValues.count
    }
}

private struct MediaShortcutAssignmentRow: View {
    let action: MediaShortcutAction
    @AppStorage(MediaShortcutSettings.versionKey) private var settingsVersion = 0
    @FocusState private var isCaptureFocused: Bool
    @State private var isCapturing = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(action.settingsTitle)
            Spacer(minLength: 12)
            FlowLayout(spacing: 6) {
                ForEach(keys) { key in
                    HStack(spacing: 4) {
                        Text(key.displayName)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                        Button {
                            MediaShortcutSettings.removeKey(key, for: action)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .disabled(keys.count <= 1)
                        .help(keys.count <= 1 ? "少なくとも1つのキーが必要です" : "このキーを削除")
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
            Button {
                isCapturing = true
                DispatchQueue.main.async {
                    isCaptureFocused = true
                }
            } label: {
                Label(isCapturing ? "キーを押してください" : "キーを追加", systemImage: isCapturing ? "keyboard" : "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(isCapturing ? "登録したいキーを押してください。Escでキャンセルします。" : "キーを押して追加")
        }
        .padding(.vertical, 2)
        .focusable()
        .focused($isCaptureFocused)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCapturing ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .onKeyPress(phases: .down, action: captureKeyPress)
        .onChange(of: settingsVersion) { _, _ in
            // UserDefaults の配列変更を設定行へ伝播させるための依存関係です。
        }
    }

    private var keys: [MediaShortcutKey] {
        _ = settingsVersion
        return MediaShortcutSettings.keys(for: action)
    }

    private func captureKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard isCapturing else { return .ignored }

        if press.key == .escape {
            isCapturing = false
            isCaptureFocused = false
            return .handled
        }

        guard let key = MediaShortcutKey.captured(from: press) else {
            return .handled
        }

        MediaShortcutSettings.addKey(key, for: action)
        isCapturing = false
        isCaptureFocused = false
        return .handled
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 13.0, *) {
            Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                GridRow {
                    content
                }
            }
        }
    }
}

// MARK: - Chapter model

/// プレイヤーサイドバーに表示するチャプター情報を表す構造体
struct ChapterPoint: Identifiable, Hashable {
    let id = UUID()
    let percentage: Double // 0.0, 0.1 ... 0.9
    let time: CMTime
    let thumbnail: Image?

    var timeString: String {
        let totalSeconds = Int(round(CMTimeGetSeconds(time)))
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func == (lhs: ChapterPoint, rhs: ChapterPoint) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Live thumbnail generation (no cache)

/// 再生中プレビュー（チャプター等）用に、キャッシュなしでサムネイルを生成するユーティリティ。
enum PlayerThumbnailGenerator {

    /// 指定された時間からサムネイルを生成する。真っ黒なフレームの場合は少し先で再試行する。
    static func generateLiveThumbnail(for asset: AVAsset, at time: CMTime) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let maxAttempts = 5
        let retryTimeOffset: Double = 2.0

        for attempt in 0..<maxAttempts {
            let attemptTime = CMTimeAdd(time, CMTime(seconds: Double(attempt) * retryTimeOffset, preferredTimescale: 600))
            do {
                let cgImage = try await generator.image(at: attemptTime).image
                if !isPredominantlyBlack(image: cgImage) {
                    return cgImage
                }
            } catch {
                continue
            }
        }
        return try? await generator.image(at: time).image
    }

    /// CGImage が主に黒（非常に暗い色）で構成されているかを判定する。
    private static func isPredominantlyBlack(
        image: CGImage,
        darknessThreshold: UInt8 = 30,
        percentageThreshold: Double = 0.95
    ) -> Bool {
        guard let pixelData = image.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else { return false }

        let width = image.width
        let height = image.height
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return false }

        let totalPixels = width * height
        guard totalPixels > 0 else { return false }

        // パフォーマンスのため最大1万ピクセル程度をサンプリングする
        let step = max(1, totalPixels / 10000)
        let sampleTotal = max(1, totalPixels / step)
        var darkPixelCount = 0

        for i in stride(from: 0, to: totalPixels, by: step) {
            let x = i % width
            let y = i / width
            let offset = (y * image.bytesPerRow) + (x * bytesPerPixel)
            let red = data[offset]
            let green = data[offset + 1]
            let blue = data[offset + 2]
            if red < darknessThreshold && green < darknessThreshold && blue < darknessThreshold {
                darkPixelCount += 1
            }
        }
        return Double(darkPixelCount) / Double(sampleTotal) >= percentageThreshold
    }
}
