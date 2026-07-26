import AppKit
import QuickLookUI

// MARK: - クイックルック（一覧で動画を選んで Space）
//
// Finder と同じ QLPreviewPanel を小さいパネルで開き、動画をその場で確認できるようにする。
// アプリ内の通常再生（VideoPlayerView）はウィンドウ全体を占有するので、
// 「中身をちょっと確かめたいだけ」の用途はこちらで受ける。動画専用の機能。

/// クイックルックパネルへ渡す項目を保持する。パネルはシステムに1つしか無いので単一インスタンス。
final class QuickLookPreviewController: NSObject {
    static let shared = QuickLookPreviewController()

    /// 矢印キーで一覧の選択を動かす向き。
    enum NavigationDirection {
        case left, right, up, down
    }

    /// プレビュー中に矢印キーが押されたときに呼ぶ。
    /// 一覧側で選択を1つ動かし、新しく選ばれた項目の URL を返してもらう（端で動けなければ nil）。
    /// パネルを開くたびに差し替え、閉じたら捨てる。
    var onNavigate: ((NavigationDirection) -> URL?)?

    private var urls: [URL] = []

    private override init() {
        super.init()
    }

    /// `urls` をパネルに並べ、`index` 番目を表示する。
    /// 同じ内容が同じ位置で既に開いていれば閉じる（Finder の Space と同じトグル）。
    /// パネルがキーウィンドウの間は Space をパネル自身が処理して閉じるので、
    /// このトグルが効くのは一覧側にフォーカスが戻っている場合。
    func present(urls: [URL], startingAt index: Int) {
        guard urls.indices.contains(index) else { return }
        guard let panel = QLPreviewPanel.shared() else { return }

        if panel.isVisible, self.urls == urls, panel.currentPreviewItemIndex == index {
            panel.orderOut(nil)
            return
        }

        self.urls = urls
        if panel.isVisible {
            panel.reloadData()
        } else {
            // makeKeyAndOrderFront がレスポンダチェーンを辿って制御役を決め、
            // その中で dataSource が設定される（AppDelegate の beginPreviewPanelControl）。
            panel.makeKeyAndOrderFront(nil)
        }
        // dataSource が付く前に索引を触ると例外になるため、制御役が決まったことを確かめてから設定する。
        if panel.dataSource != nil {
            panel.currentPreviewItemIndex = index
        }
    }

    /// パネルが開いていれば閉じる。
    func close() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// パネルの制御が終わったときの後片付け。一覧側を掴んだままにしない。
    func panelControlEnded() {
        onNavigate = nil
    }
}

extension QuickLookPreviewController {
    /// 一覧の項目からパネルへ渡す動画の URL 列と、`focused` がその何番目になるかを求める。
    /// 実ファイルが見つからないものは飛ばすので、索引は取り出せた URL の側で数える。
    /// `focused` 自身のファイルが無ければ `startIndex` は nil（＝プレビューしない）。
    static func previewTargets(
        in items: [VideoItem],
        focusedOn focused: VideoItem,
        resolve: (VideoItem) -> URL?
    ) -> (urls: [URL], startIndex: Int?) {
        var urls: [URL] = []
        var startIndex: Int?
        for item in items where item.mediaType == .video {
            guard let url = resolve(item) else { continue }
            if item.id == focused.id { startIndex = urls.count }
            urls.append(url)
        }
        return (urls, startIndex)
    }
}

extension QuickLookPreviewController: QLPreviewPanelDelegate {
    /// パネルへ届くキー入力を横取りする。
    ///
    /// 矢印キーは一覧の選択移動に使い、プレビューをその項目へ差し替える。
    /// ただし複数選択して開いたとき（＝「この何件かを見比べたい」）は、
    /// パネル本来の項目送りをそのまま使わせる。
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event?.type == .keyDown, urls.count == 1, let onNavigate else { return false }
        guard let direction = Self.direction(for: event.keyCode) else { return false }

        // 端まで来て動けなくてもキーは消費する。ここで false を返すと
        // パネル既定の項目送り（項目は1件なので何も起きない）へ流れるだけで意味がない。
        guard let url = onNavigate(direction) else { return true }
        urls = [url]
        panel.reloadData()
        return true
    }

    private static func direction(for keyCode: UInt16) -> NavigationDirection? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }
}

extension QuickLookPreviewController: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        // QLPreviewItem に適合しているのは NSURL の方（URL は適合していない）。
        return urls[index] as NSURL
    }
}
