import SwiftUI


struct StorageManagerView: View {
    @ObservedObject var dataManager: VideoDataManager
    @Environment(\.dismiss) var dismiss

    @State private var videosSize: Int64 = 0
    @State private var proxiesSize: Int64 = 0
    @State private var downloadsSize: Int64 = 0
    @State private var appTotalSize: Int64 = 0

    @State private var isOptimizing = false
    @State private var optimizationMessage = ""

    @State private var showingResultAlert = false
    @State private var resultMessage = ""

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                IconTile(icon: "internaldrive.fill", tint: .indigo, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ストレージ管理")
                        .font(.title3.bold())
                    Text("このアプリがMac内に保存しているデータの内訳")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 14) {
                usageBar

                breakdownRow(color: .blue, label: "取り込み済みメディア", size: videosSize)
                breakdownRow(color: .teal, label: "軽量版（プロキシ）動画", size: proxiesSize)
                breakdownRow(color: .orange, label: "退避された元動画", size: downloadsSize)

                Divider()

                HStack {
                    Text("総使用容量")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(formatBytes(appTotalSize))
                        .font(.title3.bold())
                        .monospacedDigit()
                        .foregroundStyle(appTotalSize > 10_000_000_000 ? .red : .primary)
                }
            }
            .dashboardCard()

            if isOptimizing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(optimizationMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                VStack(spacing: 10) {
                    Button(action: removeDuplicates) {
                        Label("重複動画を検出して削除", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("タイトルが違っても内容が完全に一致する動画を自動で整理します。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button(action: { dataManager.openAppRootFolderInFinder() }) {
                            Label("データフォルダを開く", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        Button(action: { dataManager.openTempFolderInFinder() }) {
                            Label("一時キャッシュを開く", systemImage: "folder.badge.gearshape")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480, height: 500)
        .onAppear(perform: calculateSizes)
        .alert("クリーンアップ完了", isPresented: $showingResultAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(resultMessage)
        }
    }

    // 内訳を色分けして示す比率バー
    private var usageBar: some View {
        GeometryReader { geo in
            let total = max(Double(videosSize + proxiesSize + downloadsSize), 1)
            HStack(spacing: 2) {
                segment(width: geo.size.width * Double(videosSize) / total, color: .blue)
                segment(width: geo.size.width * Double(proxiesSize) / total, color: .teal)
                segment(width: geo.size.width * Double(downloadsSize) / total, color: .orange)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func segment(width: CGFloat, color: Color) -> some View {
        if width >= 1 {
            Rectangle()
                .fill(color.gradient)
                .frame(width: width)
        }
    }

    private func breakdownRow(color: Color, label: String, size: Int64) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12))
            Spacer()
            Text(formatBytes(size))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
    }

    private func calculateSizes() {
        Task {
            let sizes = await dataManager.getStorageUsage()
            self.videosSize = sizes.videosSize
            self.proxiesSize = sizes.proxiesSize
            self.downloadsSize = sizes.downloadsSize
            self.appTotalSize = sizes.appTotalSize
        }
    }

    private func removeDuplicates() {
        isOptimizing = true
        optimizationMessage = "重複している動画を解析し、削除しています..."

        Task {
            let removedCount = await MainActor.run {
                dataManager.removeDuplicateVideos()
            }

            await MainActor.run {
                calculateSizes()
                isOptimizing = false
                resultMessage = "\(removedCount) 件の重複動画を検知し、削除しました。\n(関連するゴミファイルも同時に一掃しました)"
                showingResultAlert = true
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
