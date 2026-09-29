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
    @Published var login: LoginState?
    @Published var update: UpdateState?
    private var lastUpdateCheck: Date = .distantPast
    private var loginFlow: LoginFlow?
    private var lastKnownLiveName: String?
    private var autoSaveAttemptAt: Date = .distantPast
    private var autoSaveUnverified = 0
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
    /// The user chose the live account (menu, terminal `use` that held, /login): the 7d balance waits an hour.
    private var lastManualSwitchAt: Date?
    /// Live account after the last switch that held; the quota-ping cron's A→B→A flip ends where it began.
    private var settledLive: String?
    private var lastMarker: AccountStore.CurrentMarker?
    private var eventsOffset: UInt64 = 0
    private var lastAlive: Date = .distantPast
    /// Why an account's snapshot cannot be switched to, keyed by name, with the blob fingerprint it was judged on:
    /// a new snapshot (relogin, sync, CLI save) clears the verdict.
    @Published var credentialIssues: [String: CredentialProblem] = [:]
    private var issueFingerprint: [String: String] = [:]
    /// Snapshot fingerprints whose owner the profile endpoint already confirmed.
    private var verifiedFingerprint: [String: String] = [:]
    private var hopFailedAt: [String: Date] = [:]
    private var lastSyncedFingerprint: String?
    private var lastLiveSync: Date = .distantPast
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
        selfHealRC()
        refreshSetup()
        reloadProfiles()
        settledLive = liveName
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
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                while !Task.isCancelled {
                    await self?.checkForUpdate()
                    try? await Task.sleep(for: .seconds(6 * 3600))
                }
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

    /// An rc block written by an older version of this app is replaced by the current one (backup kept); the
    /// plugin's block is left alone.
    private func selfHealRC() {
        guard Self.runningFromBundle, !Self.smokeMode else { return }
        let rc = ShellInstaller.rcFile()
        guard ShellInstaller.rcStatus(rc: rc) == .ours, !ShellInstaller.rcIsCurrent(rc: rc) else { return }
        do {
            try ShellInstaller.installRC(rc: rc)
            store.log("claude-as block in \(rc.path) updated to this version")
        } catch { store.log("claude-as block update failed: \(error.localizedDescription)") }
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
        followLive(now: now)
        store.pruneSessionMarkers(now: now)
        ingestEvents(now: now)
        pollInterval = AppSettings.pollSeconds
        refreshSetup()
        evaluate()
        planOrphans(now: now)
        if let n = liveName { lastKnownLiveName = n } else { await autoSaveNewLogin(now: now) }
    }

    /// `/login` inside a session or a bare `claude auth login` replaces the live login without telling anyone.
    /// When the live login is not one of the snapshots, save it - after checking that the token in the Keychain
    /// really belongs to the account ~/.claude.json names (an old session may have written its own token there).
    private func autoSaveNewLogin(now: Date) async {
        guard AppSettings.autoSaveLogin, !Self.smokeMode, !busy, let live = liveAccount, let uuid = live.accountUuid else { return }
        guard now.timeIntervalSince(autoSaveAttemptAt) > 15 else { return }
        autoSaveAttemptAt = now
        guard let blob = await Keychain.readLive(), blob.hasRefreshToken else { return }
        if let profile = await client.fetchProfile(token: blob.accessToken) {
            if (200..<300).contains(profile.status) {
                autoSaveUnverified = 0
                if let tokenUuid = profile.uuid, tokenUuid != uuid {
                    let owner = profiles.first { $0.uuid == tokenUuid }
                    drift = DriftInfo(tokenEmail: profile.email, tokenUuid: tokenUuid, tokenAccountName: owner?.name, configName: nil)
                    store.log("new login \(live.emailAddress ?? "?") NOT saved: live token belongs to \(owner?.name ?? profile.email ?? tokenUuid)")
                    return
                }
            } else if profile.status == 401 || profile.status == 403 {
                store.log("new login \(live.emailAddress ?? "?") not saved yet: token rejected (HTTP \(profile.status))")
                return
            } else {
                // endpoint unavailable (5xx / 404): after a few tries trust the config file
                autoSaveUnverified += 1
                guard autoSaveUnverified >= 3 else { return }
            }
        } else {
            return // offline: try again on the next tick
        }
        let name = Switcher.suggestName(email: live.emailAddress, taken: profiles.map(\.name))
        do {
            let out = try await switcher.save(name: name)
            store.appendSwitch(SwitchEvent(at: now, from: lastKnownLiveName, to: name, by: "login"))
            lastMarker = store.currentMarker()          // not an external `use`: no restart plan for old sessions
            lastSwitchAt = now
            lastManualSwitchAt = now
            settledLive = name
            lastKnownLiveName = name
            store.log("auto-saved new login as '\(name)': \(out.split(separator: "\n").first ?? "")")
            reloadProfiles()
            Notifier.post("Đã lưu login mới là '\(name)'", "\(live.emailAddress ?? ""). Đổi tên trong menu (⋯ › Đổi tên) nếu muốn.")
            await pollUsage()
        } catch {
            store.log("auto-save of new login failed: \(error.localizedDescription)")
        }
    }

    /// Sessions still on an exhausted account while the live account has room: restart them onto the live
    /// account at their next turn boundary. Covers sessions the hop policy never looks at (it only weighs the
    /// live account) - e.g. after a `/login` moved the live login elsewhere.
    private func planOrphans(now: Date) {
        guard AppSettings.restartSessions, let live = liveName, let liveEff = effective(live, now: now),
              !HopPolicy.isExhausted(liveEff, AppSettings.thresholds) else { return }
        let planned = Set((plan?.pids ?? [:]).keys)
        let orphans = sessions.filter { s in
            guard let acct = s.account.name, acct != live, s.isLoop, !planned.contains(String(s.pid)) else { return false }
            guard let eff = effective(acct, now: now) else { return false }
            return HopPolicy.isExhausted(eff, AppSettings.thresholds)
        }
        guard !orphans.isEmpty else { return }
        planRestarts(for: orphans, to: live)
        Notifier.post("\(orphans.count) session trên account hết quota", "Sẽ restart --continue sang \(live) ở cuối turn.")
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
            pendingExternalPlan = (from: prev.name, to: m.name, at: now)
        }
    }

    private func settleExternalPlan(now: Date) {
        guard let p = pendingExternalPlan else { return }
        guard liveName == p.to else { pendingExternalPlan = nil; return }
        guard now.timeIntervalSince(p.at) >= 30 else { return }
        pendingExternalPlan = nil
        // held for the settle window and landed somewhere new: a terminal `use`, not the quota-ping cron's flip
        if p.to != settledLive { lastManualSwitchAt = p.at }
        settledLive = p.to
        guard AppSettings.restartSessions else { return }
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

    /// Sessions in the plan should land on whatever is live now; sessions already on the live account drop out
    /// (a switch back to the account they were planned away from must not restart them for nothing).
    private func retargetPlan() {
        guard var p = store.readRestartPlan(), let live = liveName else { return }
        p.to = live
        for (pid, _) in p.pids {
            if let s = sessions.first(where: { String($0.pid) == pid }), s.account.name == live {
                p.pids.removeValue(forKey: pid)
            } else {
                p.pids[pid] = live
            }
        }
        store.writeRestartPlan(p.pids.isEmpty ? nil : p)
        plan = p.pids.isEmpty ? nil : p
        store.log("restart plan retargeted -> \(live): \(p.pids.keys.sorted())")
    }

    /// A plan only ever moves sessions onto the live account. When the live account changed some other way
    /// (`/login`, a switch the marker did not show), retarget once things have settled.
    private func followLive(now: Date) {
        guard let p = plan, let live = liveName, p.to != live else { return }
        if let s = lastSwitchAt, now.timeIntervalSince(s) < 30 { return }
        retargetPlan()
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
            // the hook is waiting (up to 5 s) for a plan entry: a session on a non-live account with a healthy
            // live account gets one right away
            if let live = liveName, name != live, let liveEff = effective(live, now: now),
               !HopPolicy.isExhausted(liveEff, AppSettings.thresholds),
               let s = sessions.first(where: { $0.pid == e.pid }), s.isLoop, AppSettings.restartSessions {
                planRestarts(for: [s], to: live)
            }
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
            let (read, problem) = await Keychain.inspect(service: isLive ? Keychain.liveService : Keychain.savedService(p.name))
            guard let blob = read, problem == nil else {
                // Keep whatever was last measured (the UI shows it dimmed): an unusable Keychain item says nothing
                // about the account's windows, and the stale fetchedAt already keeps it out of the policy.
                var u = next[p.name] ?? AccountUsage(fetchedAt: now, source: .none)
                u.error = problem?.text ?? "không đọc được Keychain"
                u.tokenExpiresAt = nil
                next[p.name] = u
                setIssue(p.name, problem ?? .unreadable("?"), fingerprint: read?.fingerprint ?? "")
                changed = true
                continue
            }
            if let fp = issueFingerprint[p.name], fp != blob.fingerprint { setIssue(p.name, nil, fingerprint: nil) }
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
            if u.httpStatus == 401 { setIssue(p.name, .rejected(401), fingerprint: blob.fingerprint) }
            if u.isFreshAPI, let five = u.fiveHour {
                // The payload does not always carry every window; a missing one means "unchanged", not "gone",
                // so the last reading stays on screen instead of the 7d row blinking out.
                if u.sevenDay == nil { u.sevenDay = next[p.name]?.sevenDay }
                if u.extras.isEmpty { u.extras = next[p.name]?.extras ?? [:] }
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
            if isLive {
                await syncLive(blob, now: now)
            } else if u.isFreshAPI, verifiedFingerprint[p.name] != blob.fingerprint {
                await verifySnapshot(p, blob)
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

    private func setIssue(_ name: String, _ problem: CredentialProblem?, fingerprint: String?) {
        if credentialIssues[name] != problem {
            store.log(problem.map { "snapshot \(name): \($0.text)" } ?? "snapshot \(name): usable again")
        }
        credentialIssues[name] = problem
        issueFingerprint[name] = problem == nil ? nil : fingerprint
    }

    /// A saved snapshot that answers with another account's identity was overwritten by a bad re-snapshot; it
    /// must never be put live. Asked once per snapshot version.
    private func verifySnapshot(_ p: AccountProfile, _ blob: OAuthBlob) async {
        let owner = await switcher.tokenOwner(blob)
        if case .unknown = owner { return }
        verifiedFingerprint[p.name] = blob.fingerprint
        if let bad = Switcher.targetProblem(owner: owner, expectedUuid: p.uuid, profiles: profiles) {
            setIssue(p.name, bad, fingerprint: blob.fingerprint)
        }
    }

    /// Keeps the live account's snapshot as fresh as the live item and reports drift. Runs when the live blob
    /// changed (a session refreshed its token, a switch, a /login) and at least every 10 minutes.
    private func syncLive(_ blob: OAuthBlob, now: Date) async {
        guard blob.fingerprint != lastSyncedFingerprint || now.timeIntervalSince(lastLiveSync) > 600 else { return }
        lastLiveSync = now
        let result: Switcher.LiveSync
        do { result = try await switcher.syncLiveSnapshot() } catch {
            store.log("live snapshot sync failed: \(error.localizedDescription)")
            return
        }
        lastSyncedFingerprint = blob.fingerprint
        if result.wrote, case .save(let name) = result.decision {
            store.log("snapshot '\(name)' refreshed from the live login")
            setIssue(name, nil, fingerprint: nil)
            hopFailedAt.removeValue(forKey: name)
        }
        switch result.owner {
        case .confirmed(let uuid, let email):
            guard let cfg = result.configUuid, uuid != cfg else { drift = nil; return }
            let owner = profiles.first { $0.uuid == uuid }
            let info = DriftInfo(tokenEmail: email, tokenUuid: uuid, tokenAccountName: owner?.name, configName: liveName)
            if info != drift {
                store.log("DRIFT: live token belongs to \(owner?.name ?? email ?? uuid), config says \(liveName ?? "?")")
                Notifier.post("Keychain lệch với ~/.claude.json", "Token live thuộc \(owner?.name ?? email ?? "?") nhưng config nói \(liveName ?? "?"). Mở Claude Switcher → Sửa lệch.")
            }
            drift = info
        case .rejected(let code):
            drift = nil
            if let live = liveName { setIssue(live, .rejected(code), fingerprint: blob.fingerprint) }
        case .unknown:
            break
        }
    }

    // MARK: policy

    func states(now: Date = Date()) -> [AccountState] {
        profiles.map { AccountState(name: $0.name, usage: usage[$0.name], record: records[$0.name],
                                    forcedExhaustedUntil: forcedExhausted[$0.name], blocked: blockReason($0.name, now: now)) }
    }

    /// Why a hop must not go to this account now. A failed switch keeps it out for the cooldown, so a target
    /// the app cannot switch to is not retried every tick.
    func blockReason(_ name: String, now: Date = Date()) -> String? {
        if let issue = credentialIssues[name] { return issue.text }
        if let at = hopFailedAt[name], now.timeIntervalSince(at) < max(AppSettings.cooldown, 300) { return "vừa chuyển sang thất bại" }
        return nil
    }

    func effective(_ name: String, now: Date = Date()) -> Effective? {
        guard let s = states(now: now).first(where: { $0.name == name }) else { return nil }
        return HopPolicy.effective(s, now: now, maxAge: TimeInterval(pollInterval * 3))
    }

    func evaluate() {
        let now = Date()
        let d = HopPolicy.decide(live: liveName, states: states(now: now), t: AppSettings.thresholds, now: now,
                                 maxAge: TimeInterval(pollInterval * 3), lastHopAt: lastHopAt, cooldown: AppSettings.cooldown,
                                 lastSwitchAt: lastSwitchAt, settle: 30, lastManualSwitchAt: lastManualSwitchAt)
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

    // MARK: update

    /// Asks GitHub what the newest build is. The background loop runs this every 6 hours and stays silent when
    /// there is nothing new; `manual` reports every outcome, including "already newest".
    func checkForUpdate(manual: Bool = false) async {
        guard !Self.smokeMode else { return }
        if case .installing = update { return }
        guard manual || Date().timeIntervalSince(lastUpdateCheck) > 3600 else { return }
        lastUpdateCheck = Date()
        if manual { update = .checking }
        guard let release = await Updater.latest() else {
            if manual { update = .failed("không hỏi được GitHub (mạng?)") }
            return
        }
        guard Updater.isNewer(release.version, than: AppInfo.version) else {
            update = manual ? .upToDate(release.version) : nil
            return
        }
        let firstTime = {
            if case .available(let v, _) = update, v == release.version { return false }
            return true
        }()
        update = .available(release.version, release.pageURL)
        store.log("update available: \(release.version) (running \(AppInfo.version))")
        if !manual, firstTime, AppSettings.notify {
            Notifier.post("Có bản Claude Switcher \(release.version)", "Đang chạy \(AppInfo.version). Mở menu và bấm Cập nhật để cài.")
        }
    }

    /// Hands the upgrade to `scripts/install.sh`, which stops this app, replaces the bundle and reopens it.
    func installUpdate() async {
        guard case .available(let version, _) = update else { return }
        guard Self.runningFromBundle else {
            update = .failed("chỉ cập nhật được bản .app đã cài (đang chạy binary dev)")
            return
        }
        let dest = Bundle.main.bundleURL.deletingLastPathComponent().path
        do {
            let pid = try Updater.startUpgrade(dest: dest, version: version, log: Paths.updateLog)
            update = .installing(version)
            store.log("update to \(version) started (pid \(pid), dest \(dest), log \(Paths.updateLog.path))")
            Notifier.post("Đang cài Claude Switcher \(version)", "App sẽ tự thoát rồi mở lại. Log: \(Paths.updateLog.path)")
        } catch {
            update = .failed(error.localizedDescription)
            store.log("update failed to start: \(error.localizedDescription)")
        }
    }

    func dismissUpdateNotice() {
        switch update {
        case .upToDate, .failed: update = nil
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
            if auto { lastHopAt = now } else { lastManualSwitchAt = now }
            settledLive = name
            lastError = nil
            hopFailedAt.removeValue(forKey: name)
            reloadProfiles()
            lastMarker = store.currentMarker()
            // the old picture is void: re-verify the live token on the next poll, and move the pending plan
            drift = nil
            lastLiveSync = .distantPast
            pendingExternalPlan = nil
            retargetPlan()
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
            hopFailedAt[name] = Date()
            store.log("switch to \(name) failed: \(error.localizedDescription)")
            if auto { Notifier.post("Hop sang \(name) thất bại", error.localizedDescription) }
        }
    }

    func planRestarts(for moving: [Session], to name: String) {
        guard !moving.isEmpty else { return }
        guard name == liveName else {
            store.log("restart plan to \(name) refused: live account is \(liveName ?? "unsaved")")
            return
        }
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
        await startLogin(name: name, email: email.isEmpty ? nil : email, relogin: false)
    }

    /// Signs in again as a saved account whose snapshot died; the browser must come back as that same account.
    func relogin(_ name: String) async {
        guard let p = profiles.first(where: { $0.name == name }) else { return }
        await startLogin(name: name, email: p.oauthAccount.emailAddress, relogin: true)
    }

    private func startLogin(name: String, email: String?, relogin: Bool) async {
        guard Environment.which("claude") != nil else { lastError = "Không thấy `claude` trên PATH — thêm đường dẫn trong Cài đặt › Shell › PATH thêm"; return }
        if AppSettings.loginViaTerminal {
            do {
                try await LoginLauncher.open(cli: cliPath, name: name, email: email, relogin: relogin, terminalApp: AppSettings.terminalApp)
                lastError = nil
                store.log("login window opened for \(name)\(relogin ? " (relogin)" : "")")
            } catch { lastError = error.localizedDescription }
            return
        }
        if let f = loginFlow, !f.state.phase.isTerminal { lastError = "Đang có một đăng nhập chạy ('\(f.name)') — huỷ nó trước"; return }
        do {
            loginFlow = try await LoginFlow(name: name, email: email, relogin: relogin, switcher: switcher,
                                            privateWindow: AppSettings.loginPrivateWindow) { [weak self] st in
                guard let self else { return }
                self.login = st
                if case .done(let msg) = st.phase {
                    self.store.log("login \(st.name): \(msg.split(separator: "\n").first ?? "")")
                    Notifier.post(st.relogin ? "Đã đăng nhập lại '\(st.name)'" : "Đã thêm account '\(st.name)'", msg.split(separator: "\n").first.map(String.init) ?? "")
                    self.setIssue(st.name, nil, fingerprint: nil)
                    self.hopFailedAt.removeValue(forKey: st.name)
                    self.reloadProfiles()
                    Task { await self.pollUsage() }
                } else if case .failed(let why) = st.phase {
                    self.store.log("login \(st.name) failed: \(why)")
                }
            }
            login = loginFlow?.state
            lastError = nil
            store.log("in-app login started for \(name)\(relogin ? " (relogin)" : "")")
        } catch { lastError = error.localizedDescription }
    }

    func loginReopen(privateWindow: Bool) { loginFlow?.reopen(privateWindow: privateWindow) }
    func loginSubmitCode(_ code: String) { loginFlow?.submitCode(code) }
    func loginCancel() { loginFlow?.cancel() }
    func loginDismiss() { if login?.phase.isTerminal == true { login = nil; loginFlow = nil } }

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

    /// Drift repair, decided by `Switcher.realign` on the state at the moment of the click.
    func realign() async {
        busyText = "Đang sửa lệch…"
        defer { busyText = nil }
        do {
            let msg = try await switcher.realign()
            store.log(msg)
            drift = nil
            lastLiveSync = .distantPast
            lastError = nil
            await pollUsage()
        } catch {
            lastError = error.localizedDescription
            store.log("realign failed: \(error.localizedDescription)")
        }
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

enum UpdateState: Equatable {
    case checking
    case upToDate(String)
    case available(String, URL?)
    case installing(String)
    case failed(String)
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
