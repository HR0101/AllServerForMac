import AppKit
import Charts
import SwiftUI

// MARK: - サーバー状態ヒーローカード
struct ServerHeroCard: View {
    @ObservedObject var webServerManager: ServerViewModel
    /// ダッシュボード側の段数。ヒーローカードも同じ幅の判断に合わせて 1〜3 段に組み替える。
    var columnCount: Int = 2

    var body: some View {
        Group {
            switch columnCount {
            case ...1:
                VStack(spacing: 18) {
                    serverControlTile
                    statusTileRow
                    welcomePill
                    analyticsTile
                }
            case 2:
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        serverControlTile
                        statusTileRow
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 18) {
                        welcomePill
                        analyticsTile
                    }
                    .frame(maxWidth: .infinity)
                }
            default:
                // 3 段以上のときは要約タイルを 3 段目に縦積みして、横に伸びた余白を埋める。
                HStack(alignment: .top, spacing: 18) {
                    serverControlTile
                        .frame(maxWidth: .infinity)

                    VStack(spacing: 18) {
                        welcomePill
                        analyticsTile
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 18) {
                        autoStopTile
                        pinTile
                        portTile
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: webServerManager.isRunning)
    }

    private var statusTileRow: some View {
        HStack(spacing: 18) {
            autoStopTile
            pinTile
            portTile
        }
    }

    private var autoStopTile: some View {
        NeomorphicSceneTile(
            icon: "timer",
            title: "自動停止",
            value: webServerManager.autoStopEnabled ? "\(webServerManager.autoStopIntervalMinutes) 分後" : "オフ",
            tint: .orange
        )
    }

    private var pinTile: some View {
        NeomorphicSceneTile(
            icon: "lock.shield",
            title: "PIN 認証",
            value: webServerManager.authEnabled ? "必須" : "なし",
            tint: .green
        )
    }

    private var portTile: some View {
        NeomorphicSceneTile(
            icon: "network",
            title: "ポート",
            value: "\(webServerManager.targetPort)",
            tint: .blue
        )
    }

    private var serverControlTile: some View {
        NeomorphicTile(padding: 24) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Mac Media Server")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(NeomorphicTheme.ink)
                            Text(webServerManager.isRunning ? "LAN に配信中" : "待機中")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(NeomorphicTheme.muted)
                        }
                    } icon: {
                        Image(systemName: "snowflake")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(NeomorphicTheme.ink)
                    }

                    Spacer()

                    Button(action: toggleServer) {
                        HStack(spacing: 8) {
                            Text(webServerManager.isRunning ? "On." : "Off.")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                            Image(systemName: "power")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(webServerManager.isRunning ? .white : NeomorphicTheme.muted)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(webServerManager.isRunning ? NeomorphicTheme.accent : NeomorphicTheme.surface)
                                .shadow(color: .white.opacity(0.9), radius: 4, x: -3, y: -3)
                                .shadow(color: NeomorphicTheme.shadow.opacity(0.28), radius: 6, x: 4, y: 4)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(webServerManager.isRunning ? "サーバーを停止" : "サーバーを開始")
                    .accessibilityLabel(webServerManager.isRunning ? "サーバーを停止" : "サーバーを開始")
                }

                HStack(spacing: 8) {
                    Image(systemName: "clock")
                    Text(webServerManager.isRunning ? webServerManager.uptimeString : "LAN内の視聴を待機")
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(NeomorphicTheme.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(NeomorphicTheme.surface)
                        .shadow(color: .white.opacity(0.9), radius: 3, x: -2, y: -2)
                        .shadow(color: NeomorphicTheme.shadow.opacity(0.22), radius: 5, x: 3, y: 3)
                )

                Spacer(minLength: 0)

                ServerArcGauge(isRunning: webServerManager.isRunning)
                    .frame(maxWidth: .infinity)

                Spacer(minLength: 0)

                statusDetail
            }
        }
    }

    @ViewBuilder
    private var statusDetail: some View {
        if webServerManager.isRunning, let url = webServerManager.serverURL {
            CopyableText(text: url, font: .system(size: 12, design: .monospaced), tint: NeomorphicTheme.accent)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if webServerManager.statusMessage.contains("❌") {
            Text(webServerManager.statusMessage.replacingOccurrences(of: "❌ ", with: ""))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            Text("「開始」を押すと、同じWi-Fi内のiPhoneやブラウザから視聴できます")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(NeomorphicTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var welcomePill: some View {
        // ここは 1 行ぶんの高さで固定し、余った高さは下の「サーバーの状態」に吸わせる。
        NeomorphicTile(padding: 15) {
            HStack(spacing: 14) {
                Circle()
                    .fill(NeomorphicTheme.accent)
                    .frame(width: 46, height: 46)
                    .overlay(
                        Image(systemName: "play.rectangle.stack.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: .white.opacity(0.9), radius: 4, x: -3, y: -3)
                    .shadow(color: NeomorphicTheme.shadow.opacity(0.28), radius: 6, x: 4, y: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(webServerManager.isRunning ? "視聴できます" : "停止中")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(NeomorphicTheme.ink)
                    Text(webServerManager.isRunning
                         ? "同じ Wi-Fi の iPhone・ブラウザから接続できます"
                         : "「開始」を押すと配信をはじめます")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(NeomorphicTheme.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var analyticsTile: some View {
        NeomorphicTile(padding: 22) {
            // 高さが余ったときは Spacer の側で吸って、行間が均等に開くようにする。
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(NeomorphicTheme.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("サーバーの状態")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(NeomorphicTheme.ink)
                        Text("いまの設定と稼働状況")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(NeomorphicTheme.muted)
                    }
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 17)

                VStack(spacing: 0) {
                    NeomorphicAnalyticsRow(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "LAN 配信",
                        value: webServerManager.isRunning ? "稼働中・ポート \(webServerManager.targetPort)" : "停止中・ポート \(webServerManager.targetPort)"
                    )
                    Spacer(minLength: 12)
                    NeomorphicAnalyticsRow(
                        icon: "lock.shield",
                        title: "PIN 認証",
                        value: webServerManager.authEnabled ? "必須（PIN を知っている人だけ）" : "なし（同じ Wi-Fi なら誰でも）"
                    )
                    Spacer(minLength: 12)
                    NeomorphicAnalyticsRow(
                        icon: "list.bullet.rectangle",
                        title: "アクセスログ",
                        value: "\(webServerManager.accessLogs.count) 件を記録中"
                    )
                    Spacer(minLength: 12)
                    NeomorphicAnalyticsRow(
                        icon: "timer",
                        title: "自動停止",
                        value: webServerManager.autoStopEnabled ? "\(webServerManager.autoStopIntervalMinutes) 分後に停止" : "しない"
                    )
                }
            }
        }
    }

    private var remainingTimeString: String {
        let remaining = max(0, (webServerManager.autoStopIntervalMinutes * 60) - Int(Date().timeIntervalSince(webServerManager.serverStartTime ?? Date())))
        return String(format: "%d分 %02d秒", remaining / 60, remaining % 60)
    }
    private func toggleServer() {
        if webServerManager.isRunning {
            webServerManager.stopServer()
        } else {
            webServerManager.startServer()
        }
    }
}

private struct ServerArcGauge: View {
    let isRunning: Bool

    private let tickCount = 42
    private let startAngle = -112.0
    private let endAngle = 112.0

    var body: some View {
        ZStack {
            ForEach(0..<tickCount, id: \.self) { index in
                let ratio = Double(index) / Double(tickCount - 1)
                Capsule()
                    .fill(tickColor(for: ratio))
                    .frame(width: 3, height: ratio > 0.74 ? 28 : 22)
                    .offset(y: -82)
                    .rotationEffect(.degrees(startAngle + (endAngle - startAngle) * ratio))
            }

            VStack(spacing: 2) {
                Text(isRunning ? "Streaming" : "Standby")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(NeomorphicTheme.ink)
            }
            .offset(y: 28)
        }
        .frame(height: 190)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRunning ? "サーバー稼働中" : "サーバー待機中")
    }

    private func tickColor(for ratio: Double) -> Color {
        let activeLimit = isRunning ? 0.82 : 0.28
        if ratio > activeLimit {
            return NeomorphicTheme.shadow.opacity(0.18)
        }
        return ratio > 0.72 ? NeomorphicTheme.accent : NeomorphicTheme.ink.opacity(0.84)
    }
}

private struct NeomorphicSceneTile: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        NeomorphicTile(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(9)
                        .background(
                            Circle()
                                .fill(NeomorphicTheme.surface)
                                .shadow(color: .white.opacity(0.9), radius: 3, x: -2, y: -2)
                                .shadow(color: NeomorphicTheme.shadow.opacity(0.24), radius: 5, x: 3, y: 3)
                        )
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(NeomorphicTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(value)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(NeomorphicTheme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        }
    }
}

private struct NeomorphicAnalyticsRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NeomorphicTheme.muted)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(NeomorphicTheme.surface)
                        .shadow(color: .white.opacity(0.92), radius: 3, x: -2, y: -2)
                        .shadow(color: NeomorphicTheme.shadow.opacity(0.24), radius: 5, x: 3, y: 3)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(NeomorphicTheme.ink)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(NeomorphicTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(NeomorphicTheme.surface)
                .shadow(color: .white.opacity(0.92), radius: 5, x: -4, y: -4)
                .shadow(color: NeomorphicTheme.shadow.opacity(0.25), radius: 8, x: 5, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.58), lineWidth: 1)
        )
    }
}

/// ライブ配信機器のレベルメーターを模した表示。ネットワークの稼働状態だけを表すため，
/// 実測値のように見せるランダムなアニメーションは使いません。
private struct BroadcastLevelMeter: View {
    let isRunning: Bool
    let port: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NETWORK LEVEL")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("TX / RX")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            levelRow(label: "TX", activeCount: isRunning ? 13 : 0)
            levelRow(label: "RX", activeCount: isRunning ? 10 : 0)

            HStack(spacing: 12) {
                BroadcastStatusLabel(label: "LAN", value: isRunning ? "LINK" : "IDLE", active: isRunning)
                BroadcastStatusLabel(label: "PORT", value: "\(port)", active: true)
                BroadcastStatusLabel(label: "PIN", value: "READY", active: true)
            }
        }
    }

    private func levelRow(label: String, activeCount: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)
            ForEach(0..<16, id: \.self) { index in
                Rectangle()
                    .fill(index < activeCount ? meterColor(for: index) : Color.white.opacity(0.1))
                    .frame(width: 7, height: index.isMultiple(of: 4) ? 13 : 9)
            }
        }
    }

    private func meterColor(for index: Int) -> Color {
        index >= 12 ? DS.signalAmber : DS.tallyGreen
    }
}

private struct BroadcastStatusLabel: View {
    let label: String
    let value: String
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? DS.tallyGreen : Color.secondary)
                .frame(width: 5, height: 5)
            Text("\(label) \(value)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
