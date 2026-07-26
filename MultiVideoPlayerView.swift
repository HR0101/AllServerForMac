import Foundation
import SwiftUI
import AVKit
import Combine

// MARK: - Multi-video synchronized playback (3-B)
// 選択した2〜9個の動画をグリッドに並べ、共通スライダー/キーボードで完全同期して再生する。

/// タイルの並び。行ごとに、その行へ左から並べるプレイヤーの添字を持つ。
///
/// 画面の組み立てと、音の定位（左のタイルは左から鳴らす）の計算が必ず同じ配置を見るように、
/// 配置の定義はここ1か所だけにする。
enum MultiPlayerLayout {
    static func rows(for count: Int) -> [[Int]] {
        switch count {
        case 2: return [[0], [1]]
        case 3: return [[0, 1], [2]]
        case 4: return [[0, 1], [2, 3]]
        case 5: return [[0, 1, 2], [3, 4]]
        case 6: return [[0, 1], [2, 3], [4, 5]]
        case 7: return [[0, 1, 2], [3, 4], [5, 6]]
        case 8: return [[0, 1, 2], [3, 4, 5], [6, 7]]
        case 9: return [[0, 1, 2], [3, 4, 5], [6, 7, 8]]
        default: return count > 0 ? [Array(0..<count)] : []
        }
    }

    /// 配置から決まる既定の定位。-1（左端）〜 +1（右端）。
    /// 1列しかない行は中央（0）。3列なら左 -1 / 中央 0 / 右 +1 になる。
    static func defaultPans(for count: Int) -> [Int: Float] {
        var result: [Int: Float] = [:]
        for row in rows(for: count) {
            guard row.count > 1 else {
                row.forEach { result[$0] = 0 }
                continue
            }
            for (column, index) in row.enumerated() {
                result[index] = Float(column) / Float(row.count - 1) * 2 - 1
            }
        }
        return result
    }
}

@MainActor
final class MultiVideoPlayerViewModel: ObservableObject {
    @Published var players: [AVPlayer] = []
    @Published var commonCurrentTime: Double = 0
    @Published var commonDuration: Double = 1.0

    private var leadPlayerTimeObserver: Any?
    private var leadPlayer: AVPlayer?
    private var cancellables = Set<AnyCancellable>()
    private var isSliderEditing = false
    private var syncStartTask: Task<Void, Never>?

    /// 一斉スタートを予約するときの猶予。全プレイヤーへ setRate を配り終える前に
    /// その時刻が過ぎてしまうと、結局バラバラに動き出す。
    private static let syncStartLeadSeconds: Double = 0.15
    /// 再生可能になるまで待つ上限。壊れたファイルが1つ混じっても止まらないようにする。
    private static let readyTimeoutSeconds: Double = 5

    /// タイル1枚ぶんの音声設定。並びは `players` と同じ＝画面の配置と同じ。
    struct TileAudio: Identifiable {
        let id: Int
        let title: String
        var volume: Float
        var isMuted: Bool
        /// -1（完全に左）〜 0（中央）〜 +1（完全に右）
        var pan: Float
    }

    @Published var tileAudio: [TileAudio] = []
    /// 処理タップへ値を渡す箱。`tileAudio` と同じ並び。
    private var tapSettings: [AudioTapSettings] = []

    init(videos: [VideoItem], dataManager: VideoDataManager) {
        let playable = videos.compactMap { item -> (VideoItem, URL)? in
            guard let url = dataManager.fileURL(for: item) else { return nil }
            return (item, url)
        }

        self.players = playable.map { _, url in
            let player = AVPlayer(url: url)
            // 一斉スタート（setRate(_:time:atHostTime:)）を使うための前提。
            // 既定のままだとプレイヤーが自分の判断で再生開始を遅らせるので同期が崩れる。
            player.automaticallyWaitsToMinimizeStalling = false
            // 各プレイヤーの時間軸を共通のホストクロックに合わせる。
            player.sourceClock = CMClockGetHostTimeClock()
            return player
        }

        let defaultPans = MultiPlayerLayout.defaultPans(for: players.count)
        self.tileAudio = playable.enumerated().map { index, entry in
            TileAudio(
                id: index,
                title: entry.0.originalFilename,
                volume: 1,
                isMuted: false,
                pan: defaultPans[index] ?? 0
            )
        }
        self.tapSettings = tileAudio.map { tile in
            let settings = AudioTapSettings()
            settings.update(volume: tile.volume, isMuted: tile.isMuted, pan: tile.pan)
            return settings
        }

        setupLeadPlayerObserver()
        attachAudioProcessing()
    }

    /// 各プレイヤーの音声トラックに処理タップを挟む。
    /// トラックの読み込みは非同期なので、再生開始を待たせないように後から差し込む。
    private func attachAudioProcessing() {
        for (index, player) in players.enumerated() {
            guard let item = player.currentItem, index < tapSettings.count else { continue }
            let settings = tapSettings[index]
            Task { @MainActor in
                guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
                item.audioMix = MultiPlayerAudio.makeAudioMix(for: track, settings: settings)
            }
        }
    }

    /// コンソールで音量・ミュート・定位をいじったときに、その場で音へ反映する。
    func applyTileAudio(at index: Int) {
        guard tileAudio.indices.contains(index), tapSettings.indices.contains(index) else { return }
        let tile = tileAudio[index]
        tapSettings[index].update(volume: tile.volume, isMuted: tile.isMuted, pan: tile.pan)
    }

    /// 全タイルの定位を、いまの並びから決まる既定値へ戻す（音量・ミュートはそのまま）。
    func resetPansToLayout() {
        let defaultPans = MultiPlayerLayout.defaultPans(for: players.count)
        for index in tileAudio.indices {
            tileAudio[index].pan = defaultPans[index] ?? 0
            applyTileAudio(at: index)
        }
    }

    /// 自分以外を全部ミュートする（1つの音だけ聴きたいとき用）。
    func soloTile(at index: Int) {
        for i in tileAudio.indices {
            tileAudio[i].isMuted = (i != index)
            applyTileAudio(at: i)
        }
    }

    func unmuteAllTiles() {
        for i in tileAudio.indices {
            tileAudio[i].isMuted = false
            applyTileAudio(at: i)
        }
    }

    private func setupLeadPlayerObserver() {
        guard let leadPlayer = players.max(by: {
            ($0.currentItem?.duration.seconds ?? 0) < ($1.currentItem?.duration.seconds ?? 0)
        }) else { return }
        self.leadPlayer = leadPlayer

        leadPlayer.publisher(for: \.currentItem?.duration)
            .compactMap { $0?.seconds }
            .filter { !$0.isNaN && $0 > 0 }
            .assign(to: &$commonDuration)

        leadPlayerTimeObserver = leadPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isSliderEditing else { return }
                self.commonCurrentTime = time.seconds
            }
        }
    }

    func commonSliderEditingChanged(isEditing: Bool) {
        self.isSliderEditing = isEditing
        if !isEditing {
            guard commonDuration > 0 else { return }
            seekAll(toPercentage: commonCurrentTime / commonDuration)
        }
    }

    var isPlaying: Bool { players.contains { $0.rate > 0 } }

    func playAll() { startInSync() }

    func pauseAll() {
        syncStartTask?.cancel()
        syncStartTask = nil
        players.forEach { $0.pause() }
    }

    func togglePlayPauseAll() {
        if isPlaying {
            pauseAll()
        } else {
            startInSync()
        }
    }

    /// 全プレイヤーを同じ瞬間に走らせる。`seek` を渡すと、まずその位置へ揃えてから開始する。
    ///
    /// 個別に `play()` を呼ぶと、デコードの準備ができた順にバラバラと動き出すので、
    /// 同じ動画を並べても開始が数フレームずれる。ずれを無くすために
    /// 「目的位置へシーク → 全員が再生可能になるまで待つ → preroll でバッファを用意 →
    /// 共通のホストタイムを指定して一斉に setRate」という順で揃える。
    func startInSync(seek target: ((AVPlayer) -> CMTime?)? = nil) {
        syncStartTask?.cancel()
        let players = self.players
        guard !players.isEmpty else { return }

        // 走ったまま準備を進めると、その間に各プレイヤーが進んでしまって揃わない。
        players.forEach { $0.pause() }
        let seekTargets = players.map { player in (player: player, time: target?(player)) }

        syncStartTask = Task { @MainActor in
            for entry in seekTargets {
                guard let time = entry.time else { continue }
                await entry.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                if Task.isCancelled { return }
            }

            await Self.waitUntilAllReady(players)
            if Task.isCancelled { return }

            for player in players {
                _ = await player.preroll(atRate: 1.0)
                if Task.isCancelled { return }
            }

            let startHostTime = CMClockGetTime(CMClockGetHostTimeClock())
                + CMTime(seconds: Self.syncStartLeadSeconds, preferredTimescale: 600)
            for player in players {
                // time に .invalid を渡すと「今指している位置」をその瞬間に合わせる意味になる。
                player.setRate(1.0, time: .invalid, atHostTime: startHostTime)
            }
        }
    }

    /// 全プレイヤーの `currentItem` が再生可能になるまで待つ（上限つき）。
    private static func waitUntilAllReady(_ players: [AVPlayer]) async {
        let deadline = Date().addingTimeInterval(readyTimeoutSeconds)
        while Date() < deadline {
            if players.allSatisfy({ $0.currentItem?.status == .readyToPlay }) { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
            if Task.isCancelled { return }
        }
    }

    /// 再生中なら一斉スタートし直し、停止中ならシークだけして止まったままにする。
    private func applySeek(_ target: @escaping (AVPlayer) -> CMTime?) {
        guard !isPlaying else {
            startInSync(seek: target)
            return
        }
        syncStartTask?.cancel()
        syncStartTask = nil
        for player in players {
            guard let time = target(player) else { continue }
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func seekAll(by seconds: Double) {
        applySeek { player in
            let current = player.currentTime().seconds
            guard current.isFinite else { return nil }
            return CMTime(seconds: max(0, current + seconds), preferredTimescale: 600)
        }
    }

    func seekAll(toPercentage percentage: Double) {
        applySeek { player in
            guard let duration = player.currentItem?.duration, duration.seconds > 0 else { return nil }
            return CMTime(seconds: duration.seconds * percentage, preferredTimescale: 600)
        }
    }

    /// 全動画を同じ秒数（最短動画の範囲内）へランダムシークする
    func seekAllToRandomTime() {
        let shortestDuration = players.compactMap { $0.currentItem?.duration.seconds }.min() ?? 0
        guard shortestDuration > 0 else { return }
        let seekCMTime = CMTime(seconds: Double.random(in: 0..<shortestDuration), preferredTimescale: 600)
        applySeek { _ in seekCMTime }
    }

    func cleanup() {
        syncStartTask?.cancel()
        syncStartTask = nil
        if let observer = leadPlayerTimeObserver {
            leadPlayer?.removeTimeObserver(observer)
            leadPlayerTimeObserver = nil
        }
        leadPlayer = nil
        players.forEach { $0.pause() }
        players.removeAll()
    }
}

/// グリッド内の個々のプレイヤーセル（操作は共通スライダー/キーボードに集約）
private struct PlayerCellView: View {
    let player: AVPlayer
    /// ミキサーを開いている間だけ、コンソールの行と見比べられるよう番号とミュート状態を出す。
    var badgeNumber: Int?
    var isMuted: Bool = false

    var body: some View {
        PlayerContainerView(
            player: player,
            controlsStyle: .none,
            showsFullScreenToggleButton: false,
            allowsPictureInPicturePlayback: false
        )
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            if let badgeNumber {
                HStack(spacing: 5) {
                    Text("\(badgeNumber)")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                    if isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(8)
            }
        }
    }
}

struct MultiVideoPlayerView: View {
    @StateObject private var viewModel: MultiVideoPlayerViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @FocusState private var isFocused: Bool
    @State private var showShortcutHelp = false
    @State private var isAudioConsoleVisible = false
    @AppStorage(MediaShortcutSettings.versionKey) private var shortcutSettingsVersion = 0
    private let videoCount: Int

    init(videos: [VideoItem], dataManager: VideoDataManager) {
        _viewModel = StateObject(wrappedValue: MultiVideoPlayerViewModel(videos: videos, dataManager: dataManager))
        self.videoCount = videos.count
    }

    private var shortcutList: [(key: String, action: String)] {
        _ = shortcutSettingsVersion
        return MediaShortcutSettings.shortcutList(
            for: [
                .videoPlayPause,
                .videoSeekBack10,
                .videoSeekBack5,
                .videoSeekForward5,
                .videoSeekForward10,
                .videoRandomSeek
            ],
            extraItems: [
                ("0〜9", "0%〜90% の位置へ同時ジャンプ"),
                ("M", "音声ミキサーの表示/非表示"),
                ("?", "ショートカット一覧を表示"),
                ("Esc", "プレイヤーを閉じる")
            ]
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                grid
                controls
            }
            PlayerCornerControls(showShortcutHelp: $showShortcutHelp) {
                coordinator.close()
            }
            if isAudioConsoleVisible {
                audioConsole
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showShortcutHelp {
                ShortcutHelpPanel(title: "同時再生のショートカット", shortcuts: shortcutList) {
                    showShortcutHelp = false
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down, action: handleKeyPress)
        .onAppear {
            viewModel.playAll()
            isFocused = true
        }
        // コンソールのボタンやスライダーを押すとフォーカスがそちらへ移り、
        // 以降 .onKeyPress が効かなくなる。開閉のたびに本体へ戻しておく。
        .onChange(of: isAudioConsoleVisible) { _, _ in
            isFocused = true
        }
        .onDisappear(perform: viewModel.cleanup)
    }

    @ViewBuilder
    private var grid: some View {
        let players = viewModel.players
        if players.isEmpty {
            Text("再生する動画がありません").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 2) {
                ForEach(Array(MultiPlayerLayout.rows(for: players.count).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 2) {
                        ForEach(row, id: \.self) { index in
                            PlayerCellView(
                                player: players[index],
                                badgeNumber: isAudioConsoleVisible ? index + 1 : nil,
                                isMuted: viewModel.tileAudio.indices.contains(index)
                                    ? viewModel.tileAudio[index].isMuted
                                    : false
                            )
                        }
                    }
                }
            }
        }
    }

    /// M キーで開閉する音声ミキサー。タイルと同じ並びで出すので、
    /// 画面のどの位置の音を触っているのかが見たままで分かる。
    private var audioConsole: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Label("音声ミキサー", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button("全部鳴らす") { viewModel.unmuteAllTiles() }
                    .help("すべてのミュートを解除")
                Button("定位を配置どおりに") { viewModel.resetPansToLayout() }
                    .help("左右の振り分けを、いまのタイル配置から決まる既定値へ戻す")
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { isAudioConsoleVisible = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .help("ミキサーを閉じる（M / Esc）")
            }

            ForEach(Array(MultiPlayerLayout.rows(for: viewModel.players.count).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(row, id: \.self) { index in
                        tileStrip(index)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 920)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder
    private func tileStrip(_ index: Int) -> some View {
        if viewModel.tileAudio.indices.contains(index) {
            let tile = viewModel.tileAudio[index]
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white.opacity(0.18)))
                    Text(tile.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        viewModel.tileAudio[index].isMuted.toggle()
                        viewModel.applyTileAudio(at: index)
                    } label: {
                        Image(systemName: tile.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 18)
                    }
                    .buttonStyle(.plain)
                    .help(tile.isMuted ? "ミュート解除" : "ミュート")
                    Button {
                        viewModel.soloTile(at: index)
                    } label: {
                        Text("SOLO").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("これだけ鳴らす（他を全部ミュート）")
                }

                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.1")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { viewModel.tileAudio[index].volume },
                            set: {
                                viewModel.tileAudio[index].volume = $0
                                viewModel.applyTileAudio(at: index)
                            }
                        ),
                        in: 0...1
                    )
                    .controlSize(.mini)
                    .disabled(tile.isMuted)
                }

                HStack(spacing: 6) {
                    Text("L")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { viewModel.tileAudio[index].pan },
                            set: {
                                viewModel.tileAudio[index].pan = $0
                                viewModel.applyTileAudio(at: index)
                            }
                        ),
                        in: -1...1
                    )
                    .controlSize(.mini)
                    .disabled(tile.isMuted)
                    Text("R")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(minWidth: 210)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.25)))
            .opacity(tile.isMuted ? 0.55 : 1)
        }
    }

    private var controls: some View {
        HStack {
            Button {
                viewModel.togglePlayPauseAll()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .help(viewModel.isPlaying ? "一時停止（Space）" : "再生（Space）")
            .accessibilityLabel(viewModel.isPlaying ? "一時停止" : "再生")

            Text(formatTime(viewModel.commonCurrentTime))
                .font(.caption.monospacedDigit())
            Slider(value: $viewModel.commonCurrentTime, in: 0...max(viewModel.commonDuration, 0.1)) { isEditing in
                viewModel.commonSliderEditingChanged(isEditing: isEditing)
            }
            Text(formatTime(viewModel.commonDuration))
                .font(.caption.monospacedDigit())
        }
        .padding()
        .background(.regularMaterial)
    }

    private func handleKeyPress(press: KeyPress) -> KeyPress.Result {
        if let digit = press.key.character.wholeNumberValue {
            viewModel.seekAll(toPercentage: Double(digit) / 10.0)
            return .handled
        }
        switch press.key {
        case .escape:
            if showShortcutHelp {
                showShortcutHelp = false
            } else if isAudioConsoleVisible {
                withAnimation(.easeOut(duration: 0.18)) { isAudioConsoleVisible = false }
            } else {
                coordinator.close()
            }
            return .handled
        case "?":
            showShortcutHelp.toggle()
            return .handled
        case "m", "M":
            withAnimation(.easeOut(duration: 0.18)) { isAudioConsoleVisible.toggle() }
            return .handled
        case .space:
            if press.modifiers.contains(.option) {
                coordinator.close()
                return .handled
            }
            break
        default:
            break
        }

        if MediaShortcutSettings.matches(.videoPlayPause, press: press) {
            viewModel.togglePlayPauseAll()
            return .handled
        } else if MediaShortcutSettings.matches(.videoRandomSeek, press: press) {
            viewModel.seekAllToRandomTime()
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekBack10, press: press) {
            viewModel.seekAll(by: -10)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekBack5, press: press) {
            viewModel.seekAll(by: -5)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekForward5, press: press) {
            viewModel.seekAll(by: 5)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekForward10, press: press) {
            viewModel.seekAll(by: 10)
            return .handled
        }

        return .ignored
    }

    private func formatTime(_ time: Double) -> String {
        let seconds = Int(time)
        guard seconds >= 0 else { return "0:00" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
