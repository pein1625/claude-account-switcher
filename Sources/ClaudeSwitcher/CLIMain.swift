import Foundation
import AppKit
import ClaudeSwitcherCore

/// `claude-switcher <command>` - the same operations the menu bar app performs, from a terminal or a script.
enum CLIMain {
    static let commands: Set<String> = [
        "list", "ls", "names", "current", "next", "use", "save", "remove", "rm", "rename", "mv", "login", "login-prepare", "login-finish",
        "status", "doctor", "hook", "install", "uninstall", "version", "help",
        "--version", "-v", "--help", "-h", "--status", "--doctor", "--uninstall",
    ]

    static func isCLI(_ args: [String]) -> Bool { args.first.map(commands.contains) ?? false }

    static var appBinary: String { Bundle.main.executableURL?.path ?? CommandLine.arguments[0] }

    static let usage = """
    claude-switcher \(AppInfo.version) - switch Claude Code (claude.ai subscription) accounts without re-login

    Usage:
      claude-switcher list                    saved accounts (* = live now, 5H = last known 5-hour usage)
      claude-switcher current                 who is logged in now
      claude-switcher save [name]             snapshot the current login under <name> (default: its email)
      claude-switcher use <name> [--force]    switch the live login to <name>
      claude-switcher login <name> [--email <email>]
                                              sign in to ANOTHER account in a scratch config dir and snapshot it;
                                              the current login is not touched (opens the browser once)
      claude-switcher login-prepare <name>    step 1 of the same flow for scripts: prints the scratch dir; then run
                                              CLAUDE_CONFIG_DIR=<dir> claude auth login, then login-finish
      claude-switcher login-finish <name> <dir>
      claude-switcher remove <name>           delete a saved snapshot (live login untouched)
      claude-switcher rename <old> <new>      rename a snapshot
      claude-switcher names                   bare names, for shell completion
      claude-switcher next                    account a hop would go to now; exit 1 when none has room
      claude-switcher status [--no-api]       accounts, usage, decision, running sessions
      claude-switcher doctor                  dependency + store + shell integration check
      claude-switcher install [--no-rc]       shim, Stop/StopFailure hook, claude-as + alias claude in your shell rc
      claude-switcher uninstall [--dry-run] [--keep-app]
      claude-switcher hook                    (used by Claude Code as the Stop / StopFailure hook)

    Environment:
      CLAUDE_ACCOUNT_DIR            where snapshots live (default ~/.claude/accounts)
      CLAUDE_ACCOUNT_LIVE_SERVICE   macOS Keychain service Claude Code writes to (default "Claude Code-credentials")
    """

    static func run(_ args: [String]) async -> Int32 {
        AppSettings.register()
        let store = AccountStore()
        let switcher = Switcher(store: store)
        let cmd = args.first ?? "help"
        let rest = Array(args.dropFirst())
        func out(_ s: String) { print(s) }
        func fail(_ s: String) -> Int32 { FileHandle.standardError.write(Data("claude-switcher: \(s)\n".utf8)); return 1 }

        do {
            switch cmd {
            case "--version", "-v", "version":
                out(AppInfo.version)
            case "--help", "-h", "help":
                out(usage)
            case "list", "ls":
                print(switcher.listText(usage: store.readUsageCache()), terminator: "")
            case "names":
                switcher.profiles().forEach { out($0.name) }
            case "current":
                guard let c = switcher.current() else { return fail("not logged in (no oauthAccount in \(Paths.claudeJSON.path))") }
                out("\(c.name ?? "(unsaved)")\t\(c.email)\t\(c.org)")
            case "next":
                let now = Date()
                let states = switcher.profiles().map { AccountState(name: $0.name, usage: store.readUsageCache()[$0.name], record: store.quotaRecord($0.name)) }
                guard let best = HopPolicy.ranked(states, excluding: switcher.currentName(), t: AppSettings.thresholds, now: now, maxAge: 300).first else {
                    return fail("no other account below \(Int(AppSettings.hopAt))% 5h usage")
                }
                out(best.name)
            case "use":
                guard let name = rest.first(where: { !$0.hasPrefix("-") }) else { return fail("usage: use <name> [--force]") }
                out(try await switcher.use(name, force: rest.contains("--force")))
            case "save":
                out(try await switcher.save(name: rest.first))
            case "remove", "rm":
                guard let name = rest.first else { return fail("usage: remove <name>") }
                out(try await switcher.remove(name))
            case "rename", "mv":
                guard rest.count == 2 else { return fail("usage: rename <old> <new>") }
                out(try await switcher.rename(rest[0], to: rest[1]))
            case "login":
                return try await login(rest, switcher: switcher)
            case "login-prepare":
                // prints only the scratch dir on stdout; the caller runs `CLAUDE_CONFIG_DIR=<dir> claude auth login` next
                guard let name = rest.first else { return fail("usage: login-prepare <name>") }
                let ctx = try await switcher.loginPrepare(name: name)
                FileHandle.standardError.write(Data("Signing in inside a scratch config dir; the current login (\(switcher.current()?.email ?? "none")) is not touched.\n".utf8))
                out(ctx.scratch.path)
            case "login-finish":
                guard rest.count == 2 else { return fail("usage: login-finish <name> <scratch-dir>") }
                let ctx = try Switcher.LoginContext.load(scratch: URL(fileURLWithPath: rest[1]))
                out(try await switcher.loginFinish(name: rest[0], ctx: ctx))
            case "status", "--status":
                await status(store: store, noAPI: rest.contains("--no-api"))
            case "doctor", "--doctor":
                for item in await Doctor.run(store: store, usage: store.readUsageCache(), appBinary: appBinary, drift: nil) {
                    out("\(item.level == .ok ? "ok   " : item.level == .warn ? "WARN " : "FAIL ") \(item.text)")
                }
                out("PATH used: \(Environment.path)")
            case "hook":
                return HookRunner.run(stdin: FileHandle.standardInput.readDataToEndOfFile(), env: ProcessInfo.processInfo.environment)
            case "install":
                try ShellInstaller.installShim(appBinary: appBinary)
                out("shim    \(Paths.shim.path) -> \(appBinary)")
                try await HookInstaller.wireSettings()
                out("hooks   Stop + StopFailure(rate_limit) in \(Paths.settingsJSON.path) (backup kept)")
                if !rest.contains("--no-rc") {
                    let rc = ShellInstaller.rcFile()
                    try ShellInstaller.installRC(rc: rc)
                    out("shell   claude-as + alias claude in \(rc.path) (backup kept). Open a new terminal or: source \(rc.path)")
                }
            case "uninstall", "--uninstall":
                let ok = await Uninstaller.run(removeApp: !rest.contains("--keep-app"), dryRun: rest.contains("--dry-run")) { out($0) }
                return ok ? 0 : 1
            default:
                return fail("unknown command '\(cmd)' (try --help)")
            }
            return 0
        } catch {
            return fail(error.localizedDescription)
        }
    }

    /// Interactive. `claude auth login` is a TUI: it must run in the terminal's foreground process group, and a
    /// Foundation `Process` child does not (it gets SIGTTOU on raw mode and stops silently). So after preparing
    /// the scratch dir this process execs bash on the same script the menu's Terminal window uses.
    static func login(_ rest: [String], switcher: Switcher) async throws -> Int32 {
        var name: String?
        var email: String?
        var i = 0
        while i < rest.count {
            if rest[i] == "--email", i + 1 < rest.count { email = rest[i + 1]; i += 2; continue }
            if rest[i].hasPrefix("-") { throw SwitcherError("unknown option '\(rest[i])'") }
            name = rest[i]; i += 1
        }
        guard let name else { throw SwitcherError("usage: login <name> [--email <email>]") }
        let ctx = try await switcher.loginPrepare(name: name)
        let script = LoginLauncher.loginScript(cli: appBinary, name: name, email: email, scratch: ctx.scratch.path)
        let file = ctx.scratch.appendingPathComponent("run.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let words: [String] = ["/bin/bash", file.path]
        var argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) }
        argv.append(nil)
        execv("/bin/bash", &argv)
        throw SwitcherError("exec /bin/bash failed: \(String(cString: strerror(errno)))")
    }

    static func status(store: AccountStore, noAPI: Bool) async {
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
            let five = Format.pct(e.fiveHour) + (e.fiveResetsAt.map { " →\(Format.clock($0))" } ?? "")
            let seven = e.sevenDay.map { Format.pct($0) + (e.sevenResetsAt.map { " →\(Format.clock($0))" } ?? "") } ?? "-"
            var src = e.source.rawValue
            if let u = usage[s.name], let err = u.error { src += " (\(err.prefix(60)))" }
            print(String(format: "%-1@ %-10@ %-28@ %-6@ %-14@ %-14@ %@", s.name == liveName ? "*" : " ", s.name, p.email, p.plan, five, seven, src))
        }
        print("")
        print("decision: \(HopPolicy.decide(live: liveName, states: states, t: AppSettings.thresholds, now: now))")

        let raw = await SessionScanner.scan(now: now)
        let loops = await SessionScanner.loopInfo(pids: raw.map(\.pid))
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
            let loop = s.isLoop ? (s.loopID != nil ? "loop+id" : "loop") : "plain"
            print(String(format: "  %-6d %-8@ %-8@ %-8@ %@", s.pid, acct, loop, Format.ago(s.startedAt), s.cwd ?? s.command))
        }
        if let plan = store.readRestartPlan() { print("restart plan: \(plan.pids)") }
        if let hop = store.readHop() { print(".hop: \(hop)") }
        let setup = SetupStatus.current(appBinary: appBinary)
        let shimDesc: String
        if let target = ShellInstaller.shimTarget() {
            shimDesc = FileManager.default.isExecutableFile(atPath: target) ? "-> \(target)" : "-> \(target) (MISSING)"
        } else { shimDesc = "missing" }
        print("setup: shim \(shimDesc), hook \(setup.hookWired ? "wired" : "not wired"), rc \(setup.rc)")
    }
}
