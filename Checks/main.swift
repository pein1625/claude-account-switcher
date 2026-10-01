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
    equal(attributed[0].account, Attribution.assumed("m04"), "older than history -> assumed from-account of the first switch")
    let markerOnly = [SwitchEvent(at: now.addingTimeInterval(100), from: nil, to: "m19", by: "marker")]
    equal(SessionAttribution.attribute([raw[0]], history: markerOnly, fallback: "m19", loops: [:], cwds: [:])[0].account, Attribution.assumed("m19"), "no from recorded -> fallback")
    let afterHop = [SwitchEvent(at: now.addingTimeInterval(100), from: "m04", to: "m19", by: "cli")]
    equal(SessionAttribution.attribute([raw[0]], history: afterHop, fallback: "m19", loops: [:], cwds: [:])[0].account, Attribution.assumed("m04"), "old session after a hop stays on the account it started with")
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

// MARK: 7d preference
do {
    let t7 = Thresholds(hopAt: 90, sevenDayAt: 100, prefer7d: true, sevenDayMargin: 10)
    let three7 = [AccountState(name: "m04", usage: api(92, 50)), AccountState(name: "m19", usage: api(40, 20)), AccountState(name: "m07", usage: api(10, 70))]
    equal(HopPolicy.decide(live: "m04", states: three7, t: t7, now: now), .hop(to: "m19", reason: "m04 5h 92% ≥ 90%"), "exhausted: lowest 7d wins over lowest 5h")
    equal(HopPolicy.decide(live: "m04", states: three7, t: t, now: now), .hop(to: "m07", reason: "m04 5h 92% ≥ 90%"), "prefer7d off keeps lowest 5h")
    let tight = [AccountState(name: "m04", usage: api(95, 50)), AccountState(name: "m19", usage: api(85, 10)), AccountState(name: "m07", usage: api(10, 60))]
    equal(HopPolicy.ranked(tight, excluding: "m04", t: t7, now: now, maxAge: 300).map(\.name), ["m07", "m19"], "5h room beats a lower 7d with no 5h room")

    // the screenshot's day: m04 live at 5h 24% / 7d 98%, m19 at 5h 3% / 7d 60%
    let week = [AccountState(name: "m04", usage: api(24, 98)), AccountState(name: "m19", usage: api(3, 60))]
    equal(HopPolicy.decide(live: "m04", states: week, t: t7, now: now), .hop(to: "m19", reason: "cân bằng tuần: m04 +12 so với tiến độ, m19 -26 (chênh ≥ 10)"),
          "live not exhausted, pace gap ≥ margin -> move")
    if case .stay = HopPolicy.decide(live: "m04", states: week, t: t, now: now) {} else { check(false, "no rebalance with prefer7d off") }
    let close = [AccountState(name: "m04", usage: api(24, 65)), AccountState(name: "m19", usage: api(3, 60))]
    if case .stay = HopPolicy.decide(live: "m04", states: close, t: t7, now: now) {} else { check(false, "gap under margin -> stay (no ping-pong)") }
    let noRoom = [AccountState(name: "m04", usage: api(24, 98)), AccountState(name: "m19", usage: api(85, 10))]
    if case .stay = HopPolicy.decide(live: "m04", states: noRoom, t: t7, now: now) {} else { check(false, "candidate without 5h room -> stay") }
    if case .hold = HopPolicy.decide(live: "m04", states: week, t: t7, now: now, lastManualSwitchAt: now.addingTimeInterval(-600)) {} else { check(false, "manual choice held for an hour") }
    if case .hop = HopPolicy.decide(live: "m04", states: week, t: t7, now: now, lastManualSwitchAt: now.addingTimeInterval(-3601)) {} else { check(false, "hold over") }
    if case .hold = HopPolicy.decide(live: "m04", states: week, t: t7, now: now, lastHopAt: now.addingTimeInterval(-60)) {} else { check(false, "rebalance respects cooldown") }
    let manualButOut = [AccountState(name: "m04", usage: api(95, 98)), AccountState(name: "m19", usage: api(3, 60))]
    if case .hop = HopPolicy.decide(live: "m04", states: manualButOut, t: t7, now: now, lastManualSwitchAt: now) {} else { check(false, "manual hold never blocks an exhaustion hop") }
    let deadLow = [AccountState(name: "m04", usage: api(24, 98)), AccountState(name: "m19", usage: api(3, 5), blocked: "token bị từ chối")]
    if case .stay = HopPolicy.decide(live: "m04", states: deadLow, t: t7, now: now) {} else { check(false, "blocked account never a rebalance target") }

    // weekly pace: used 7d minus the elapsed share of each account's own week
    func paced(_ five: Double, _ seven: Double, resetIn hours: Double) -> AccountUsage {
        AccountUsage(fiveHour: WindowUsage(pct: five, resetsAt: now.addingTimeInterval(3600)),
                     sevenDay: WindowUsage(pct: seven, resetsAt: now.addingTimeInterval(hours * 3600)), fetchedAt: now, source: .api)
    }
    func slack(_ u: AccountUsage) -> Double? { HopPolicy.weekSlack(HopPolicy.effective(AccountState(name: "x", usage: u), now: now, maxAge: 300), now: now) }
    equal(slack(paced(0, 50, resetIn: 84)).map { $0.rounded() }, 0, "half the week gone, half used -> on pace")
    equal(slack(paced(0, 99, resetIn: 50.2)).map { $0.rounded() }, 29, "m04 today: 99% with 50h left is 29 points ahead")
    equal(slack(paced(0, 63, resetIn: 39.2)).map { $0.rounded() }, -14, "m19 today: 63% with 39h left is 14 points behind")
    var rolled = paced(0, 80, resetIn: -24); rolled.sevenDay?.resetsAt = now.addingTimeInterval(-24 * 3600)
    equal(slack(rolled).map { $0.rounded() }, -14, "reset passed: 0% used, next week 1 day in (-100/7)")
    check(slack(AccountUsage(fiveHour: WindowUsage(pct: 1, resetsAt: nil), fetchedAt: now, source: .api)) == nil, "no 7d reading -> no pace")

    // resets far apart: a lower 7d % is not the account to use when the other resets within hours
    let lopsided = [AccountState(name: "m04", usage: paced(20, 40, resetIn: 144)), AccountState(name: "m19", usage: paced(10, 70, resetIn: 5))]
    equal(HopPolicy.decide(live: "m04", states: lopsided, t: t7, now: now), .hop(to: "m19", reason: "dùng nốt m19 trước khi reset (còn 30%, 5h nữa)"),
          "m19's 30% left would be lost in 5h; m04 has 6 days")
    var noExpiry = t7; noExpiry.nearResetHours = 0
    equal(HopPolicy.decide(live: "m04", states: lopsided, t: noExpiry, now: now), .hop(to: "m19", reason: "cân bằng tuần: m04 +26 so với tiến độ, m19 -27 (chênh ≥ 10)"),
          "expiry tier off: the weekly pace alone gets there too")

    // the user's case: one account just reset, the other resets at the end of the day
    let justReset = AccountState(name: "m04", usage: paced(10, 2, resetIn: 166))
    let endOfDay = { (used: Double) in AccountState(name: "m19", usage: paced(5, used, resetIn: 10)) }
    equal(HopPolicy.decide(live: "m04", states: [justReset, endOfDay(60)], t: t7, now: now), .hop(to: "m19", reason: "dùng nốt m19 trước khi reset (còn 40%, 10h nữa)"),
          "move to the account whose week ends today")
    equal(HopPolicy.decide(live: "m04", states: [justReset, endOfDay(88)], t: t7, now: now), .hop(to: "m19", reason: "dùng nốt m19 trước khi reset (còn 12%, 10h nữa)"),
          "even near pace: the pace rule alone (gap 7 < 10) would stay on m04 and lose the 12%")
    if case .stay = HopPolicy.decide(live: "m04", states: [justReset, endOfDay(97)], t: t7, now: now) {} else { check(false, "3% left < margin: not worth restarting every session for") }
    equal(HopPolicy.ranked([justReset, endOfDay(97)], excluding: "m07", t: t7, now: now, maxAge: 300).first?.name, "m19",
          "but it is the first target once a hop happens anyway")
    equal(HopPolicy.decide(live: "m19", states: [justReset, endOfDay(88)], t: t7, now: now), .stay("dùng nốt m19 trước khi reset (còn 12%, 10h nữa)"),
          "live on the expiring account: stay, the pace rule would have moved away")
    let sooner = AccountState(name: "m07", usage: paced(5, 70, resetIn: 3))
    equal(HopPolicy.decide(live: "m19", states: [justReset, endOfDay(60), sooner], t: t7, now: now), .hop(to: "m07", reason: "dùng nốt m07 trước khi reset (còn 30%, 3h nữa)"),
          "two expiring: the earlier reset first")
    let soonerTiny = AccountState(name: "m07", usage: paced(5, 95, resetIn: 3))
    if case .stay = HopPolicy.decide(live: "m19", states: [justReset, endOfDay(60), soonerTiny], t: t7, now: now) {} else { check(false, "an earlier but tiny leftover does not pull the live expiring account away") }
    equal(HopPolicy.decide(live: "m19", states: [AccountState(name: "m19", usage: paced(95, 60, resetIn: 10)), justReset], t: t7, now: now),
          .hop(to: "m04", reason: "m19 5h 95% ≥ 90%"), "5h out on the expiring account: hop anyway")
    let today = [AccountState(name: "m04", usage: paced(100, 99, resetIn: 50.2)), AccountState(name: "m19", usage: paced(22, 63, resetIn: 39.2))]
    if case .stay = HopPolicy.decide(live: "m19", states: today, t: t7, now: now) {} else { check(false, "today: stay on m19 (behind pace, m04 out)") }
    let todayFresh = [AccountState(name: "m04", usage: paced(10, 99, resetIn: 50.2)), AccountState(name: "m19", usage: paced(22, 63, resetIn: 39.2))]
    equal(HopPolicy.decide(live: "m04", states: todayFresh, t: t7, now: now), .hop(to: "m19", reason: "cân bằng tuần: m04 +29 so với tiến độ, m19 -14 (chênh ≥ 10)"),
          "today from m04 with 5h left: still move to m19")

    let staleWeek = AccountUsage(fiveHour: WindowUsage(pct: 50, resetsAt: now.addingTimeInterval(-100)), sevenDay: WindowUsage(pct: 60, resetsAt: now.addingTimeInterval(86400)),
                                 fetchedAt: now.addingTimeInterval(-7200), source: .api)
    let staleEff = HopPolicy.effective(AccountState(name: "m19", usage: staleWeek, record: oldRecForBlock()), now: now, maxAge: 300)
    equal(staleEff.source, .recorded); equal(staleEff.sevenDay, 60, "stale 7d kept: a lower bound until its reset")
    var resetWeek = staleWeek; resetWeek.sevenDay = WindowUsage(pct: 60, resetsAt: now.addingTimeInterval(-1))
    equal(HopPolicy.effective(AccountState(name: "m19", usage: resetWeek), now: now, maxAge: 300).sevenDay, 0, "7d window already reset -> 0")
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

    check(block.contains("case \"$(alias claude 2>/dev/null)\" in"), "block keeps an alias claude set elsewhere")
    equal(ShellInstaller.conflicts(in: pluginRC), [], "inside the block and alias claude='claude-as' are not conflicts")
    equal(ShellInstaller.conflicts(in: block), [], "our own block is not a conflict")
    let userRC = """
    alias ll='ls -l'
    alias claude='claude --dangerously-skip-permissions'
    # alias claude='old'
    alias -g claude-as=x
    alias claude="claude-as"
    claude-as() { echo; }
    function claude-as { :; }
    claude-as m07
    alias claude='claude-as --x'
    """
    equal(ShellInstaller.conflicts(in: userRC).map(\.line), [2, 4, 6, 7, 9], "user aliases and functions on our names")
    let truncated = "# >>> claude-account >>>\nclaude-as() {\n}\nalias mine=x\nwt() { :; }\n\n# >>> claude-account >>>\nclaude-as() { new; }\n# <<< claude-account <<<\n"
    equal(ShellInstaller.existingBlock(in: truncated), "# >>> claude-account >>>\nclaude-as() { new; }\n# <<< claude-account <<<", "block = begin closest to the end marker")
    check(ShellInstaller.replaceBlock(in: truncated, with: "B").contains("alias mine=x\nwt() { :; }"), "replace keeps lines after a truncated block")
    equal(ShellInstaller.conflicts(in: truncated).map(\.line), [2], "a truncated block's claude-as is a conflict")
    let rcDir = FileManager.default.temporaryDirectory.appendingPathComponent("cs-rc-\(getpid())")
    try? FileManager.default.createDirectory(at: rcDir, withIntermediateDirectories: true)
    let rcURL = rcDir.appendingPathComponent(".zshrc")
    try? "alias claude='claude --foo'\n".write(to: rcURL, atomically: true, encoding: .utf8)
    check((try? ShellInstaller.installRC(rc: rcURL)) == nil, "installRC refuses on conflict")
    equal(try? String(contentsOf: rcURL, encoding: .utf8), "alias claude='claude --foo'\n", "rc untouched on conflict")
    try? FileManager.default.removeItem(at: rcDir)

    equal(ShellInstaller.shellQuote("a'b"), "'a'\\''b'")
    let shim = ShellInstaller.shimText(appBinary: "/Applications/X.app/Contents/MacOS/X")
    check(shim.hasPrefix("#!/bin/sh\n") && shim.contains("exec \"$APP\" \"$@\"") && shim.contains("= hook ] && exit 0"), "shim shape")
    let script = LoginLauncher.loginScript(cli: "/x/claude-switcher", name: "m07", email: "me@x.io")
    check(script.contains("cs='/x/claude-switcher'") && script.contains("login-prepare \"$name\"") && script.contains("login-finish \"$name\" \"$scratch\""), "login script uses prepare/finish")
    check(script.contains("claude auth login --email 'me@x.io'"), "bash runs claude auth login itself with the email")
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

    let log = "1\tm04\tm19\tapp\n2\tm19\tm04\tcli\n3\t\tm04\tmarker\nbroken line\n"
    equal(AccountStore.rewriteSwitches(log, from: "m04", to: "work"), "1\twork\tm19\tapp\n2\tm19\twork\tcli\n3\t\twork\tmarker\nbroken line\n", "rename rewrites from/to fields only")

    let plan = RestartPlan(to: "m19", created: now, pids: ["123": "m19"])
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    equal(try? dec.decode(RestartPlan.self, from: try enc.encode(plan)), plan, "plan round trip")
    check(Switcher.isValidName("m07") && Switcher.isValidName("a.b_c@d-e") && !Switcher.isValidName("bad name") && !Switcher.isValidName(""), "name validation")
    equal(Switcher.suggestName(email: "Miracle04@dlsinc.com", taken: []), "miracle04")
    equal(Switcher.suggestName(email: "miracle04@dlsinc.com", taken: ["miracle04", "miracle04-2"]), "miracle04-3")
    equal(Switcher.suggestName(email: "a+b@x.io", taken: []), "a-b")
    equal(Switcher.suggestName(email: nil, taken: []), "account")
    equal(Switcher.suggestName(email: "@x.io", taken: []), "account")
}

// MARK: credentials, snapshot ownership
do {
    let full = OAuthBlob(raw: #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1800000000000}}"#)
    check(full?.isComplete == true, "both tokens -> complete")
    check(OAuthBlob(raw: #"{"claudeAiOauth":{"accessToken":"","refreshToken":"r"}}"#)?.isComplete == false, "empty access token parses but is incomplete (the CLI used to accept it)")
    check(OAuthBlob(raw: #"{"claudeAiOauth":{"accessToken":"a"}}"#)?.isComplete == false, "no refresh token -> incomplete")
    check(OAuthBlob(raw: #"{"mcpOAuth":{}}"#) == nil && OAuthBlob(raw: "6a736f6e") == nil, "not an OAuth blob -> nil")
    check(full?.isExpired(at: Date(timeIntervalSince1970: 1_800_000_001)) == true, "expiry in ms")

    func prof(_ n: String, _ uuid: String) -> AccountProfile { AccountProfile(name: n, oauthAccount: OAuthAccount(accountUuid: uuid, emailAddress: "\(n)@x.io")) }
    let ps = [prof("m04", "u4"), prof("m19", "u19")]
    equal(Switcher.snapshotDecision(configName: "m19", owner: .confirmed(uuid: "u19", email: nil), profiles: ps, trustConfig: false), .save("m19"))
    equal(Switcher.snapshotDecision(configName: "m19", owner: .confirmed(uuid: "u4", email: nil), profiles: ps, trustConfig: true), .save("m04"),
          "drift: the live token goes to its real owner, never to the account the config names (the 2026-09-25 loss)")
    if case .skip = Switcher.snapshotDecision(configName: "m19", owner: .confirmed(uuid: "u7", email: "m07@x.io"), profiles: ps, trustConfig: true) {} else { check(false, "unsaved owner -> skip") }
    if case .skip = Switcher.snapshotDecision(configName: "m19", owner: .rejected(401), profiles: ps, trustConfig: true) {} else { check(false, "rejected token is never snapshotted") }
    equal(Switcher.snapshotDecision(configName: "m19", owner: .unknown, profiles: ps, trustConfig: true), .save("m19"), "unverifiable + trust -> config name (pre-0.5 rule)")
    if case .skip = Switcher.snapshotDecision(configName: "m19", owner: .unknown, profiles: ps, trustConfig: false) {} else { check(false, "periodic sync writes verified owners only") }
    if case .skip = Switcher.snapshotDecision(configName: nil, owner: .unknown, profiles: ps, trustConfig: true) {} else { check(false, "unsaved login, unverified -> skip") }

    equal(Switcher.targetProblem(owner: .confirmed(uuid: "u19", email: nil), expectedUuid: "u19", profiles: ps), nil)
    equal(Switcher.targetProblem(owner: .confirmed(uuid: "u4", email: nil), expectedUuid: "u19", profiles: ps), .wrongOwner("'m04'"), "snapshot holding another account's token")
    equal(Switcher.targetProblem(owner: .rejected(401), expectedUuid: "u19", profiles: ps), .rejected(401))
    equal(Switcher.targetProblem(owner: .unknown, expectedUuid: "u19", profiles: ps), nil, "cannot tell -> allowed")

    let dead = [AccountState(name: "m04", usage: api(96)), AccountState(name: "m19", record: oldRecForBlock(), blocked: "token bị từ chối"), AccountState(name: "m07", usage: api(50))]
    equal(HopPolicy.decide(live: "m04", states: dead, t: t, now: now), .hop(to: "m07", reason: "m04 5h 96% ≥ 90%"),
          "a blocked account is never a hop target, even at 0%")
    equal(HopPolicy.decide(live: "m04", states: Array(dead.prefix(2)), t: t, now: now), .allExhausted(nextReset: nil), "only a blocked account left -> nothing to hop to")

    let block = ShellInstaller.rcBlock()
    check(block.contains(#"if "$cs" use "$next"; then"#) && block.contains("resuming on the current login") && !block.contains(#""$cs" use "$next" || return"#),
          "claude-as resumes on the current login when the switch fails")
    check(LoginLauncher.loginScript(cli: "/x/cs", name: "m19", email: nil, relogin: true).contains(#"login-prepare --relogin "$name""#), "relogin script")
    check(!LoginLauncher.loginScript(cli: "/x/cs", name: "m19", email: nil).contains("--relogin"), "plain login script")
    check(CredentialProblem.missing.detail.hasPrefix("are ") && CredentialProblem.rejected(401).detail.contains("401"), "error detail wording")
}

// MARK: hop markers on disk (temp store)
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cs-checks-\(getpid())")
    setenv("CLAUDE_ACCOUNT_DIR", dir.path, 1)
    defer { unsetenv("CLAUDE_ACCOUNT_DIR"); try? FileManager.default.removeItem(at: dir) }
    let store = AccountStore()
    store.writeHopMarker(id: "1-2", "m19", sessionID: "sess-a")
    equal(try? String(contentsOf: Paths.hopMarker("1-2"), encoding: .utf8), "m19\n", "marker stays a bare name (pre-0.5 loops read it)")
    equal(try? String(contentsOf: Paths.hopSessionMarker("1-2"), encoding: .utf8), "sess-a\n")
    store.writeHopMarker(id: "3-4", "m04", sessionID: "sess-b")
    try? FileManager.default.removeItem(at: Paths.hopMarker("3-4"))
    store.pruneSessionMarkers(now: Date().addingTimeInterval(600))
    check(FileManager.default.fileExists(atPath: Paths.hopSessionMarker("1-2").path), "session file next to a live marker kept")
    check(!FileManager.default.fileExists(atPath: Paths.hopSessionMarker("3-4").path), "orphan session file (old loop took the marker) pruned")
    store.writeHopMarker(id: "5-6", "m04")
    check(!FileManager.default.fileExists(atPath: Paths.hopSessionMarker("5-6").path), "no session id -> no session file")
}

func oldRecForBlock() -> QuotaRecord { QuotaRecord(pct: 0, resetsAt: now.addingTimeInterval(-60), recordedAt: now.addingTimeInterval(-9000)) }

// MARK: Updater
do {
    check(Updater.isNewer("0.3.1", than: "0.3.0"), "patch bump is newer")
    check(Updater.isNewer("v0.4.0", than: "0.3.9"), "tag prefix ignored")
    check(Updater.isNewer("0.10.0", than: "0.9.9"), "numeric compare, not lexicographic")
    check(Updater.isNewer("1.0", than: "0.9.9"), "missing component counts as 0")
    check(!Updater.isNewer("0.3.0", than: "0.3.0"), "same version is not newer")
    check(!Updater.isNewer("0.2.9", than: "0.3.0"), "older is not newer")
    check(!Updater.isNewer("0.3.0", than: "0.3.0.1"), "extra component on current wins")
    equal(Updater.normalize(" v1.2.3\n"), "1.2.3")
    let cmd = Updater.upgradeCommand(dest: "/Users/x/My Apps", version: "0.4.0")
    check(cmd.contains("DEST='/Users/x/My Apps'"), "dest quoted: \(cmd)")
    check(cmd.contains("CLAUDE_SWITCHER_VERSION='0.4.0'"), "version pinned: \(cmd)")
    check(cmd.contains("scripts/install.sh"), "runs the repo installer: \(cmd)")
    check(!Updater.upgradeCommand(dest: "/Applications", version: nil).contains("CLAUDE_SWITCHER_VERSION"), "no version -> latest")
}

// MARK: background work (the Stop hook defers a restart while any is pending)
do {
    let clock = ISO8601.parse("2026-10-01T02:10:00Z")!
    func json(_ o: [String: Any], at: String = "2026-10-01T02:00:00.000Z") -> String {
        var o = o; o["timestamp"] = at
        return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }
    func result(_ r: [String: Any], at: String = "2026-10-01T02:00:00.000Z") -> String { json(["type": "user", "toolUseResult": r], at: at) }
    func queued(_ id: String, _ status: String) -> String {
        json(["type": "queue-operation", "operation": "enqueue", "content": "<task-notification>\n<task-id>\(id)</task-id>\n<status>\(status)</status>\n</task-notification>"])
    }
    func run(_ lines: [String]) -> [String] { BackgroundWork.pending(transcript: lines.joined(separator: "\n"), now: clock) }
    let shell = result(["backgroundTaskId": "bmsj88w9j", "stdout": ""])
    let agent = result(["isAsync": true, "status": "async_launched", "agentId": "a4dbb2adeccf14763"])
    let monitor = result(["taskId": "b699dwcuc", "timeoutMs": 1_800_000, "persistent": false])
    equal(run([shell, agent, monitor]), ["bmsj88w9j", "a4dbb2adeccf14763", "b699dwcuc"], "every launch shape is pending")
    equal(run([shell, agent, monitor, queued("bmsj88w9j", "completed"), queued("a4dbb2adeccf14763", "failed"),
               result(["task_id": "b699dwcuc", "message": "Successfully stopped task: b699dwcuc (tail -f)"])]),
          [], "completed, failed and TaskStop-ed work is no longer pending")
    equal(run([agent, queued("a4dbb2adeccf14763", "running")]), ["a4dbb2adeccf14763"], "a running notice is not an end")
    let idle = json(["type": "user", "message": ["content": "<task-notification>\n<task-id>bmsj88w9j</task-id>\n<status>killed</status>\n</task-notification>"]])
    equal(run([shell, idle]), [], "a notice delivered as a user message ends the task")
    let echoed = result(["stdout": "Monitor started (task b699dwcuc ... Command running in background with ID: zzz <task-id>bmsj88w9j</task-id><status>completed</status>"])
    equal(run([echoed]), [], "ids inside some command's output are not launches")
    equal(run([shell, echoed]), ["bmsj88w9j"], "nor are they ends")
    equal(run([result(["taskId": "bshort", "timeoutMs": 60_000, "persistent": false])]), [], "monitor past its own timeout")
    equal(run([result(["taskId": "bforever", "timeoutMs": 3_600_000, "persistent": true])]), [], "persistent monitor never holds a hop")
    equal(run([result(["backgroundTaskId": "oldjob1"], at: "2026-09-30T20:00:00.000Z")]), [], "launch older than maxAge")
    equal(run(["not json", ""]), [], "garbage lines ignored")
}

print("\(total - failed)/\(total) checks passed")
exit(failed == 0 ? 0 : 1)
