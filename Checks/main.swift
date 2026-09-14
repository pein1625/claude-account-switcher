// Assertion runner for ClaudeSwitcherCore. `swift run ClaudeSwitcherChecks` — exit 1 on any failure.
import Foundation
import ClaudeSwitcherCore

var total = 0, failed = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    total += 1
    if !cond { failed += 1; print("FAIL  line \(line): \(msg)") }
}
func equal<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", line: Int = #line) {
    check(a == b, "\(msg) expected \(b), got \(a)", line: line)
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
let t = Thresholds(hopAt: 90, sevenDayAt: 100)
func api(_ five: Double, _ seven: Double? = nil, fetched: TimeInterval = 0, resetIn: TimeInterval = 3600) -> AccountUsage {
    AccountUsage(fiveHour: WindowUsage(pct: five, resetsAt: now.addingTimeInterval(resetIn)),
                 sevenDay: seven.map { WindowUsage(pct: $0, resetsAt: now.addingTimeInterval(86400)) },
                 fetchedAt: now.addingTimeInterval(fetched), source: .api)
}

// MARK: QuotaRecord
do {
    let rec = QuotaRecord(line: "25\t1789385400\t1789373222\n")!
    equal(rec.pct, 25)
    equal(rec.resetsAt, Date(timeIntervalSince1970: 1789385400))
    equal(rec.effectivePct(now: Date(timeIntervalSince1970: 1789385399)), 25)
    equal(rec.effectivePct(now: Date(timeIntervalSince1970: 1789385400)), 0, "window reset -> 0")
    equal(QuotaRecord(line: "91.7\t0\t0")?.pct, 91)
    check(QuotaRecord(line: "91.7\t0\t0")?.resetsAt == nil, "0 reset -> nil")
    check(QuotaRecord(line: "") == nil && QuotaRecord(line: "abc") == nil, "garbage rejected")
    equal(QuotaRecord(pct: 42, resetsAt: Date(timeIntervalSince1970: 1_800_010_000), recordedAt: nil).line(now: now), "42\t1800010000\t1800000000\n")
}

// MARK: usage parsing
do {
    let json = """
    {"five_hour":{"utilization":25.5,"resets_at":"2026-09-14T13:30:00.123456+00:00"},
     "seven_day":{"utilization":12.0,"resets_at":"2026-09-17T02:00:00Z"},
     "seven_day_opus":{"utilization":3,"resets_at":null},
     "extra_usage":{"is_enabled":true}}
    """
    let u = UsageClient.parseUsage(Data(json.utf8), now: now)
    check(u != nil, "parses")
    equal(u?.fiveHour?.pct, 25.5)
    equal(u?.fiveHour?.resetsAt, ISO8601.parse("2026-09-14T13:30:00.123456+00:00"), "fractional seconds kept")
    equal(u?.sevenDay?.pct, 12)
    equal(u?.extras["seven_day_opus"]?.pct, 3)
    check(u?.extras["extra_usage"] == nil, "objects without utilization ignored")
    equal(u?.isFreshAPI, true)
    check(UsageClient.parseUsage(Data("{\"error\":\"nope\"}".utf8), now: now) == nil, "no windows -> nil")
    check(UsageClient.parseUsage(Data("not json".utf8), now: now) == nil, "not json -> nil")
}

// MARK: session scanner
do {
    let day: TimeInterval = 86400, hour: TimeInterval = 3600
    equal(SessionScanner.parseEtime("01:05"), TimeInterval(65))
    equal(SessionScanner.parseEtime("02:03:04"), 2 * hour + 184)
    equal(SessionScanner.parseEtime("01-22:50:55"), day + 22 * hour + 50 * 60 + 55)
    check(SessionScanner.parseEtime("x") == nil, "bad etime")
    let out = """
    15761 15258    01:00 claude           claude
    36562 36273 01-00:00:00 claude           claude --continue
    28493     1    05:00 /Users/x/.nvm/versions/node/v24/bin/node node worker.js
      999   998    00:10 /opt/claude/claude /opt/claude/claude -p hi
    """
    let s = SessionScanner.parsePS(out, now: now)
    equal(s.map(\.pid), [36562, 15761, 999], "claude only, oldest first (1d, 60s, 10s)")
    equal(s[1].startedAt, now.addingTimeInterval(-60))
    equal(s[2].startedAt, now.addingTimeInterval(-10))
    equal(s[0].command, "claude --continue", "column padding trimmed")
    equal(s[2].command, "/opt/claude/claude -p hi")

    let history = [
        SwitchEvent(at: now.addingTimeInterval(100), from: "m04", to: "m19", by: "app"),
        SwitchEvent(at: now.addingTimeInterval(500), from: "m19", to: "m04", by: "cli"),
    ]
    let raw = [
        RawSession(pid: 1, ppid: 0, startedAt: now, command: "claude"),
        RawSession(pid: 2, ppid: 0, startedAt: now.addingTimeInterval(200), command: "claude"),
        RawSession(pid: 3, ppid: 0, startedAt: now.addingTimeInterval(600), command: "claude"),
    ]
    let attributed = SessionAttribution.attribute(raw, history: history, fallback: "m04", loops: [2: LoopInfo(isLoop: true, id: "1-2")], cwds: [3: "/tmp"])
    equal(attributed[0].account, Attribution.assumed("m04"), "older than history -> assumed")
    equal(attributed[1].account, Attribution.known("m19"))
    equal(attributed[2].account, Attribution.known("m04"))
    equal(attributed[1].loopID, "1-2")
    check(attributed[1].isLoop && !attributed[0].isLoop, "loop flags")
    equal(attributed[2].cwd, "/tmp")
    equal(SessionAttribution.attribute([raw[0]], history: [], fallback: nil, loops: [:], cwds: [:])[0].account, Attribution.unknown)
}

// MARK: hop policy
do {
    let stay = HopPolicy.decide(live: "m04", states: [AccountState(name: "m04", usage: api(25)), AccountState(name: "m19", usage: api(1))], t: t, now: now)
    if case .stay = stay {} else { check(false, "stay below threshold: \(stay)") }

    let three = [AccountState(name: "m04", usage: api(92)), AccountState(name: "m19", usage: api(40)), AccountState(name: "m07", usage: api(10))]
    equal(HopPolicy.decide(live: "m04", states: three, t: t, now: now), .hop(to: "m07", reason: "m04 5h 92% ≥ 90%"), "lowest 5h wins")

    let weekly = [AccountState(name: "m04", usage: api(10, 100)), AccountState(name: "m19", usage: api(5, 100)), AccountState(name: "m07", usage: api(50, 20))]
    equal(HopPolicy.decide(live: "m04", states: weekly, t: t, now: now), .hop(to: "m07", reason: "m04 7d 100% ≥ 100%"), "7d exhaustion triggers and filters")

    let allOut = [AccountState(name: "m04", usage: api(95)), AccountState(name: "m19", usage: api(91, resetIn: 1200))]
    equal(HopPolicy.decide(live: "m04", states: allOut, t: t, now: now), .allExhausted(nextReset: now.addingTimeInterval(1200)))

    let oldRec = QuotaRecord(pct: 95, resetsAt: now.addingTimeInterval(-10), recordedAt: now.addingTimeInterval(-20000))
    equal(HopPolicy.decide(live: "m04", states: [AccountState(name: "m04", usage: api(90)), AccountState(name: "m19", record: oldRec)], t: t, now: now),
          .hop(to: "m19", reason: "m04 5h 90% ≥ 90%"), "recorded window already reset counts as 0")
    let liveRec = QuotaRecord(pct: 95, resetsAt: now.addingTimeInterval(1000), recordedAt: now)
    equal(HopPolicy.decide(live: "m04", states: [AccountState(name: "m04", usage: api(90)), AccountState(name: "m19", record: liveRec)], t: t, now: now),
          .allExhausted(nextReset: now.addingTimeInterval(1000)), "recorded window still open blocks")

    let stale = HopPolicy.effective(AccountState(name: "m19", usage: api(5, fetched: -3600), record: liveRec), now: now, maxAge: 300)
    equal(stale.fiveHour, 95, "stale api falls back to record"); equal(stale.source, .recorded)

    let ev = HopPolicy.effective(AccountState(name: "m04", usage: api(10), forcedExhaustedUntil: now.addingTimeInterval(60)), now: now, maxAge: 300)
    equal(ev.fiveHour, 100); equal(ev.source, .event)
    equal(HopPolicy.effective(AccountState(name: "m04", usage: api(10), forcedExhaustedUntil: now.addingTimeInterval(-1)), now: now, maxAge: 300).fiveHour, 10, "expired event ignored")

    let two = [AccountState(name: "m04", usage: api(95)), AccountState(name: "m19", usage: api(1))]
    if case .hold = HopPolicy.decide(live: "m04", states: two, t: t, now: now, lastSwitchAt: now.addingTimeInterval(-5)) {} else { check(false, "settle hold") }
    if case .hold = HopPolicy.decide(live: "m04", states: two, t: t, now: now, lastHopAt: now.addingTimeInterval(-60)) {} else { check(false, "cooldown hold") }
    if case .hop = HopPolicy.decide(live: "m04", states: two, t: t, now: now, lastHopAt: now.addingTimeInterval(-601)) {} else { check(false, "cooldown over") }
    if case .hold = HopPolicy.decide(live: nil, states: [], t: t, now: now) {} else { check(false, "unsaved live holds") }
    equal(HopPolicy.ranked(three, excluding: "m04", t: t, now: now, maxAge: 300).map(\.name), ["m07", "m19"])
}

// MARK: shell installer, launcher, plan, hooks
do {
    let block = ShellInstaller.rcBlock()
    check(block.hasPrefix(ShellInstaller.markBegin + "\n") && block.hasSuffix(ShellInstaller.markEnd), "rc block delimited by the plugin's markers")
    check(block.contains("CLAUDE_AS_ID=\"$id\"") && block.contains("hop-$id") && block.contains("alias claude='claude-as'"), "rc block content")
    check(block.contains("printf 'claude-as: resuming as %s\\n'"), "printf newline escape survives (raw string)")

    let empty = ShellInstaller.replaceBlock(in: "", with: "B1\nB2")
    equal(empty, "\nB1\nB2\n", "append to empty")
    let appended = ShellInstaller.replaceBlock(in: "x=1", with: ShellInstaller.rcBlock())
    check(appended.hasPrefix("x=1\n\n# >>> claude-account >>>"), "append after existing content with blank line")
    let pluginRC = "a\n\n# >>> claude-account >>>\nclaude-as() { claude-account use x; }\n# <<< claude-account <<<\nalias claude='claude-as'\n"
    let replaced = ShellInstaller.replaceBlock(in: pluginRC, with: "# >>> claude-account >>>\nOURS\n# <<< claude-account <<<")
    equal(replaced, "a\n\n# >>> claude-account >>>\nOURS\n# <<< claude-account <<<\nalias claude='claude-as'\n", "replace in place keeps the rest")
    equal(ShellInstaller.replaceBlock(in: pluginRC, with: nil), "a\nalias claude='claude-as'\n", "remove drops block and the blank line before it")
    equal(ShellInstaller.replaceBlock(in: "no block\n", with: nil), "no block\n", "remove without block is a no-op")
    check(ShellInstaller.existingBlock(in: pluginRC)?.contains("claude-account use") == true, "existing block detected")

    equal(ShellInstaller.shellQuote("a'b"), "'a'\\''b'")
    let shim = ShellInstaller.shimText(appBinary: "/Applications/X.app/Contents/MacOS/X")
    check(shim.hasPrefix("#!/bin/sh\n") && shim.contains("exec \"$APP\" \"$@\"") && shim.contains("= hook ] && exit 0"), "shim shape")
    let script = LoginLauncher.loginScript(cli: "/x/claude-switcher", name: "m07", email: "me@x.io")
    check(script.contains("'/x/claude-switcher' login 'm07' --email 'me@x.io'"), "login command")
    check(!LoginLauncher.loginScript(cli: "/x/cs", name: "m07", email: nil).contains("--email"), "no email flag when empty")

    let dump = """
    keychain: "/Users/x/Library/Keychains/login.keychain-db"
        "svce"<blob>="Claude Code-credentials"
        "svce"<blob>="Claude Code-credentials-acct-m04"
        "svce"<blob>="Claude Code-credentials-3e86560c"
        "svce"<blob>="Something else"
    """
    equal(Keychain.parseServices(dump), ["Claude Code-credentials", "Claude Code-credentials-acct-m04", "Claude Code-credentials-3e86560c"], "service names parsed")

    let loops = SessionScanner.parseLoopInfo("  123 claude A=1 CLAUDE_AS_LOOP=1 CLAUDE_AS_ID=77-42 PATH=/x\n  456 claude PATH=/x\n  789 claude CLAUDE_AS_LOOP=1 HOME=/h")
    equal(loops[123], LoopInfo(isLoop: true, id: "77-42"))
    equal(loops[456], LoopInfo(isLoop: false, id: nil))
    equal(loops[789], LoopInfo(isLoop: true, id: nil))

    let root: [String: Any] = ["a": 1, "hooks": ["Stop": [["hooks": [["type": "command", "command": "bash x"]]],
                                                          ["hooks": [["type": "command", "command": "bash \"$HOME/.local/bin/claude-switcher-hook\""]]]],
                                                 "SessionStart": [["hooks": [["command": "echo hi"]]]]]]
    let added = HookInstaller.addHooks(root)
    let hooks = added["hooks"] as? [String: Any]
    let stop = hooks?["Stop"] as? [[String: Any]]
    equal(stop?.count, 2, "legacy entry stripped, ours added")
    equal(((stop?.last?["hooks"] as? [[String: Any]])?.first?["command"] as? String), HookInstaller.command)
    equal((hooks?["StopFailure"] as? [[String: Any]])?.first?["matcher"] as? String, "rate_limit")
    equal((hooks?["SessionStart"] as? [[String: Any]])?.count, 1, "other events untouched")
    let removed = HookInstaller.removeHooks(added)
    let rh = removed["hooks"] as? [String: Any]
    equal((rh?["Stop"] as? [[String: Any]])?.count, 1, "remove leaves foreign hook")
    equal((rh?["StopFailure"] as? [[String: Any]])?.count, 0)
    equal(removed["a"] as? Int, 1)

    let plan = RestartPlan(to: "m19", created: now, pids: ["123": "m19"])
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    equal(try? dec.decode(RestartPlan.self, from: try enc.encode(plan)), plan, "plan round trip")
    check(Switcher.isValidName("m07") && Switcher.isValidName("a.b_c@d-e") && !Switcher.isValidName("bad name") && !Switcher.isValidName(""), "name validation")
}

print("\(total - failed)/\(total) checks passed")
exit(failed == 0 ? 0 : 1)
