import Foundation
import ClaudeSwitcherCore

/// `claude-switcher hook` - the Stop / StopFailure(rate_limit) hook body. Ends THIS claude process at its turn
/// boundary when the app listed its pid in `.switcher/restart.json`; the `claude-as` loop around the process
/// then reads the relaunch target and runs `claude --continue` as that account. Sessions not started through a
/// loop are left alone. On a rate-limit failure the event is reported first so the app can decide a hop.
enum HookRunner {
    static func run(stdin: Data, env: [String: String], now: Date = Date()) -> Int32 {
        let store = AccountStore()
        let json = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any] ?? [:]
        if let agent = json["agent_id"] as? String, !agent.isEmpty { return 0 }
        let event = json["hook_event_name"] as? String ?? "Stop"
        guard let pid = resolveClaudePid(env: env) else { return 0 }

        if event == "StopFailure" {
            store.appendEvent(RateLimitEvent(at: now, pid: pid))
            if store.appAlive(now: now) {
                var tries = 0
                while tries < 10, store.readRestartPlan()?.pids[String(pid)] == nil {
                    Thread.sleep(forTimeInterval: 0.5)
                    tries += 1
                }
            }
        }

        guard let target = store.readRestartPlan()?.pids[String(pid)], !target.isEmpty else { return 0 }
        guard env["CLAUDE_AS_LOOP"] == "1" else { return 0 }

        if let id = env["CLAUDE_AS_ID"], !id.isEmpty {
            store.writeHopMarker(id: id, target)
        } else {
            store.writeHop(target)
        }
        store.appendRestartLog("\(ISO8601.string(now))\t\(event)\thop=\(target)\tpid=\(pid)")
        if env["CLAUDE_SWITCHER_DRY_RUN"] != nil { return 0 }
        kill(pid, SIGTERM)
        return 0
    }

    /// CLAUDE_PID when it is one of our ancestors; otherwise the nearest ancestor whose executable is `claude`.
    static func resolveClaudePid(env: [String: String]) -> Int32? {
        guard let r = try? Shell.runSync("/bin/ps", ["-axo", "pid=,ppid=,comm="], timeout: 10), r.ok else { return nil }
        var parent: [Int32: Int32] = [:]
        var comm: [Int32: String] = [:]
        for line in r.stdout.split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard cols.count == 3, let pid = Int32(cols[0]), let ppid = Int32(cols[1]) else { continue }
            parent[pid] = ppid
            comm[pid] = String(cols[2])
        }
        var chain: [Int32] = []
        var p = getppid()
        while p > 1, chain.count < 64 {
            chain.append(p)
            p = parent[p] ?? 0
        }
        if env["CLAUDE_SWITCHER_DEBUG"] != nil {
            let desc = chain.map { "\($0):\(comm[$0] ?? "?")" }.joined(separator: " <- ")
            FileHandle.standardError.write(Data("hook: ppid \(getppid()) chain \(desc) CLAUDE_PID=\(env["CLAUDE_PID"] ?? "-")\n".utf8))
        }
        if let s = env["CLAUDE_PID"], let cp = Int32(s), chain.contains(cp) { return cp }
        return chain.first { (comm[$0].map { ($0 as NSString).lastPathComponent } ?? "") == "claude" }
    }
}
