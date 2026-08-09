import SwiftUI

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
