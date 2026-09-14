import Foundation

public struct RawSession: Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var startedAt: Date
    public var command: String
    public init(pid: Int32, ppid: Int32, startedAt: Date, command: String) {
        self.pid = pid; self.ppid = ppid; self.startedAt = startedAt; self.command = command
    }
}

/// Finds running Claude Code processes. A session binds to one account for its whole life (the token sits
/// in memory), so the account is inferred from the process start time against the switch history.
public enum SessionScanner {
    public static func scan(now: Date = Date()) async -> [RawSession] {
        guard let r = try? await Shell.run("/bin/ps", ["-axo", "pid=,ppid=,etime=,comm=,args="], timeout: 15), r.ok else { return [] }
        return parsePS(r.stdout, now: now)
    }

    public static func parsePS(_ output: String, now: Date) -> [RawSession] {
        var out: [RawSession] = []
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard cols.count >= 4, let pid = Int32(cols[0]), let ppid = Int32(cols[1]) else { continue }
            let comm = String(cols[3])
            guard comm == "claude" || comm.hasSuffix("/claude") else { continue }
            guard let elapsed = parseEtime(String(cols[2])) else { continue }
            let args = cols.count > 4 ? String(cols[4]).trimmingCharacters(in: .whitespaces) : comm
            out.append(RawSession(pid: pid, ppid: ppid, startedAt: now.addingTimeInterval(-elapsed), command: args))
        }
        return out.sorted { $0.startedAt < $1.startedAt }
    }

    /// `[[dd-]hh:]mm:ss`
    public static func parseEtime(_ s: String) -> TimeInterval? {
        var days = 0
        var rest = s
        if let dash = s.firstIndex(of: "-") {
            guard let d = Int(s[..<dash]) else { return nil }
            days = d
            rest = String(s[s.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").map { Int($0) }
        guard !parts.contains(nil) else { return nil }
        let nums = parts.compactMap { $0 }
        var secs = 0
        switch nums.count {
        case 3: secs = nums[0] * 3600 + nums[1] * 60 + nums[2]
        case 2: secs = nums[0] * 60 + nums[1]
        default: return nil
        }
        return TimeInterval(days * 86400 + secs)
    }

    /// pids whose environment carries `CLAUDE_AS_LOOP=1`: only those sessions get relaunched with `--continue` after exit.
    public static func loopFlags(pids: [Int32]) async -> Set<Int32> {
        guard !pids.isEmpty else { return [] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let r = try? await Shell.run("/bin/ps", ["-Eww", "-o", "pid=,command=", "-p", list], timeout: 15), r.ok else { return [] }
        var flagged = Set<Int32>()
        for line in r.stdout.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let sp = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<sp]) else { continue }
            if trimmed.contains(" CLAUDE_AS_LOOP=1") { flagged.insert(pid) }
        }
        return flagged
    }

    public static func cwds(pids: [Int32]) async -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let r = try? await Shell.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", list], timeout: 10) else { return [:] }
        var map: [Int32: String] = [:]
        var current: Int32?
        for line in r.stdout.split(separator: "\n") {
            guard let first = line.first else { continue }
            let body = String(line.dropFirst())
            switch first {
            case "p": current = Int32(body)
            case "n": if let c = current { map[c] = body }
            default: break
            }
        }
        return map
    }
}

public enum SessionAttribution {
    /// `history` must be sorted by time. A session started after switch N and before switch N+1 runs as N's target.
    /// Sessions older than the first known switch get `.assumed(fallback)`: the steady-state account.
    public static func attribute(_ raw: [RawSession], history: [SwitchEvent], fallback: String?,
                                 loops: Set<Int32>, cwds: [Int32: String]) -> [Session] {
        raw.map { s in
            let account: Attribution
            if let ev = history.last(where: { $0.at <= s.startedAt }) {
                account = .known(ev.to)
            } else if let f = fallback {
                account = .assumed(f)
            } else {
                account = .unknown
            }
            return Session(pid: s.pid, ppid: s.ppid, startedAt: s.startedAt, command: s.command,
                           isLoop: loops.contains(s.pid), cwd: cwds[s.pid], account: account)
        }
    }
}
