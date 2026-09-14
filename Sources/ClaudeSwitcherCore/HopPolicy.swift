import Foundation

public struct Thresholds: Equatable {
    public var hopAt: Double
    public var sevenDayAt: Double
    public init(hopAt: Double = 90, sevenDayAt: Double = 100) { self.hopAt = hopAt; self.sevenDayAt = sevenDayAt }
}

public struct AccountState: Equatable {
    public var name: String
    public var usage: AccountUsage?
    public var record: QuotaRecord?
    public var forcedExhaustedUntil: Date?

    public init(name: String, usage: AccountUsage? = nil, record: QuotaRecord? = nil, forcedExhaustedUntil: Date? = nil) {
        self.name = name; self.usage = usage; self.record = record; self.forcedExhaustedUntil = forcedExhaustedUntil
    }
}

public struct Effective: Equatable {
    public var name: String
    public var fiveHour: Double
    public var fiveResetsAt: Date?
    public var sevenDay: Double?
    public var sevenResetsAt: Date?
    public var source: UsageSource
}

public enum Decision: Equatable {
    case stay(String)
    case hop(to: String, reason: String)
    case allExhausted(nextReset: Date?)
    case hold(String)
}

/// Pure decision logic; the app feeds it state, tests feed it fixtures.
public enum HopPolicy {
    /// What the account's windows look like right now, from the best source available:
    /// a rate-limit event beats a fresh API reading beats the recorded `.quota` line; nothing known counts as 0
    /// (same optimism as `claude-account next`).
    public static func effective(_ s: AccountState, now: Date, maxAge: TimeInterval) -> Effective {
        if let until = s.forcedExhaustedUntil, until > now {
            return Effective(name: s.name, fiveHour: 100, fiveResetsAt: until,
                             sevenDay: s.usage?.sevenDay?.pct, sevenResetsAt: s.usage?.sevenDay?.resetsAt, source: .event)
        }
        if let u = s.usage, u.isFreshAPI, now.timeIntervalSince(u.fetchedAt) <= maxAge, let five = u.fiveHour {
            let fivePct = (five.resetsAt.map { now >= $0 } ?? false) ? 0 : five.pct
            let sevenPct = u.sevenDay.map { w in (w.resetsAt.map { now >= $0 } ?? false) ? 0 : w.pct }
            return Effective(name: s.name, fiveHour: fivePct, fiveResetsAt: five.resetsAt,
                             sevenDay: sevenPct, sevenResetsAt: u.sevenDay?.resetsAt, source: .api)
        }
        if let r = s.record {
            return Effective(name: s.name, fiveHour: Double(r.effectivePct(now: now)), fiveResetsAt: r.resetsAt,
                             sevenDay: nil, sevenResetsAt: nil, source: .recorded)
        }
        return Effective(name: s.name, fiveHour: 0, fiveResetsAt: nil, sevenDay: nil, sevenResetsAt: nil, source: .none)
    }

    public static func isExhausted(_ e: Effective, _ t: Thresholds) -> Bool {
        e.fiveHour >= t.hopAt || (e.sevenDay ?? 0) >= t.sevenDayAt
    }

    /// Candidates ordered best-first: lowest 5h, then lowest 7d, then name.
    public static func ranked(_ states: [AccountState], excluding live: String?, t: Thresholds, now: Date, maxAge: TimeInterval) -> [Effective] {
        states.filter { $0.name != live }
            .map { effective($0, now: now, maxAge: maxAge) }
            .filter { !isExhausted($0, t) }
            .sorted { a, b in
                if a.fiveHour != b.fiveHour { return a.fiveHour < b.fiveHour }
                if (a.sevenDay ?? 0) != (b.sevenDay ?? 0) { return (a.sevenDay ?? 0) < (b.sevenDay ?? 0) }
                return a.name < b.name
            }
    }

    public static func decide(live: String?, states: [AccountState], t: Thresholds, now: Date,
                              maxAge: TimeInterval = 300, lastHopAt: Date? = nil, cooldown: TimeInterval = 600,
                              lastSwitchAt: Date? = nil, settle: TimeInterval = 30) -> Decision {
        guard let live, let liveState = states.first(where: { $0.name == live }) else {
            return .hold("login hiện tại chưa được lưu (claude-account save)")
        }
        let liveEff = effective(liveState, now: now, maxAge: maxAge)
        guard isExhausted(liveEff, t) else {
            return .stay(String(format: "%@ 5h %.0f%% < %.0f%%", live, liveEff.fiveHour, t.hopAt))
        }
        let candidates = ranked(states, excluding: live, t: t, now: now, maxAge: maxAge)
        guard let best = candidates.first else {
            let resets = states.filter { $0.name != live }
                .map { effective($0, now: now, maxAge: maxAge) }
                .compactMap { $0.fiveResetsAt }
                .filter { $0 > now }
                .min()
            return .allExhausted(nextReset: resets)
        }
        if let s = lastSwitchAt, now.timeIntervalSince(s) < settle {
            return .hold("vừa đổi account \(Int(now.timeIntervalSince(s)))s trước, chờ ổn định")
        }
        if let h = lastHopAt, now.timeIntervalSince(h) < cooldown {
            return .hold("cooldown sau lần hop trước (\(Int((cooldown - now.timeIntervalSince(h)) / 60)) phút)")
        }
        let why: String
        if liveEff.fiveHour >= t.hopAt {
            why = String(format: "%@ 5h %.0f%% ≥ %.0f%%", live, liveEff.fiveHour, t.hopAt)
        } else {
            why = String(format: "%@ 7d %.0f%% ≥ %.0f%%", live, liveEff.sevenDay ?? 0, t.sevenDayAt)
        }
        return .hop(to: best.name, reason: why)
    }
}
