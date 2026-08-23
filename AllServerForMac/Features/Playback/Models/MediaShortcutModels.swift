import Foundation
import SwiftUI

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
    case videoClose
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
    case videoToggleUpNextPanel
    case videoToggleMiniPlayer
    case variantNext
    case variantPrevious
    case variantRandom
    case variantToggleAuto
    case variantToggleDeleteMode
    case variantMarkForDeletion
    case photoPrevious
    case photoNext
    case photoToggleMangaMode
    case photoDelete
    case photoClose
    case libraryOpenFocused
    case libraryQuickLook
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
    case libraryVariantPlay
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
        case .videoClose: return "動画: プレイヤーを閉じる"
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
        case .videoToggleUpNextPanel: return "動画: 関連動画パネル切替"
        case .videoToggleMiniPlayer: return "動画: ミニプレイヤー"
        case .variantNext: return "差分: 次のバージョンへ"
        case .variantPrevious: return "差分: 前のバージョンへ"
        case .variantRandom: return "差分: ランダムなバージョンへ"
        case .variantToggleAuto: return "差分: 自動切り替えの入/切"
        case .variantToggleDeleteMode: return "差分: 削除モードの入/切"
        case .variantMarkForDeletion: return "差分: 表示中を削除対象にする"
        case .photoPrevious: return "画像: 前の画像"
        case .photoNext: return "画像: 次の画像"
        case .photoToggleMangaMode: return "画像: 漫画モード切替"
        case .photoDelete: return "画像: 削除"
        case .photoClose: return "画像: 全画面表示／閉じる"
        case .libraryOpenFocused: return "一覧: 開く"
        case .libraryQuickLook: return "一覧: クイックルック"
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
        case .libraryVariantPlay: return "一覧: 差分切り替え再生"
        case .librarySlideshow: return "一覧: スライドショー"
        case .librarySplitPlay: return "一覧: 分割再生"
        case .libraryDuplicateCheck: return "一覧: 重複チェック"
        case .libraryRemoveFromAlbum: return "一覧: アルバムから外す"
        case .libraryEmptyTrash: return "一覧: ゴミ箱を空にする"
        }
    }

    var helpAction: String {
        switch self {
        case .videoClose: return "動画プレイヤーを閉じる"
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
        case .videoToggleUpNextPanel: return "同じアルバムの動画パネルを表示/非表示"
        case .videoToggleMiniPlayer: return "小さい画面で再生しながらアルバム一覧を表示"
        case .variantNext: return "次の差分バージョンへ切り替え"
        case .variantPrevious: return "前の差分バージョンへ切り替え"
        case .variantRandom: return "ランダムな差分バージョンへ切り替え"
        case .variantToggleAuto: return "一定間隔での自動切り替えを止める/再開する"
        case .variantToggleDeleteMode: return "見比べて要らないと分かったものを選んで消すモードに入る"
        case .variantMarkForDeletion: return "いま表示している差分を削除対象に入れる/外す"
        case .photoPrevious: return "前の画像へ"
        case .photoNext: return "次の画像へ"
        case .photoToggleMangaMode: return "漫画モードを切り替え"
        case .photoDelete: return "現在の画像を削除"
        case .photoClose: return "全画面表示／画像ビューアを閉じる"
        case .libraryOpenFocused: return "選択中の動画・画像を開く"
        case .libraryQuickLook: return "選択中の動画を小さいパネルでプレビュー（動画のみ）"
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
        case .libraryVariantPlay: return "選択動画を差分切り替え再生"
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
        case .videoClose: return [.f]
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
        case .videoToggleUpNextPanel: return [MediaShortcutKey(rawValue: "t")]
        case .videoToggleMiniPlayer: return [MediaShortcutKey(rawValue: "i")]
        case .variantNext: return [MediaShortcutKey(rawValue: "n")]
        case .variantPrevious: return [MediaShortcutKey(rawValue: "b")]
        case .variantRandom: return [MediaShortcutKey(rawValue: "v")]
        case .variantToggleAuto: return [MediaShortcutKey(rawValue: "a")]
        case .variantToggleDeleteMode: return [MediaShortcutKey(rawValue: "d")]
        case .variantMarkForDeletion: return [MediaShortcutKey(rawValue: "x")]
        case .photoPrevious: return [.leftArrow]
        case .photoNext: return [.rightArrow]
        case .photoToggleMangaMode: return [.m]
        case .photoDelete: return [.delete]
        case .photoClose: return [.f]
        case .libraryOpenFocused: return [.returnKey]
        case .libraryQuickLook: return [.space]
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
        case .libraryVariantPlay: return [MediaShortcutKey(rawValue: "y")]
        case .librarySlideshow: return [MediaShortcutKey(rawValue: "s")]
        case .librarySplitPlay: return [MediaShortcutKey(rawValue: "p")]
        case .libraryDuplicateCheck: return [MediaShortcutKey(rawValue: "d")]
        case .libraryRemoveFromAlbum: return [MediaShortcutKey(rawValue: "a")]
        case .libraryEmptyTrash: return [MediaShortcutKey(rawValue: "x")]
        }
    }

    static let videoActions: [MediaShortcutAction] = [
        .videoClose,
        .videoPlayPause,
        .videoPreviousItem,
        .videoNextItem,
        .videoSeekBack15,
        .videoSeekBack10,
        .videoSeekBack5,
        .videoSeekForward5,
        .videoSeekForward10,
        .videoSeekForward15,
        .videoRandomSeek,
        .videoToggleUpNextPanel,
        .videoToggleMiniPlayer
    ]

    /// 差分切り替え再生だけで使うもの。再生・シーク・閉じるは `videoActions` と共通なので重ねない。
    static let variantActions: [MediaShortcutAction] = [
        .variantNext,
        .variantPrevious,
        .variantRandom,
        .variantToggleAuto,
        .variantToggleDeleteMode,
        .variantMarkForDeletion
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
        .libraryQuickLook,
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
        .libraryVariantPlay,
        .librarySlideshow,
        .librarySplitPlay,
        .libraryDuplicateCheck,
        .libraryRemoveFromAlbum,
        .libraryEmptyTrash
    ]
}
