import SwiftUI


struct StorageManagerView: View {
    @StateObject private var viewModel: StorageViewModel
    @Environment(\.dismiss) var dismiss

    init(dataManager: LibraryViewModel) {
        _viewModel = StateObject(
            wrappedValue: StorageViewModel(libraryViewModel: dataManager)
        )
    }

    var body: some View {
        VStack(spacing: 18) {
            SheetHeader(
                icon: "internaldrive",
                title: "ストレージ管理",
                subtitle: "このアプリがMac内に保存しているデータの内訳"
            )

            VStack(alignment: .leading, spacing: 14) {
                usageBar

                breakdownRow(
                    color: Self.usageColors[0],
                    label: "取り込み済みメディア",
                    size: viewModel.usage.videosSize
                )
                breakdownRow(
                    color: Self.usageColors[1],
                    label: "軽量版（プロキシ）動画",
                    size: viewModel.usage.proxiesSize
                )
                breakdownRow(
                    color: Self.usageColors[2],
                    label: "退避された元動画",
                    size: viewModel.usage.downloadsSize
                )

                Divider()

                HStack {
                    Text("総使用容量")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(viewModel.formatBytes(viewModel.usage.appTotalSize))
                        .font(.appTitle.bold())
                        .monospacedDigit()
                        .foregroundStyle(
                            viewModel.usage.appTotalSize > 10_000_000_000
                                ? .red
                                : .primary
                        )
                }
            }
            .dashboardCard()

            if viewModel.isOptimizing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(viewModel.optimizationMessage)
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                VStack(spacing: 10) {
                    Button(action: viewModel.cleanupMissingFiles) {
                        Label("リンク切れメディアを整理", systemImage: "link.badge.minus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Text("Mac上の元ファイルが削除されて「見つかりません」になったデータを一括整理します．")
                        .font(.appCaption)
                        .foregroundStyle(NeomorphicTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: viewModel.removeDuplicates) {
                        Label("重複動画を検出して削除", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Text("タイトルが違っても内容が完全に一致する動画を自動で整理します．")
                        .font(.appCaption)
                        .foregroundStyle(NeomorphicTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button(action: viewModel.openDataFolder) {
                            Label("データフォルダを開く", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        Button(action: viewModel.openTemporaryFolder) {
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
        .appSheet()
        .onAppear(perform: viewModel.refreshUsage)
        .alert("クリーンアップ完了", isPresented: $viewModel.isShowingResultAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.resultMessage)
        }
    }

    /// 内訳の3区分。色相ではなく明るさの段階で見分ける（無彩色のまま、凡例と棒を対応づけられる）。
    private static let usageColors: [Color] = [
        NeomorphicTheme.ink.opacity(0.90),
        NeomorphicTheme.ink.opacity(0.55),
        NeomorphicTheme.ink.opacity(0.28),
    ]

    // 内訳を色分けして示す比率バー
    private var usageBar: some View {
        GeometryReader { geo in
            let total = max(
                Double(
                    viewModel.usage.videosSize
                        + viewModel.usage.proxiesSize
                        + viewModel.usage.downloadsSize
                ),
                1
            )
            HStack(spacing: 2) {
                segment(
                    width: geo.size.width * Double(viewModel.usage.videosSize) / total,
                    color: Self.usageColors[0]
                )
                segment(
                    width: geo.size.width * Double(viewModel.usage.proxiesSize) / total,
                    color: Self.usageColors[1]
                )
                segment(
                    width: geo.size.width * Double(viewModel.usage.downloadsSize) / total,
                    color: Self.usageColors[2]
                )
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
                .fill(color)
                .frame(width: width)
        }
    }

    private func breakdownRow(color: Color, label: String, size: Int64) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.appBody)
            Spacer()
            Text(viewModel.formatBytes(size))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
    }

}
