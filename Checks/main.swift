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
    let attributed = SessionAttribution.attribute(raw, history: history, fallback: "m04", loops: [2], cwds: [3: "/tmp"])
    equal(attributed[0].account, .assumed("m04"), "older than history -> assumed")
    equal(attributed[1].account, .known("m19"))
    equal(attributed[2].account, .known("m04"))
    check(attributed[1].isLoop && !attributed[0].isLoop, "loop flags")
    equal(attributed[2].cwd, "/tmp")
    equal(SessionAttribution.attribute([raw[0]], history: [], fallback: nil, loops: [], cwds: [:])[0].account, .unknown)
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

// MARK: hook script, launcher, plan
do {
    let s = HookScript.normalized
    check(s.hasPrefix("#!/usr/bin/env bash\n"), "shebang first")
    check(s.contains("kill -TERM \"$pid\"") && s.contains("CLAUDE_AS_LOOP") && s.contains("restart.json"), "hook body")
    check(!s.contains("\n    #!/"), "indentation stripped")
    equal(LoginLauncher.shellQuote("a'b"), "'a'\\''b'")
    check(LoginLauncher.loginScript(cli: "/x/claude-account", name: "m07", email: "me@x.io").contains("'/x/claude-account' login 'm07' --email 'me@x.io'"), "login command")
    check(!LoginLauncher.loginScript(cli: "/x/ca", name: "m07", email: nil).contains("--email"), "no email flag when empty")
    let plan = RestartPlan(to: "m19", created: now, pids: ["123": "m19"])
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    equal(try? dec.decode(RestartPlan.self, from: try enc.encode(plan)), plan, "plan round trip")
    check(CLI.isValidName("m07") && CLI.isValidName("a.b_c@d-e") && !CLI.isValidName("bad name") && !CLI.isValidName(""), "name validation")
}

print("\(total - failed)/\(total) checks passed")
exit(failed == 0 ? 0 : 1)
