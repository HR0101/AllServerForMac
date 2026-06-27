import Foundation
import Swifter
import AVFoundation
import AppKit
import Darwin
import Combine
import MediaServerKit


class WebServerManager: NSObject, ObservableObject, NetServiceDelegate {
    let server = HttpServer()
    private var netService: NetService?
    
    weak var dataManager: VideoDataManager?
    
    @Published var statusMessage: String = "停止中"
    @Published var serverURL: String?
    var isRunning: Bool { serverStartTime != nil }
    
    @Published var serverStartTime: Date?
    @Published var uptimeString: String = "00:00:00"
    private var timerCancellable: AnyCancellable?
    
    @Published var autoStopEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoStopEnabled, forKey: "autoStopEnabled")
        }
    }
    @Published var autoStopIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(autoStopIntervalMinutes, forKey: "autoStopIntervalMinutes")
        }
    }

    @Published var scheduleEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(scheduleEnabled, forKey: "scheduleEnabled")
            if !scheduleEnabled { removeSchedule() }
        }
    }
    @Published var scheduleStartTime: Date {
        didSet { UserDefaults.standard.set(scheduleStartTime, forKey: "scheduleStartTime") }
    }
    @Published var scheduleStopTime: Date {
        didSet { UserDefaults.standard.set(scheduleStopTime, forKey: "scheduleStopTime") }
    }
    @Published var scheduleStatusMessage: String = ""


    @Published var targetPort: Int {
        didSet {
            UserDefaults.standard.set(targetPort, forKey: "serverPort")
        }
    }

    @Published var authEnabled: Bool = true {
        didSet {
            authEnabledCache = authEnabled
            UserDefaults.standard.set(authEnabled, forKey: "authEnabled")
        }
    }
    @Published var authPIN: String = "" {
        didSet {
            authPINCache = authPIN
            UserDefaults.standard.set(authPIN, forKey: "authPIN")
        }
    }
    // バックグラウンドスレッドから安全に読むためのスナップショット
    private var authEnabledCache = true
    private var authPINCache = ""

    @Published var accessLogs: [AccessLogEntry] = []
    private let maxAccessLogs = 200

    /// アップロード受け入れの上限（ディスク枯渇の防止用）。20GB。
    let maxUploadBytes = 21_474_836_480

    init(dataManager: VideoDataManager) {
        self.dataManager = dataManager

        let savedPort = UserDefaults.standard.integer(forKey: "serverPort")
        self.targetPort = savedPort == 0 ? 8080 : savedPort

        self.autoStopEnabled = UserDefaults.standard.bool(forKey: "autoStopEnabled")
        let savedInterval = UserDefaults.standard.integer(forKey: "autoStopIntervalMinutes")
        self.autoStopIntervalMinutes = savedInterval == 0 ? 60 : savedInterval

        self.scheduleEnabled = UserDefaults.standard.bool(forKey: "scheduleEnabled")
        let cal = Calendar.current
        self.scheduleStartTime = (UserDefaults.standard.object(forKey: "scheduleStartTime") as? Date)
            ?? cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        self.scheduleStopTime = (UserDefaults.standard.object(forKey: "scheduleStopTime") as? Date)
            ?? cal.date(bySettingHour: 23, minute: 0, second: 0, of: Date()) ?? Date()

        let authEnabledValue = UserDefaults.standard.object(forKey: "authEnabled") as? Bool ?? true
        self.authEnabled = authEnabledValue
        let savedPIN = UserDefaults.standard.string(forKey: "authPIN") ?? ""
        let pin = savedPIN.isEmpty ? String(format: "%06d", Int.random(in: 0...999999)) : savedPIN
        self.authPIN = pin
        // didSet は init 中に発火しないため、キャッシュと永続化を手動で行う
        self.authEnabledCache = authEnabledValue
        self.authPINCache = pin
        UserDefaults.standard.set(pin, forKey: "authPIN")

        super.init()
        print("✅ [LIFECYCLE] WebServerManager initialized.")
        setupRoutes()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionOrAppTermination),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionOrAppTermination),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )

        if scheduleEnabled && isWithinScheduleWindow(Date()) {
            startServer()
        }
    }

    deinit {
        print("🛑 [LIFECYCLE] WebServerManager deinitialized.")
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Auth & Access Log
    func regeneratePIN() {
        authPIN = String(format: "%06d", Int.random(in: 0...999999))
    }

    private func extractPIN(from request: HttpRequest) -> String? {
        if let header = request.headers["x-auth-pin"], !header.isEmpty { return header }
        if let q = request.queryParams.first(where: { $0.0 == "pin" })?.1, !q.isEmpty { return q }
        if let cookie = request.headers["cookie"] {
            for part in cookie.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2, kv[0] == "pin", !kv[1].isEmpty { return kv[1] }
            }
        }
        return nil
    }

    // MARK: - 総当たり攻撃対策
    // IP ごとに連続失敗回数を記録し、一定回数を超えたら指数バックオフでロックアウトする。
    // サーバーのワーカースレッドから触られるため NSLock で保護する。
    private let authLock = NSLock()
    private var authFailures: [String: (count: Int, lockedUntil: Date?)] = [:]
    private let maxAttemptsBeforeLockout = 5

    private func isLockedOut(_ ip: String) -> Bool {
        authLock.lock(); defer { authLock.unlock() }
        if let until = authFailures[ip]?.lockedUntil, until > Date() { return true }
        return false
    }

    /// PIN を実際に提示したリクエストの成否のみを記録する（PIN 未提示の初回アクセスは数えない）
    private func recordAuthResult(ip: String, success: Bool) {
        authLock.lock(); defer { authLock.unlock() }
        if success {
            authFailures[ip] = nil
        } else {
            var entry = authFailures[ip] ?? (count: 0, lockedUntil: nil)
            entry.count += 1
            // 5回目以降は失敗のたびに 30s → 60s → 120s … 最大 1 時間ロック
            if let delay = PINSecurity.lockoutDelay(failCount: entry.count, maxAttempts: maxAttemptsBeforeLockout) {
                entry.lockedUntil = Date().addingTimeInterval(delay)
            }
            authFailures[ip] = entry
        }
    }

    private func isAuthorized(_ request: HttpRequest) -> Bool {
        if !authEnabledCache { return true }
        let ip = request.address ?? "unknown"
        if isLockedOut(ip) { return false }
        // PIN が無いリクエスト（ログイン前の初回アクセス等）は失敗としてカウントしない
        guard let pin = extractPIN(from: request) else { return false }
        let ok = PINSecurity.constantTimeEquals(pin, authPINCache)
        recordAuthResult(ip: ip, success: ok)
        return ok
    }

    func logAccess(_ request: HttpRequest, authorized: Bool) {
        let ip = request.address ?? "unknown"
        let method = request.method
        let path = request.path
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.accessLogs.insert(AccessLogEntry(date: Date(), ip: ip, method: method, path: path, authorized: authorized), at: 0)
            if self.accessLogs.count > self.maxAccessLogs {
                self.accessLogs.removeLast(self.accessLogs.count - self.maxAccessLogs)
            }
        }
    }

    /// 認証チェック付きでルートハンドラを包む
    func protected(_ handler: @escaping (HttpRequest) -> HttpResponse) -> (HttpRequest) -> HttpResponse {
        return { [weak self] request in
            guard let self = self else { return .internalServerError }
            let ok = self.isAuthorized(request)
            self.logAccess(request, authorized: ok)
            if !ok {
                let body = Array(#"{"error":"auth_required"}"#.utf8)
                return .raw(401, "Unauthorized",
                            ["Content-Type": "application/json", "WWW-Authenticate": "PIN"],
                            { try? $0.write(body) })
            }
            return handler(request)
        }
    }

    // MARK: - Server Control
    func startServer() {
        guard !server.operating else { return }
        
        let portToUse = in_port_t(targetPort)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                // priority のデフォルトは .background。これだと接続処理スレッドが
                // 強くスロットリングされ、サムネイル生成などでワーカースレッドが埋まると
                // 動画ストリーミングのリクエストにスレッドが割り当てられず固まってしまう
                // （アルバムを開いた直後に同時再生が始まらない原因）。
                // .userInitiated に上げてワーカースレッドを十分確保する。
                try self.server.start(portToUse, forceIPv4: true, priority: .userInitiated)
                let actualPort = try self.server.port()
                DispatchQueue.main.async {
                    self.targetPort = Int(actualPort)
                    guard let computerName = Host.current().localizedName else {
                        self.statusMessage = "❌ [FATAL] Could not get computer name."; self.server.stop(); return
                    }
                    let userName = NSUserName()
                    let uniqueServiceName = "\(computerName) (\(userName))"
                    self.netService = NetService(domain: "local.", type: "_myvideoserver._tcp.", name: uniqueServiceName, port: Int32(actualPort))
                    self.netService?.delegate = self
                    self.netService?.publish()
                    
                    self.serverStartTime = Date()
                    self.startUptimeTimer()
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "❌ 起動失敗: ポート \(portToUse) は既に使用されている可能性があります。"
                }
            }
        }
    }

    private func startUptimeTimer() {
        self.timerCancellable?.cancel()
        self.timerCancellable = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self = self, let start = self.serverStartTime else { return }
            let diff = Int(Date().timeIntervalSince(start))

            if self.autoStopEnabled {
                let limitSeconds = self.autoStopIntervalMinutes * 60
                if diff >= limitSeconds {
                    self.stopServerInternal()
                    NSApplication.shared.terminate(nil)
                    return
                }
            }

            if self.scheduleEnabled {
                let now = Date()
                let cal = Calendar.current
                let stop = cal.dateComponents([.hour, .minute], from: self.scheduleStopTime)
                let cur = cal.dateComponents([.hour, .minute], from: now)
                if cur.hour == stop.hour && cur.minute == stop.minute {
                    self.stopServerInternal()
                    NSApplication.shared.terminate(nil)
                    return
                }
            }

            let h = diff / 3600
            let m = (diff % 3600) / 60
            let s = diff % 60
            self.uptimeString = String(format: "%02d:%02d:%02d", h, m, s)
        }
    }

    @objc func stopServer() { stopServerInternal() }

    func stopServerInternal() {
        netService?.stop(); netService = nil
        server.stop()
        
        DispatchQueue.main.async {
            self.serverStartTime = nil
            self.timerCancellable?.cancel()
            self.uptimeString = "00:00:00"
            self.serverURL = nil
            self.statusMessage = "🛑 サーバー停止"
        }
    }
    
    @objc private func handleSessionOrAppTermination() { stopServerInternal() }

    // MARK: - スケジュール起動/停止
    /// 現在時刻が起動時刻〜停止時刻の時間帯に入っているか（日をまたぐ設定にも対応）
    func isWithinScheduleWindow(_ now: Date) -> Bool {
        let cal = Calendar.current
        let s = cal.dateComponents([.hour, .minute], from: scheduleStartTime)
        let e = cal.dateComponents([.hour, .minute], from: scheduleStopTime)
        let n = cal.dateComponents([.hour, .minute], from: now)
        let startMin = (s.hour ?? 0) * 60 + (s.minute ?? 0)
        let stopMin  = (e.hour ?? 0) * 60 + (e.minute ?? 0)
        let nowMin   = (n.hour ?? 0) * 60 + (n.minute ?? 0)
        if startMin == stopMin { return false }
        if startMin < stopMin { return nowMin >= startMin && nowMin < stopMin }
        return nowMin >= startMin || nowMin < stopMin // 日をまたぐ場合
    }

    private var launchAgentLabel: String {
        (Bundle.main.bundleIdentifier ?? "com.allserverformac.app") + ".autostart"
    }
    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    /// 設定画面の「適用」ボタンから呼ぶ。LaunchAgent登録 + スリープ起床(pmset)を設定する
    func applySchedule() {
        installLaunchAgent()
        scheduleWake()
    }

    /// スケジュール解除（LaunchAgent削除 + pmset起床解除）
    func removeSchedule() {
        removeLaunchAgent()
        cancelWake()
        DispatchQueue.main.async { self.scheduleStatusMessage = "スケジュールを解除しました。" }
    }

    private func installLaunchAgent() {
        let cal = Calendar.current
        let comp = cal.dateComponents([.hour, .minute], from: scheduleStartTime)
        let hour = comp.hour ?? 9
        let minute = comp.minute ?? 0
        let appPath = Bundle.main.bundlePath

        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": ["/usr/bin/open", appPath],
            "StartCalendarInterval": ["Hour": hour, "Minute": minute],
            "RunAtLoad": false
        ]

        do {
            let dir = launchAgentURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: launchAgentURL)
            reloadLaunchAgent()
            let timeStr = String(format: "%02d:%02d", hour, minute)
            DispatchQueue.main.async {
                self.scheduleStatusMessage = "✅ 毎日 \(timeStr) に自動起動するよう登録しました。"
            }
        } catch {
            DispatchQueue.main.async {
                self.scheduleStatusMessage = "❌ 自動起動の登録に失敗: \(error.localizedDescription)"
            }
        }
    }

    private func reloadLaunchAgent() {
        let path = launchAgentURL.path
        _ = runProcess("/bin/launchctl", ["unload", path])   // 既存があれば解除（失敗は無視）
        _ = runProcess("/bin/launchctl", ["load", "-w", path])
    }

    private func removeLaunchAgent() {
        let path = launchAgentURL.path
        _ = runProcess("/bin/launchctl", ["unload", path])
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    /// スリープ中でも起動時刻にMacを起こす（pmset / 管理者権限が必要）。起動2分前に起床させる
    private func scheduleWake() {
        let cal = Calendar.current
        let comp = cal.dateComponents([.hour, .minute], from: scheduleStartTime)
        var total = (comp.hour ?? 9) * 60 + (comp.minute ?? 0) - 2
        if total < 0 { total += 24 * 60 }
        let timeStr = String(format: "%02d:%02d:00", total / 60, total % 60)
        runAdminShell("/usr/bin/pmset repeat wakeorpoweron MTWRFSU \(timeStr)") { ok in
            DispatchQueue.main.async {
                if !ok {
                    self.scheduleStatusMessage = "⚠️ 自動起動は登録しましたが、スリープ起床(pmset)の設定がキャンセル/失敗しました。"
                }
            }
        }
    }

    private func cancelWake() {
        runAdminShell("/usr/bin/pmset repeat cancel") { _ in }
    }

    /// 管理者権限でシェルコマンドを実行（GUIでパスワード入力を求める）
    private func runAdminShell(_ command: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
            let source = "do shell script \"\(escaped)\" with administrator privileges"
            var errorDict: NSDictionary?
            if let script = NSAppleScript(source: source) {
                script.executeAndReturnError(&errorDict)
                completion(errorDict == nil)
            } else {
                completion(false)
            }
        }
    }

    @discardableResult
    private func runProcess(_ launchPath: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    func netServiceDidPublish(_ sender: NetService) {
        let ipAddress = getIPAddress() ?? "N/A"
        self.serverURL = "http://\(ipAddress):\(sender.port)"
        self.statusMessage = "✅ 実行中: http://\(ipAddress):\(sender.port)"
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        self.statusMessage = "❌ Bonjour publish failed."
        self.server.stop()
    }
}
