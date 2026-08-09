import Combine
import Foundation

/// リンクフォルダの手動更新（ホーム画面のボタン）の進捗状態。LibraryViewModel 本体とは別の
/// ObservableObject に分離することで、スキャン中に更新される statusMessage が、写真・動画一覧を
/// 表示する巨大なギャラリービュー（videos/albums を @Published で購読している側）まで
/// 再描画させないようにする（DuplicateCheckStatus と同じ理由）。
final class LinkedFolderScanStatus: ObservableObject {
    @Published var isScanning = false
    /// これまでに確認し終えたフォルダ数（進捗バーの分子）。
    @Published var processedCount = 0
    /// 今回の更新で対象になったフォルダ総数（進捗バーの分母）。
    @Published var totalCount = 0
    /// 現在スキャン中のフォルダ（アルバム）名。
    @Published var currentFolderName: String?
    /// 現在のフォルダで新しく取り込んだメディア件数（単一フォルダでも進捗が動いて見えるように）。
    @Published var processedItemsInCurrentFolder = 0
    /// スキャン完了後などに表示するメッセージ。
    @Published var statusMessage = ""
}

/// 自動重複チェックの進捗状態。LibraryViewModel 本体とは別の ObservableObject に分離することで、
/// ハッシュ計算中に頻繁に更新される progress/statusMessage が、写真・動画一覧を表示する
/// 巨大なギャラリービュー（videos/albums を @Published で購読している側）まで再描画させないようにする。
final class DuplicateCheckStatus: ObservableObject {
    @Published var isAutoChecking = false
    @Published var currentAlbumName: String?
    @Published var progress: Double = 0
    @Published var statusMessage = "待機中"

    // チェック済み/未チェックのアルバム一覧はダッシュボードの表示用キャッシュ。
    // 署名（アルバム内の全動画IDをソートして連結した文字列）の再計算はアルバム件数が多いと軽くないため、
    // 描画のたびではなく自動チェックループ（数十秒おき）やチェック完了時にだけ更新する。
    @Published var checkedAlbums: [Album] = []
    @Published var uncheckedAlbums: [Album] = []
}
