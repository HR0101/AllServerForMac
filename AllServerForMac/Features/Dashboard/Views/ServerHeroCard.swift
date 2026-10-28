import SwiftUI

// MARK: - サーバーの状態と接続案内
struct ServerHeroCard: View {
  @ObservedObject var webServerManager: ServerViewModel

  var showConnectionSettings: () -> Void
  var showSecuritySettings: () -> Void
  var showAccessLog: () -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      // 下に続くホームの2カラム（左右とも均等幅）と縦のラインを揃えるため，こちらも均等に割る．
      // 高さも揃えて，短い方のカードの下に空白が残らないようにする．
      HStack(alignment: .top, spacing: DS.cardSpacing) {
        serverStatusCard.frame(minWidth: 380, maxWidth: .infinity)
        settingsSummaryCard.frame(minWidth: 380, maxWidth: .infinity)
      }
      .fixedSize(horizontal: false, vertical: true)
      VStack(spacing: DS.cardSpacing) {
        serverStatusCard
        settingsSummaryCard
      }
    }
  }

  private var serverStatusCard: some View {
    NeomorphicTile(padding: 24) {
      VStack(alignment: .leading, spacing: 18) {
        CardHeader(icon: "network", tint: NeomorphicTheme.accent, title: "サーバーの状態")
        HStack(spacing: 12) {
          Image(systemName: webServerManager.isRunning ? "dot.radiowaves.left.and.right" : "pause.circle")
            .foregroundStyle(webServerManager.isRunning ? NeomorphicTheme.accent : NeomorphicTheme.muted)
          Text(webServerManager.isRunning ? "配信中" : "停止中")
            .font(.system(size: 30, weight: .bold, design: .default))
          Spacer()
          Button(action: toggleServer) {
            Label(webServerManager.isRunning ? "停止" : "開始", systemImage: "power")
              .font(.headline)
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
          }
          .buttonStyle(.borderedProminent)
          .accessibilityLabel(webServerManager.isRunning ? "サーバーを停止" : "サーバーを開始")
        }
        Text(webServerManager.isRunning
          ? "同じWi-Fi内の端末から動画・画像を閲覧できます．"
          : "「開始」を押すと，iPhoneやブラウザから接続できます．")
          .font(.callout)
          .foregroundStyle(NeomorphicTheme.muted)
          .fixedSize(horizontal: false, vertical: true)

        if !webServerManager.statusMessage.isEmpty,
           webServerManager.statusMessage.contains("❌") || webServerManager.statusMessage.contains("⚠️") {
          Label(webServerManager.statusMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }

        Divider()
        VStack(alignment: .leading, spacing: 10) {
          Label("接続方法", systemImage: "iphone.and.arrow.forward")
            .font(.headline)
          Text("1．端末をMacと同じWi-Fiに接続します．")
          Text("2．iPhoneアプリでこのMacを選ぶか，ブラウザで接続先を開きます．")
          Text(webServerManager.authEnabled
            ? "3．下の「PIN認証」に表示される6桁のPINを入力します．"
            : "PIN認証は無効です．同じWi-Fi内の端末はPINなしで接続できます．")
          if webServerManager.isRunning, let url = webServerManager.serverURL {
            Text("ブラウザの接続先（クリックでコピー）")
              .font(.caption)
              .foregroundStyle(NeomorphicTheme.muted)
            CopyableText(text: url, font: .system(.body, design: .monospaced), tint: NeomorphicTheme.accent)
            Text("稼働時間：\(webServerManager.uptimeString)")
              .foregroundStyle(NeomorphicTheme.muted)
          } else {
            Text("接続先のURLはサーバー開始後に表示されます．")
              .foregroundStyle(NeomorphicTheme.muted)
          }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var settingsSummaryCard: some View {
    NeomorphicTile(padding: 22) {
      VStack(alignment: .leading, spacing: 14) {
        CardHeader(icon: "slider.horizontal.3", tint: NeomorphicTheme.accent,
          title: "設定の概要", subtitle: "項目を押すと設定やログを開きます")
        summaryButton("接続設定", value: "ポート \(webServerManager.targetPort)",
          detail: "接続に使う番号を確認・変更", icon: "network", action: showConnectionSettings)
        summaryButton("PIN認証", value: webServerManager.authEnabled ? "PINが必要" : "PINなしで接続可能",
          detail: "接続用PINと認証設定を確認", icon: "lock.shield", action: showSecuritySettings)
        summaryButton("自動停止", value: webServerManager.autoStopEnabled
          ? "開始から\(webServerManager.autoStopIntervalMinutes)分で終了" : "自動では停止しません",
          detail: "サーバー開始からアプリ終了までの時間", icon: "timer", action: showConnectionSettings)
        summaryButton("アクセスログ", value: "直近\(webServerManager.accessLogs.count)件のリクエスト",
          detail: "接続端末からの通信履歴を開く", icon: "list.bullet.rectangle", action: showAccessLog)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private func summaryButton(_ title: String, value: String, detail: String,
    icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: 12) {
        Image(systemName: icon)
          .font(.title3)
          .foregroundStyle(NeomorphicTheme.accent)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 5) {
          Text(title).font(.callout.weight(.semibold))
          Text(value).font(.body.weight(.semibold))
          Text(detail).font(.caption).foregroundStyle(NeomorphicTheme.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(NeomorphicTheme.muted)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(NeomorphicTheme.surface, in: RoundedRectangle(cornerRadius: 12))
      .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
  }

  private func toggleServer() {
    if webServerManager.isRunning {
      webServerManager.stopServer()
    } else {
      webServerManager.startServer()
    }
  }
}
