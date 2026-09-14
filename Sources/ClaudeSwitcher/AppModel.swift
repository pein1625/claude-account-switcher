import Foundation
import AppKit
import ServiceManagement
import ClaudeSwitcherCore

struct DriftInfo: Equatable {
    var tokenEmail: String?
    var tokenUuid: String?
    var tokenAccountName: String?
    var configName: String?
    var summary: String { "LỆCH: token live thuộc \(tokenAccountName ?? tokenEmail ?? "?"), config nói \(configName ?? "?")" }
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
    @Published var setup = SetupStatus()
    @Published var doctorItems: [DoctorItem] = []
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var autoSwitch: Bool = AppSettings.autoSwitch {
        didSet { AppSettings.defaults.set(autoSwitch, forKey: AppSettings.Key.autoSwitch.rawValue); evaluate() }
    }

    let store = AccountStore()
    let client = UsageClient()
    let switcher = Switcher()

    static var appBinary: String { Bundle.main.executableURL?.path ?? CommandLine.arguments[0] }
    static var runningFromBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    /// `CLAUDE_SWITCHER_SMOKE=1`: UI smoke run without Keychain reads, network, or prompts.
    static let smokeMode = ProcessInfo.processInfo.environment["CLAUDE_SWITCHER_SMOKE"] == "1"

    /// What the Terminal login script calls: the shim when present, else the app binary itself.
    var cliPath: String { FileManager.default.isExecutableFile(atPath: Paths.shim.path) ? Paths.shim.path : Self.appBinary }

    private var forcedExhausted: [String: Date] = [:]
    private var forcedAt: [String: Date] = [:]
    private var lastHopAt: Date?
    private var lastSwitchAt: Date?
    private var lastMarker: AccountStore.CurrentMarker?
    private var eventsOffset: UInt64 = 0
    private var lastAlive: Date = .distantPast
    private var lastDriftCheck: Date = .distantPast
    private var lastNotifiedExhausted: Date = .distantPast
    private var switchInFlight = false
    /// An external `use` (claude-as loop, CLI) strands the old account's sessions just like an app switch
    /// does; plan their restarts once the switch has held for the settle window (the quota-ping cron flips
    /// accounts for a few seconds and must not trigger a mass restart).
    private var pendingExternalPlan: (from: String, to: String, at: Date)?
    private var tasks: [Task<Void, Never>] = []
    private var pollInterval: Int = AppSettings.pollSeconds

    var busy: Bool { busyText != nil }

    // MARK: lifecycle

    func start() {
        AppSettings.register()
        store.log("app start v\(AppInfo.version) pid \(ProcessInfo.processInfo.processIdentifier) bin \(Self.appBinary)")
        usage = store.readUsageCache()
        lastMarker = store.currentMarker()
        if let m = lastMarker { lastSwitchAt = m.mtime }
        eventsOffset = store.readEvents(from: 0).offset
        selfHealShim()
        refreshSetup()
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
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.offerSetupIfNeeded()
            },
        ]
    }

    func stop() { tasks.forEach { $0.cancel() } }

    // MARK: shell integration

    func refreshSetup() { setup = SetupStatus.current(appBinary: Self.appBinary) }

    /// The shim points at an absolute app path; when the app was moved, fix it silently on launch.
    private func selfHealShim() {
        guard Self.runningFromBundle, ShellInstaller.shimStatus(appBinary: Self.appBinary) == .stale else { return }
        try? ShellInstaller.installShim(appBinary: Self.appBinary)
        store.log("shim rewritten -> \(Self.appBinary)")
    }

    func installAll(rc: Bool = true) async {
        busyText = "Đang cài hop tự động…"
        defer { busyText = nil }
        do {
            try ShellInstaller.installShim(appBinary: Self.appBinary)
            try await HookInstaller.wireSettings()
            if rc { try ShellInstaller.installRC(rc: ShellInstaller.rcFile()) }
            refreshSetup()
            lastError = nil
            store.log("shell integration installed (rc: \(rc))")
            Notifier.post("Đã bật hop tự động", "Mở terminal mới (hoặc source \(ShellInstaller.rcFile().lastPathComponent)) để `claude` chạy qua claude-as. Session đang chạy nhận hook sau khi restart.")
        } catch {
            lastError = error.localizedDescription
            store.log("install failed: \(error.localizedDescription)")
        }
    }

    func removeShellIntegration() async {
        busyText = "Đang gỡ tích hợp shell…"
        defer { busyText = nil }
        do {
            try await HookInstaller.unwireSettings()
            try ShellInstaller.removeRC(rc: ShellInstaller.rcFile())
            ShellInstaller.removeShim()
            refreshSetup()
            store.log("shell integration removed")
        } catch { lastError = error.localizedDescription }
    }

    /// First launch from a bundle: one dialog, default button installs. Later launches stay quiet (banner only).
    private func offerSetupIfNeeded() async {
        guard Self.runningFromBundle, !Self.smokeMode, !setup.complete,
              !AppSettings.defaults.bool(forKey: "didOfferSetup") else { return }
        AppSettings.defaults.set(true, forKey: "didOfferSetup")
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Bật hop tự động cho Claude Code?"
        alert.informativeText = """
        Claude Switcher sẽ cài vào máy:
        • \(Paths.shim.path) — CLI claude-switcher
        • hook Stop / StopFailure vào \(Paths.settingsJSON.path) (có backup)
        • hàm claude-as + alias claude vào \(ShellInstaller.rcFile().path) (có backup)

        Nhờ đó khi account hết quota, session đang chạy tự chuyển account và tiếp tục hội thoại (--continue). Gỡ được trong Cài đặt › Shell.
        """
        alert.addButton(withTitle: "Cài")
        alert.addButton(withTitle: "Để sau")
        if alert.runModal() == .alertFirstButtonReturn { await installAll() }
    }

    // MARK: periodic work

    func reloadProfiles() {
        profiles = store.loadProfiles()
        liveAccount = store.liveOAuthAccount()
        liveName = store.liveName(profiles: profiles, live: liveAccount)
        var recs: [String: QuotaRecord] = [:]
        for p in profiles { if let r = store.quotaRecord(p.name) { recs[p.name] = r } }
        records = recs
    }

    private func tick() async {
        let now = Date()
        if now.timeIntervalSince(lastAlive) > 30 { store.touchAlive(now: now); lastAlive = now }
        reloadProfiles()
        detectExternalSwitch(now: now)
        settleExternalPlan(now: now)
        prunePlan()
        ingestEvents(now: now)
        pollInterval = AppSettings.pollSeconds
        refreshSetup()
        evaluate()
    }

    /// `claude-switcher use` / `claude-account use` from a terminal (or a claude-as loop) rewrites `.current`;
    /// record it so session attribution stays right and the policy waits for things to settle.
    private func detectExternalSwitch(now: Date) {
        let m = store.currentMarker()
        defer { lastMarker = m }
        guard let m, let prev = lastMarker, m.name != prev.name || m.mtime != prev.mtime else { return }
        if m.name != prev.name {
            store.appendSwitch(SwitchEvent(at: m.mtime ?? now, from: prev.name, to: m.name, by: "cli"))
            store.log("external switch \(prev.name) -> \(m.name)")
            lastSwitchAt = m.mtime ?? now
            retargetPlan()
            pendingExternalPlan = AppSettings.restartSessions ? (from: prev.name, to: m.name, at: now) : nil
        }
    }

    private func settleExternalPlan(now: Date) {
        guard let p = pendingExternalPlan else { return }
        guard liveName == p.to else { pendingExternalPlan = nil; return }
        guard now.timeIntervalSince(p.at) >= 30 else { return }
        pendingExternalPlan = nil
        let moving = sessions.filter { $0.account.name == p.from || $0.account == .unknown }
        guard !moving.isEmpty else { return }
        planRestarts(for: moving, to: p.to)
        Notifier.post("Account đã đổi sang \(p.to)", "\(moving.count) session của \(p.from) sẽ restart --continue ở cuối turn.")
    }

    private func prunePlan() {
        guard var p = store.readRestartPlan() else { plan = nil; return }
        let alive = Set(sessions.map { String($0.pid) })
        if !sessions.isEmpty { p.pids = p.pids.filter { alive.contains($0.key) } }
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
            forcedAt[name] = now
            store.writeQuotaRecord(name, QuotaRecord(pct: 100, resetsAt: reset, recordedAt: now), now: now)
            store.log("rate_limit event pid \(e.pid) -> \(name) exhausted until \(ISO8601.string(reset))")
        }
    }

    func scanSessions() async {
        let now = Date()
        let raw = await SessionScanner.scan(now: now)
        let pids = raw.map(\.pid)
        let loops = await SessionScanner.loopInfo(pids: pids)
        let cwds = await SessionScanner.cwds(pids: pids)
        let marker = store.currentMarker()
        var history = store.readSwitches()
        if let marker, let mt = marker.mtime, !history.contains(where: { abs($0.at.timeIntervalSince(mt)) < 2 && $0.to == marker.name }) {
            history.append(SwitchEvent(at: mt, from: nil, to: marker.name, by: "marker"))
            history.sort { $0.at < $1.at }
        }
        sessions = SessionAttribution.attribute(raw, history: history, fallback: marker?.name ?? liveName, loops: loops, cwds: cwds)
    }

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
                // A rate-limit event is a strong hint, but a fresher API reading well under both thresholds
                // overrules it (the event may have come from a misattributed session).
                if let at = forcedAt[p.name], now > at, five.pct < AppSettings.hopAt, (u.sevenDay?.pct ?? 0) < AppSettings.sevenDayAt {
                    forcedExhausted.removeValue(forKey: p.name)
                    forcedAt.removeValue(forKey: p.name)
                    store.log("rate_limit flag for \(p.name) cleared: API shows 5h \(Int(five.pct))%")
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
        guard !busy else { return }
        let from = liveName
        busyText = "Đang chuyển sang \(name)…"
        defer { busyText = nil }
        do {
            let out = try await switcher.use(name)
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
        if let id = s.loopID { store.writeHopMarker(id: id, live) } else { store.writeHop(live) }
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
        busyText = "Đang lưu login hiện tại là \(name)…"
        defer { busyText = nil }
        do {
            let out = try await switcher.save(name: name)
            store.log("save \(name): \(out)")
            lastError = nil
            reloadProfiles()
            await pollUsage()
        } catch { lastError = error.localizedDescription }
    }

    func addAccount(name: String, email: String) async {
        guard Switcher.isValidName(name) else { lastError = "Tên không hợp lệ (chữ, số, . _ @ -)"; return }
        guard !profiles.contains(where: { $0.name == name }) else { lastError = "'\(name)' đã tồn tại"; return }
        guard Environment.which("claude") != nil else { lastError = "Không thấy `claude` trên PATH — thêm đường dẫn trong Cài đặt › Shell › PATH thêm"; return }
        do {
            try await LoginLauncher.open(cli: cliPath, name: name, email: email.isEmpty ? nil : email, terminalApp: AppSettings.terminalApp)
            lastError = nil
            store.log("login window opened for \(name)")
        } catch { lastError = error.localizedDescription }
    }

    func remove(_ name: String) async {
        busyText = "Đang xoá \(name)…"
        defer { busyText = nil }
        do {
            _ = try await switcher.remove(name)
            usage.removeValue(forKey: name)
            store.writeUsageCache(usage)
            store.log("removed \(name)")
            reloadProfiles()
        } catch { lastError = error.localizedDescription }
    }

    /// Renames a snapshot everywhere the name is used; the live login itself is untouched.
    func rename(_ old: String, to new: String) async -> Bool {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard Switcher.isValidName(new) else { lastError = "Tên không hợp lệ (chữ, số, . _ @ -)"; return false }
        guard old != new else { return true }
        guard !profiles.contains(where: { $0.name == new }) else { lastError = "'\(new)' đã tồn tại"; return false }
        busyText = "Đang đổi tên \(old) → \(new)…"
        defer { busyText = nil }
        do {
            let out = try await switcher.rename(old, to: new)
            if let u = usage.removeValue(forKey: old) { usage[new] = u }
            store.writeUsageCache(usage)
            if let f = forcedExhausted.removeValue(forKey: old) { forcedExhausted[new] = f }
            if let f = forcedAt.removeValue(forKey: old) { forcedAt[new] = f }
            store.renameInSwitches(from: old, to: new)
            store.renameInPlan(from: old, to: new)
            if let p = pendingExternalPlan {
                pendingExternalPlan = (from: p.from == old ? new : p.from, to: p.to == old ? new : p.to, at: p.at)
            }
            lastMarker = store.currentMarker()
            store.log("rename \(old) -> \(new): \(out)")
            lastError = nil
            reloadProfiles()
            await scanSessions()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Drift repair: the live token really belongs to X, config says Y. Save the live blob back into X's
    /// snapshot (its freshest tokens), then put Y's snapshot into the live item so both agree again.
    func realign() async {
        guard let d = drift, let configName = d.configName else { return }
        busyText = "Đang sửa lệch…"
        defer { busyText = nil }
        do {
            try await switcher.withLock {
                guard let liveBlob = await Keychain.readLive() else { throw SwitcherError("không đọc được live Keychain") }
                if let owner = d.tokenAccountName {
                    try await Keychain.write(service: Keychain.savedService(owner), raw: liveBlob.raw)
                }
                guard let target = await Keychain.readSaved(configName) else { throw SwitcherError("snapshot của \(configName) trống") }
                try await Keychain.write(service: Keychain.liveService, raw: target.raw)
            }
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
    }

    func runDoctor() async {
        doctorItems = await Doctor.run(store: store, usage: usage, appBinary: Self.appBinary, drift: drift?.summary)
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
