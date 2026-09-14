import Foundation
import ClaudeSwitcherCore

/// `ClaudeSwitcher --status [--no-api]` / `--doctor`: the same data the menu shows, as text. Handy for scripts
/// and for checking the app without a GUI.
enum Headless {
    static func run(status: Bool, doctor: Bool, noAPI: Bool) async {
        AppSettings.register()
        let store = AccountStore()
        let now = Date()
        let profiles = store.loadProfiles()
        let live = store.liveOAuthAccount()
        let liveName = store.liveName(profiles: profiles, live: live)
        var usage = store.readUsageCache()
        let client = UsageClient()

        if !noAPI {
            for p in profiles {
                let blob = p.name == liveName ? await Keychain.readLive() : await Keychain.readSaved(p.name)
                guard let blob else { usage[p.name] = AccountUsage(fetchedAt: now, source: .none, error: "no keychain item"); continue }
                if blob.isExpired(at: now) {
                    var u = usage[p.name] ?? AccountUsage(fetchedAt: now, source: .recorded)
                    u.error = "token expired \(Format.ago(blob.expiresAt ?? now)) ago"; usage[p.name] = u; continue
                }
                var u = await client.fetchUsage(token: blob.accessToken, now: now)
                u.tokenExpiresAt = blob.expiresAt
                usage[p.name] = u
            }
        }

        let states = profiles.map { AccountState(name: $0.name, usage: usage[$0.name], record: store.quotaRecord($0.name)) }
        print("Claude Switcher \(AppInfo.version)  store: \(Paths.accountsDir.path)")
        print("live: \(liveName ?? "(unsaved)") \(live?.emailAddress ?? "-")")
        print("")
        print(String(format: "%-1@ %-10@ %-28@ %-6@ %-14@ %-14@ %@", "", "NAME", "EMAIL", "PLAN", "5H", "7D", "SOURCE"))
        for s in states {
            let p = profiles.first { $0.name == s.name }!
            let e = HopPolicy.effective(s, now: now, maxAge: 300)
            let five = "\(Format.pct(e.fiveHour))" + (e.fiveResetsAt.map { " →\(Format.clock($0))" } ?? "")
            let seven = e.sevenDay.map { "\(Format.pct($0))" + (e.sevenResetsAt.map { " →\(Format.clock($0))" } ?? "") } ?? "-"
            var src = e.source.rawValue
            if let u = usage[s.name], let err = u.error { src += " (\(err.prefix(60)))" }
            print(String(format: "%-1@ %-10@ %-28@ %-6@ %-14@ %-14@ %@", s.name == liveName ? "*" : " ", s.name, p.email, p.plan, five, seven, src))
        }
        print("")
        let decision = HopPolicy.decide(live: liveName, states: states, t: AppSettings.thresholds, now: now)
        print("decision: \(decision)")

        if status {
            let raw = await SessionScanner.scan(now: now)
            let loops = await SessionScanner.loopFlags(pids: raw.map(\.pid))
            let cwds = await SessionScanner.cwds(pids: raw.map(\.pid))
            var history = store.readSwitches()
            let marker = store.currentMarker()
            if let marker, let mt = marker.mtime { history.append(SwitchEvent(at: mt, from: nil, to: marker.name, by: "marker")); history.sort { $0.at < $1.at } }
            let sessions = SessionAttribution.attribute(raw, history: history, fallback: marker?.name ?? liveName, loops: loops, cwds: cwds)
            print("")
            print("sessions: \(sessions.count)")
            for s in sessions {
                let acct: String
                switch s.account { case .known(let n): acct = n; case .assumed(let n): acct = "~" + n; case .unknown: acct = "?" }
                print(String(format: "  %-6d %-8@ %-6@ %-8@ %@", s.pid, acct, s.isLoop ? "loop" : "plain", Format.ago(s.startedAt), s.cwd ?? s.command))
            }
            if let plan = store.readRestartPlan() { print("restart plan: \(plan.pids)") }
            if let hop = store.readHop() { print(".hop: \(hop)") }
            print("hook: script \(HookInstaller.isScriptInstalled() ? "ok" : "missing"), settings \(HookInstaller.isSettingsWired() ? "wired" : "not wired")")
        }

        if doctor {
            print("")
            print("cli: \(CLI.locate()?.path ?? "NOT FOUND")   jq: \(Environment.which("jq") ?? "NOT FOUND")   claude: \(Environment.which("claude") ?? "NOT FOUND")")
            print("PATH used: \(Environment.path)")
            if let cli = CLI.locate() { print(await cli.doctor()) }
        }
    }
}
