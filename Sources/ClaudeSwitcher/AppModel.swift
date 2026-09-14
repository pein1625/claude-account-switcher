import Foundation
import AppKit
import ServiceManagement
import ClaudeSwitcherCore

struct DoctorItem: Identifiable {
    enum Level { case ok, warn, fail }
    let id = UUID()
    var level: Level
    var text: String
}

struct DriftInfo: Equatable {
    var tokenEmail: String?
    var tokenUuid: String?
    var tokenAccountName: String?
    var configName: String?
}

/// Single source of truth for the UI and the background loops. Everything runs on the main actor; blocking
/// work (subprocesses, HTTP) is awaited off-thread inside the Core layer.
@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [AccountProfile] = []
    @Published var liveAccount: OAuthAccount?
    @Published var liveName: String?
    @Published var usage: [String: AccountUsage] = [:]
    @Published var records: [String: QuotaRecord] = [:]
    @Published var sessions: [Session] = []
    @Published var plan: RestartPlan?
    @Published var decision: Decision = .hold("chưa có dữ liệu")
    @Published var drift: DriftInfo?
    @Published var lastError: String?
    @Published var busyText: String?
    @Published var lastPollAt: Date?
    @Published var cli: CLI? = CLI.locate()
    @Published var hookInstalled = HookInstaller.isScriptInstalled() && HookInstaller.isSettingsWired()
    @Published var doctorItems: [DoctorItem] = []
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var autoSwitch: Bool = AppSettings.autoSwitch {
        didSet { AppSettings.defaults.set(autoSwitch, forKey: AppSettings.Key.autoSwitch.rawValue); evaluate() }
    }

    let store = AccountStore()
    let client = UsageClient()

    private var forcedExhausted: [String: Date] = [:]
    private var lastHopAt: Date?
    private var lastSwitchAt: Date?
    private var lastMarker: AccountStore.CurrentMarker?
    private var eventsOffset: UInt64 = 0
    private var lastAlive: Date = .distantPast
    private var lastDriftCheck: Date = .distantPast
    private var lastNotifiedExhausted: Date = .distantPast
    private var switchInFlight = false
    private var tasks: [Task<Void, Never>] = []
    private var pollInterval: Int = AppSettings.pollSeconds

    var busy: Bool { busyText != nil }

    // MARK: lifecycle

    func start() {
        AppSettings.register()
        store.log("app start v\(AppInfo.version) pid \(ProcessInfo.processInfo.processIdentifier)")
        usage = store.readUsageCache()
        lastMarker = store.currentMarker()
        if let m = lastMarker { lastSwitchAt = m.mtime }
        eventsOffset = store.readEvents(from: 0).offset
        reloadProfiles()
        tasks = [
            Task { [weak self] in
                while !Task.isCancelled { await self?.tick(); try? await Task.sleep(for: .seconds(2)) }
            },
            Task { [weak self] in
                while !Task.isCancelled { await self?.scanSessions(); try? await Task.sleep(for: .seconds(10)) }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    await self?.pollUsage()
                    let secs = self?.pollInterval ?? 60
                    try? await Task.sleep(for: .seconds(secs))
                }
            },
        ]
    }

    func stop() { tasks.forEach { $0.cancel() } }

    // MARK: periodic work

    func reloadProfiles() {
        profiles = store.loadProfiles()
        liveAccount = store.liveOAuthAccount()
        liveName = store.liveName(profiles: profiles, live: liveAccount)
        var recs: [String: QuotaRecord] = [:]
        for p in profiles { if let r = store.quotaRecord(p.name) { recs[p.name] = r } }
        records = recs
        cli = cli ?? CLI.locate()
    }

    private func tick() async {
        let now = Date()
        if now.timeIntervalSince(lastAlive) > 30 { store.touchAlive(now: now); lastAlive = now }
        reloadProfiles()
        detectExternalSwitch(now: now)
        prunePlan()
        ingestEvents(now: now)
        pollInterval = AppSettings.pollSeconds
        hookInstalled = HookInstaller.isScriptInstalled() && HookInstaller.isSettingsWired()
        evaluate()
    }

    /// `claude-account use` from a terminal (or the claude-as loop) rewrites `.current`; record it so
    /// session attribution stays right and the policy waits for things to settle.
    private func detectExternalSwitch(now: Date) {
        let m = store.currentMarker()
        defer { lastMarker = m }
        guard let m, let prev = lastMarker, m.name != prev.name || m.mtime != prev.mtime else { return }
        if m.name != prev.name {
            store.appendSwitch(SwitchEvent(at: m.mtime ?? now, from: prev.name, to: m.name, by: "cli"))
            store.log("external switch \(prev.name) -> \(m.name)")
            lastSwitchAt = m.mtime ?? now
            retargetPlan()
        }
    }

    private func prunePlan() {
        guard var p = store.readRestartPlan() else { plan = nil; return }
        let alive = Set(sessions.map { String($0.pid) })
        if !sessions.isEmpty {
            p.pids = p.pids.filter { alive.contains($0.key) }
        }
        if p.pids.isEmpty {
            store.writeRestartPlan(nil); plan = nil
            store.log("restart plan complete")
            return
        }
        if p != plan { store.writeRestartPlan(p) }
        plan = p
    }

    /// Sessions in the plan should land on whatever is live now; sessions already on the live account drop out.
    private func retargetPlan() {
        guard var p = store.readRestartPlan(), let live = liveName else { return }
        p.to = live
        for (pid, _) in p.pids {
            if let s = sessions.first(where: { String($0.pid) == pid }), s.account.name == live, !s.account.isAssumed {
                p.pids.removeValue(forKey: pid)
            } else {
                p.pids[pid] = live
            }
        }
        store.writeRestartPlan(p.pids.isEmpty ? nil : p)
        plan = p.pids.isEmpty ? nil : p
    }

    private func ingestEvents(now: Date) {
        let (events, offset) = store.readEvents(from: eventsOffset)
        eventsOffset = offset
        for e in events where now.timeIntervalSince(e.at) < 600 {
            let name = sessions.first { $0.pid == e.pid }?.account.name ?? liveName
            guard let name else { continue }
            let reset = usage[name]?.fiveHour?.resetsAt.flatMap { $0 > now ? $0 : nil }
                ?? records[name]?.resetsAt.flatMap { $0 > now ? $0 : nil }
                ?? now.addingTimeInterval(5 * 3600)
            forcedExhausted[name] = reset
            store.writeQuotaRecord(name, QuotaRecord(pct: 100, resetsAt: reset, recordedAt: now), now: now)
            store.log("rate_limit event pid \(e.pid) -> \(name) exhausted until \(ISO8601.string(reset))")
        }
    }

    func scanSessions() async {
        let now = Date()
        let raw = await SessionScanner.scan(now: now)
        let pids = raw.map(\.pid)
        let loops = await SessionScanner.loopFlags(pids: pids)
        let cwds = await SessionScanner.cwds(pids: pids)
        let marker = store.currentMarker()
        var history = store.readSwitches()
        if let marker, let mt = marker.mtime, !history.contains(where: { abs($0.at.timeIntervalSince(mt)) < 2 && $0.to == marker.name }) {
            history.append(SwitchEvent(at: mt, from: nil, to: marker.name, by: "marker"))
            history.sort { $0.at < $1.at }
        }
        sessions = SessionAttribution.attribute(raw, history: history, fallback: marker?.name ?? liveName, loops: loops, cwds: cwds)
    }

    /// `CLAUDE_SWITCHER_SMOKE=1`: UI smoke run without Keychain reads, network, or permission prompts.
    static let smokeMode = ProcessInfo.processInfo.environment["CLAUDE_SWITCHER_SMOKE"] == "1"

    func pollUsage(force: Bool = false) async {
        let now = Date()
        if Self.smokeMode {
            lastPollAt = now
            reloadProfiles()
            evaluate()
            return
        }
        var next = usage
        var changed = false
        for p in profiles {
            let isLive = p.name == liveName
            guard let blob = isLive ? await Keychain.readLive() : await Keychain.readSaved(p.name) else {
                next[p.name] = AccountUsage(fetchedAt: now, source: .none, error: "không đọc được Keychain", tokenExpiresAt: nil)
                changed = true
                continue
            }
            if blob.isExpired(at: now) {
                var u = next[p.name] ?? AccountUsage(fetchedAt: now, source: .recorded)
                u.error = "token hết hạn, dùng số đã ghi"
                u.tokenExpiresAt = blob.expiresAt
                u.source = u.fiveHour == nil ? .recorded : u.source
                next[p.name] = u
                changed = true
                continue
            }
            var u = await client.fetchUsage(token: blob.accessToken, now: now)
            u.tokenExpiresAt = blob.expiresAt
            if u.isFreshAPI, let five = u.fiveHour {
                store.writeQuotaRecord(p.name, QuotaRecord(pct: Int(five.pct.rounded(.down)), resetsAt: five.resetsAt, recordedAt: now), now: now)
                if let until = forcedExhausted[p.name], five.pct < AppSettings.hopAt, five.resetsAt.map({ $0 > until }) ?? true {
                    forcedExhausted.removeValue(forKey: p.name)
                }
            } else if let prev = next[p.name], prev.fiveHour != nil {
                u.fiveHour = prev.fiveHour; u.sevenDay = prev.sevenDay; u.extras = prev.extras
            }
            next[p.name] = u
            changed = true
            if isLive, now.timeIntervalSince(lastDriftCheck) > 600 {
                lastDriftCheck = now
                await checkDrift(liveToken: blob.accessToken)
            }
        }
        if changed {
            usage = next
            store.writeUsageCache(next)
        }
        lastPollAt = now
        reloadProfiles()
        evaluate()
    }

    private func checkDrift(liveToken: String) async {
        guard let profile = await client.fetchProfile(token: liveToken), (200..<300).contains(profile.status),
              let uuid = profile.uuid, let cfgUuid = liveAccount?.accountUuid else { drift = nil; return }
        if uuid == cfgUuid { drift = nil; return }
        let owner = profiles.first { $0.uuid == uuid }
        let info = DriftInfo(tokenEmail: profile.email, tokenUuid: uuid, tokenAccountName: owner?.name, configName: liveName)
        if info != drift {
            store.log("DRIFT: live token belongs to \(owner?.name ?? profile.email ?? uuid), config says \(liveName ?? "?")")
            Notifier.post("Keychain lệch với ~/.claude.json", "Token live thuộc \(owner?.name ?? profile.email ?? "?") nhưng config nói \(liveName ?? "?"). Mở Claude Switcher → Sửa lệch.")
        }
        drift = info
    }

    // MARK: policy

    func states(now: Date = Date()) -> [AccountState] {
        profiles.map { AccountState(name: $0.name, usage: usage[$0.name], record: records[$0.name], forcedExhaustedUntil: forcedExhausted[$0.name]) }
    }

    func effective(_ name: String, now: Date = Date()) -> Effective? {
        guard let s = states(now: now).first(where: { $0.name == name }) else { return nil }
        return HopPolicy.effective(s, now: now, maxAge: TimeInterval(pollInterval * 3))
    }

    func evaluate() {
        let now = Date()
        let d = HopPolicy.decide(live: liveName, states: states(now: now), t: AppSettings.thresholds, now: now,
                                 maxAge: TimeInterval(pollInterval * 3), lastHopAt: lastHopAt, cooldown: AppSettings.cooldown,
                                 lastSwitchAt: lastSwitchAt, settle: 30)
        decision = d
        switch d {
        case .hop(let to, let reason):
            guard autoSwitch, !busy, !switchInFlight else { return }
            switchInFlight = true
            Task {
                await performSwitch(to: to, auto: true, reason: reason)
                switchInFlight = false
            }
        case .allExhausted(let next):
            if now.timeIntervalSince(lastNotifiedExhausted) > 1800 {
                lastNotifiedExhausted = now
                let when = next.map { Format.clock($0) } ?? "?"
                Notifier.post("Tất cả account đều hết quota", "Không còn account nào dưới \(Int(AppSettings.hopAt))%. Reset sớm nhất: \(when).")
            }
        default: break
        }
    }

    // MARK: actions

    func performSwitch(to name: String, auto: Bool, reason: String? = nil) async {
        guard !busy, let cli else { lastError = cli == nil ? "Không tìm thấy CLI claude-account (~/.local/bin)" : nil; return }
        let from = liveName
        busyText = "Đang chuyển sang \(name)…"
        defer { busyText = nil }
        do {
            let out = try await cli.use(name)
            let now = Date()
            store.appendSwitch(SwitchEvent(at: now, from: from, to: name, by: auto ? "auto" : "app"))
            store.log("switch \(from ?? "?") -> \(name) by \(auto ? "auto" : "user")\(reason.map { " (\($0))" } ?? ""): \(out.split(separator: "\n").first ?? "")")
            lastSwitchAt = now
            if auto { lastHopAt = now }
            lastError = nil
            reloadProfiles()
            lastMarker = store.currentMarker()
            if AppSettings.restartSessions, let from {
                let moving = sessions.filter { $0.account.name == from || $0.account == .unknown }
                planRestarts(for: moving, to: name)
            }
            await scanSessions()
            let count = plan?.pids.count ?? 0
            if auto {
                Notifier.post("Đã hop sang \(name)", "\(reason ?? ""). \(count > 0 ? "\(count) session sẽ restart --continue ở cuối turn." : "")")
            } else {
                Notifier.post("Đã chuyển sang \(name)", count > 0 ? "\(count) session của \(from ?? "?") sẽ restart --continue ở cuối turn." : "Session mới sẽ chạy bằng \(name).")
            }
            await pollUsage()
        } catch {
            lastError = error.localizedDescription
            store.log("switch to \(name) failed: \(error.localizedDescription)")
            if auto { Notifier.post("Hop sang \(name) thất bại", error.localizedDescription) }
        }
    }

    func planRestarts(for moving: [Session], to name: String) {
        guard !moving.isEmpty else { return }
        var p = store.readRestartPlan() ?? RestartPlan(to: name, created: Date(), pids: [:])
        p.to = name
        for s in moving { p.pids[String(s.pid)] = name }
        store.writeRestartPlan(p)
        plan = p
        store.log("restart plan: \(moving.map(\.pid)) -> \(name)")
    }

    /// Immediate restart of one session: only safe when the user asked for it (a turn in flight is cut).
    func restartNow(_ s: Session) async {
        guard let live = liveName else { return }
        guard s.isLoop else { lastError = "Session \(s.pid) không chạy qua claude-as, không tự relaunch được — gõ /exit rồi claude --continue"; return }
        planRestarts(for: [s], to: live)
        store.writeHop(live)
        _ = kill(s.pid, SIGTERM)
        store.log("manual restart pid \(s.pid) -> \(live)")
        try? await Task.sleep(for: .seconds(3))
        await scanSessions()
    }

    func cancelPlan() {
        store.writeRestartPlan(nil)
        plan = nil
        if let h = store.readHop(), h == liveName { store.removeHop() }
        store.log("restart plan cancelled by user")
    }

    func saveCurrent(as name: String) async {
        guard let cli, CLI.isValidName(name) else { lastError = "Tên không hợp lệ (chữ, số, . _ @ -)"; return }
        busyText = "Đang lưu login hiện tại là \(name)…"
        defer { busyText = nil }
        do {
            let out = try await cli.save(name)
            store.log("save \(name): \(out)")
            lastError = nil
            reloadProfiles()
            await pollUsage()
        } catch { lastError = error.localizedDescription }
    }

    func addAccount(name: String, email: String) async {
        guard let cli else { lastError = "Không tìm thấy CLI claude-account"; return }
        guard CLI.isValidName(name) else { lastError = "Tên không hợp lệ (chữ, số, . _ @ -)"; return }
        guard !profiles.contains(where: { $0.name == name }) else { lastError = "'\(name)' đã tồn tại"; return }
        do {
            try await LoginLauncher.open(cli: cli.path, name: name, email: email.isEmpty ? nil : email, terminalApp: AppSettings.terminalApp)
            lastError = nil
            store.log("login window opened for \(name)")
        } catch { lastError = error.localizedDescription }
    }

    func remove(_ name: String) async {
        guard let cli else { return }
        busyText = "Đang xoá \(name)…"
        defer { busyText = nil }
        do {
            _ = try await cli.remove(name)
            usage.removeValue(forKey: name)
            store.writeUsageCache(usage)
            store.log("removed \(name)")
            reloadProfiles()
        } catch { lastError = error.localizedDescription }
    }

    func rename(_ old: String, to new: String) async {
        guard let cli, CLI.isValidName(new) else { lastError = "Tên không hợp lệ"; return }
        busyText = "Đang đổi tên…"
        defer { busyText = nil }
        do {
            _ = try await cli.rename(old, new)
            if let u = usage.removeValue(forKey: old) { usage[new] = u }
            store.writeUsageCache(usage)
            reloadProfiles()
        } catch { lastError = error.localizedDescription }
    }

    func installHook() async {
        busyText = "Đang cài hook…"
        defer { busyText = nil }
        do {
            try await HookInstaller.install()
            hookInstalled = true
            store.log("hook installed")
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func uninstallHook() async {
        do { try await HookInstaller.uninstall(); hookInstalled = false; store.log("hook removed") }
        catch { lastError = error.localizedDescription }
    }

    /// Drift repair: the live token really belongs to X, config says Y. Save the live blob back into X's
    /// snapshot (its freshest tokens), then put Y's snapshot into the live item so both agree again.
    func realign() async {
        guard let d = drift, let configName = d.configName else { return }
        busyText = "Đang sửa lệch…"
        defer { busyText = nil }
        do {
            guard let liveBlob = await Keychain.readLive() else { throw ShellError("không đọc được live Keychain") }
            if let owner = d.tokenAccountName {
                try await Keychain.write(service: Keychain.savedService(owner), raw: liveBlob.raw)
            }
            guard let target = await Keychain.readSaved(configName) else { throw ShellError("snapshot của \(configName) trống") }
            try await Keychain.write(service: Keychain.liveService, raw: target.raw)
            store.log("realigned: live token (\(d.tokenAccountName ?? d.tokenEmail ?? "?")) saved back, \(configName) restored to live")
            drift = nil
            lastDriftCheck = .distantPast
            lastError = nil
            await pollUsage()
        } catch { lastError = error.localizedDescription }
    }

    func uninstall() async {
        busyText = "Đang gỡ cài đặt…"
        stop()
        var lines: [String] = []
        let ok = await Uninstaller.run(removeApp: true, dryRun: false) { lines.append($0) }
        if ok {
            NSApplication.shared.terminate(nil)
        } else {
            busyText = nil
            lastError = lines.filter { $0.hasPrefix("FAIL") }.joined(separator: "\n")
            start()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func setExtraPath(_ p: String) {
        AppSettings.defaults.set(p, forKey: AppSettings.Key.extraPath.rawValue)
        Environment.extraPath = p
        cli = CLI.locate()
    }

    // MARK: doctor

    func runDoctor() async {
        var items: [DoctorItem] = []
        func add(_ l: DoctorItem.Level, _ t: String) { items.append(DoctorItem(level: l, text: t)) }
        if let cli { add(.ok, "CLI claude-account: \(cli.path) (v\(await cli.version() ?? "?"))") }
        else { add(.fail, "Không thấy claude-account. Chạy /claude-account:claude-account install trong Claude Code.") }
        add(Environment.which("jq") != nil ? .ok : .fail, "jq: \(Environment.which("jq") ?? "không có trên PATH")")
        add(Environment.which("claude") != nil ? .ok : .warn, "claude: \(Environment.which("claude") ?? "không thấy trên PATH (login mới sẽ lỗi)")")
        add(liveAccount != nil ? .ok : .fail, liveAccount.map { "~/.claude.json oauthAccount: \($0.emailAddress ?? "?")" } ?? "~/.claude.json không có oauthAccount")
        add(liveName != nil ? .ok : .warn, liveName.map { "Login hiện tại đã lưu là '\($0)'" } ?? "Login hiện tại chưa được lưu → Lưu login hiện tại")
        let live = await Keychain.readLive()
        add(live != nil ? .ok : .fail, live != nil ? "Keychain live item có OAuth token" : "Keychain '\(Keychain.liveService)' không có OAuth token")
        add(.ok, "\(profiles.count) account đã lưu trong \(Paths.accountsDir.path)")
        for p in profiles {
            let u = usage[p.name]
            if let u, u.isFreshAPI { add(.ok, "\(p.name): usage API OK (5h \(Int(u.fiveHour?.pct ?? 0))%)") }
            else if let u, let code = u.httpStatus { add(.warn, "\(p.name): usage API HTTP \(code) → dùng số ghi trong .quota") }
            else if let u, let e = u.error { add(.warn, "\(p.name): \(e)") }
            else { add(.warn, "\(p.name): chưa đo") }
        }
        add(hookInstalled ? .ok : .warn, hookInstalled ? "Hook restart theo pid đã cài (Stop + StopFailure)" : "Hook restart chưa cài → session cũ chỉ hop qua cơ chế .hop của plugin")
        if FileManager.default.fileExists(atPath: Paths.home.appendingPathComponent("Library/LaunchAgents/com.hapk.claude-quota-ping.plist").path) {
            add(.warn, "LaunchAgent claude-quota-ping đang đổi account tạm 3 lần/ngày; app chờ 30s ổn định sau mỗi lần .current đổi")
        }
        add(drift == nil ? .ok : .fail, drift == nil ? "Keychain và ~/.claude.json khớp" : "LỆCH: token live thuộc \(drift?.tokenAccountName ?? drift?.tokenEmail ?? "?")")
        doctorItems = items
    }
}

enum Format {
    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        if Calendar.current.isDateInToday(d) { f.dateFormat = "HH:mm" } else { f.dateFormat = "EEE HH:mm" }
        return f.string(from: d)
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    static func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
}
