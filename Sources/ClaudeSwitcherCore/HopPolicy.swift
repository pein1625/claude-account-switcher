import Foundation

public struct Thresholds: Equatable {
    public var hopAt: Double
    public var sevenDayAt: Double
    /// Pace every account's weekly quota to its own reset: candidates rank by `weekSlack` (most behind schedule
    /// first), and the live account is left once its slack is `sevenDayMargin` points above the best candidate's -
    /// not only when its 5h runs out. Behind schedule = quota that would be lost at the reset; ahead = an account
    /// that would run dry early and leave only the others' 5h windows. The margin keeps two accounts from swapping
    /// back and forth (every switch restarts the running sessions).
    public var prefer7d: Bool
    public var sevenDayMargin: Double
    /// With `prefer7d`: an account whose week resets within this many hours and still has quota is used first,
    /// earliest reset first - whatever it has left is lost at the reset, while the others keep theirs. 0 = off.
    public var nearResetHours: Double

    public init(hopAt: Double = 90, sevenDayAt: Double = 100, prefer7d: Bool = false, sevenDayMargin: Double = 10,
                nearResetHours: Double = 24) {
        self.hopAt = hopAt; self.sevenDayAt = sevenDayAt; self.prefer7d = prefer7d; self.sevenDayMargin = sevenDayMargin
        self.nearResetHours = nearResetHours
    }
}

public struct AccountState: Equatable {
    public var name: String
    public var usage: AccountUsage?
    public var record: QuotaRecord?
    public var forcedExhaustedUntil: Date?
    /// Why this account cannot be switched to right now (dead snapshot, a hop to it just failed); never a target.
    public var blocked: String?

    public init(name: String, usage: AccountUsage? = nil, record: QuotaRecord? = nil, forcedExhaustedUntil: Date? = nil, blocked: String? = nil) {
        self.name = name; self.usage = usage; self.record = record; self.forcedExhaustedUntil = forcedExhaustedUntil
        self.blocked = blocked
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
    /// (same optimism as `claude-account next`). The 7d number comes from the last API reading even when it is
    /// stale: a week's usage only grows until its reset, so an old reading is a lower bound, and a non-live
    /// account's token expires after a few hours while its 7d still decides where to go.
    public static func effective(_ s: AccountState, now: Date, maxAge: TimeInterval) -> Effective {
        let seven = s.usage?.sevenDay.map { w in (w.resetsAt.map { now >= $0 } ?? false) ? 0 : w.pct }
        let sevenAt = s.usage?.sevenDay?.resetsAt
        if let until = s.forcedExhaustedUntil, until > now {
            return Effective(name: s.name, fiveHour: 100, fiveResetsAt: until, sevenDay: seven, sevenResetsAt: sevenAt, source: .event)
        }
        if let u = s.usage, u.isFreshAPI, now.timeIntervalSince(u.fetchedAt) <= maxAge, let five = u.fiveHour {
            let fivePct = (five.resetsAt.map { now >= $0 } ?? false) ? 0 : five.pct
            return Effective(name: s.name, fiveHour: fivePct, fiveResetsAt: five.resetsAt, sevenDay: seven, sevenResetsAt: sevenAt, source: .api)
        }
        if let r = s.record {
            return Effective(name: s.name, fiveHour: Double(r.effectivePct(now: now)), fiveResetsAt: r.resetsAt,
                             sevenDay: seven, sevenResetsAt: sevenAt, source: .recorded)
        }
        return Effective(name: s.name, fiveHour: 0, fiveResetsAt: nil, sevenDay: seven, sevenResetsAt: sevenAt, source: .none)
    }

    /// Enough 5h room to be worth moving to for the 7d balance: the margin below the hop threshold.
    static func hasRoom(_ e: Effective, _ t: Thresholds) -> Bool { e.fiveHour + t.sevenDayMargin < t.hopAt }

    public static let week: TimeInterval = 7 * 86400

    /// 7d used minus the share of the week already elapsed, in points: 0 = on pace to land at 100% exactly at the
    /// reset, negative = behind (that much would be lost at the reset), positive = ahead (runs out before it).
    /// A reset already passed rolls forward by whole weeks. Nil when the 7d window was never measured.
    public static func weekSlack(_ e: Effective, now: Date) -> Double? {
        guard let used = e.sevenDay, var reset = e.sevenResetsAt else { return nil }
        while reset <= now { reset = reset.addingTimeInterval(week) }
        let elapsed = min(max(1 - reset.timeIntervalSince(now) / week, 0), 1)
        return used - 100 * elapsed
    }

    public static func isExhausted(_ e: Effective, _ t: Thresholds) -> Bool {
        e.fiveHour >= t.hopAt || (e.sevenDay ?? 0) >= t.sevenDayAt
    }

    /// Weekly quota the reset throws away within `nearResetHours` unless it is used: points left, hours to reset.
    public static func expiring(_ e: Effective, _ t: Thresholds, now: Date) -> (left: Double, hours: Double)? {
        guard t.prefer7d, t.nearResetHours > 0, let used = e.sevenDay, let reset = e.sevenResetsAt, reset > now else { return nil }
        let hours = reset.timeIntervalSince(now) / 3600
        let left = t.sevenDayAt - used
        guard hours <= t.nearResetHours, left > 0 else { return nil }
        return (left, hours)
    }

    /// Resets at least an hour earlier: closer than that the two deadlines count as the same.
    static func sooner(_ a: (left: Double, hours: Double)?, than b: (left: Double, hours: Double)?) -> Bool {
        guard let a else { return false }
        guard let b else { return true }
        return a.hours + 1 <= b.hours
    }

    /// Candidates ordered best-first. `prefer7d`: accounts with 5h room first, then quota about to expire
    /// (earliest reset first), then furthest behind their weekly pace, then lowest 5h. Otherwise lowest 5h, then
    /// lowest 7d. Name breaks ties.
    public static func ranked(_ states: [AccountState], excluding live: String?, t: Thresholds, now: Date, maxAge: TimeInterval) -> [Effective] {
        states.filter { $0.name != live && $0.blocked == nil }
            .map { effective($0, now: now, maxAge: maxAge) }
            .filter { !isExhausted($0, t) }
            .sorted { a, b in
                let (a7, b7) = (a.sevenDay ?? 0, b.sevenDay ?? 0)
                if t.prefer7d {
                    let (ra, rb) = (hasRoom(a, t), hasRoom(b, t))
                    if ra != rb { return ra }
                    let (xa, xb) = (expiring(a, t, now: now), expiring(b, t, now: now))
                    if sooner(xa, than: xb) { return true }
                    if sooner(xb, than: xa) { return false }
                    let (sa, sb) = (weekSlack(a, now: now) ?? 0, weekSlack(b, now: now) ?? 0)
                    if sa != sb { return sa < sb }
                    if a.fiveHour != b.fiveHour { return a.fiveHour < b.fiveHour }
                } else {
                    if a.fiveHour != b.fiveHour { return a.fiveHour < b.fiveHour }
                    if a7 != b7 { return a7 < b7 }
                }
                return a.name < b.name
            }
    }

    /// `lastManualSwitchAt`: the user picked the live account themselves (menu, terminal, /login); the 7d balance
    /// leaves that choice alone for `manualHold`. Running out of quota still hops at once.
    public static func decide(live: String?, states: [AccountState], t: Thresholds, now: Date,
                              maxAge: TimeInterval = 300, lastHopAt: Date? = nil, cooldown: TimeInterval = 600,
                              lastSwitchAt: Date? = nil, settle: TimeInterval = 30,
                              lastManualSwitchAt: Date? = nil, manualHold: TimeInterval = 3600) -> Decision {
        guard let live, let liveState = states.first(where: { $0.name == live }) else {
            return .hold("login hiện tại chưa được lưu (claude-account save)")
        }
        func waiting() -> Decision? {
            if let s = lastSwitchAt, now.timeIntervalSince(s) < settle {
                return .hold("vừa đổi account \(Int(now.timeIntervalSince(s)))s trước, chờ ổn định")
            }
            if let h = lastHopAt, now.timeIntervalSince(h) < cooldown {
                return .hold("cooldown sau lần hop trước (\(Int((cooldown - now.timeIntervalSince(h)) / 60)) phút)")
            }
            return nil
        }
        let liveEff = effective(liveState, now: now, maxAge: maxAge)
        let candidates = ranked(states, excluding: live, t: t, now: now, maxAge: maxAge)
        guard isExhausted(liveEff, t) else {
            let stay = Decision.stay(String(format: "%@ 5h %.0f%% < %.0f%%", live, liveEff.fiveHour, t.hopAt))
            guard t.prefer7d else { return stay }
            // use it or lose it: quota the reset is about to throw away beats the weekly pace
            let liveX = expiring(liveEff, t, now: now)
            if let best = candidates.first, let bestX = expiring(best, t, now: now), sooner(bestX, than: liveX),
               bestX.left >= t.sevenDayMargin, hasRoom(best, t) {
                let why = String(format: "dùng nốt %@ trước khi reset (còn %.0f%%, %.0fh nữa)", best.name, bestX.left, bestX.hours)
                if let m = lastManualSwitchAt, now.timeIntervalSince(m) < manualHold {
                    return .hold("giữ account chọn tay thêm \(Int((manualHold - now.timeIntervalSince(m)) / 60) + 1) phút, rồi \(why)")
                }
                return waiting() ?? .hop(to: best.name, reason: why)
            }
            // same deadline on both sides: nothing to choose on expiry, the weekly pace decides
            let sameDeadline = candidates.contains { c in
                guard let cx = expiring(c, t, now: now), let liveX else { return false }
                return !sooner(cx, than: liveX) && !sooner(liveX, than: cx)
            }
            if let liveX, !sameDeadline {
                return .stay(String(format: "dùng nốt %@ trước khi reset (còn %.0f%%, %.0fh nữa)", live, liveX.left, liveX.hours))
            }
            guard let liveSlack = weekSlack(liveEff, now: now),
                  let best = candidates.first(where: { weekSlack($0, now: now) != nil }), let bestSlack = weekSlack(best, now: now),
                  liveSlack - bestSlack >= t.sevenDayMargin, hasRoom(best, t) else { return stay }
            let why = String(format: "tuần: %@ %+.0f so với tiến độ, %@ %+.0f (chênh ≥ %.0f)", live, liveSlack, best.name, bestSlack, t.sevenDayMargin)
            if let m = lastManualSwitchAt, now.timeIntervalSince(m) < manualHold {
                return .hold("giữ account chọn tay thêm \(Int((manualHold - now.timeIntervalSince(m)) / 60) + 1) phút, rồi cân bằng \(why)")
            }
            return waiting() ?? .hop(to: best.name, reason: "cân bằng \(why)")
        }
        guard let best = candidates.first else {
            let resets = states.filter { $0.name != live && $0.blocked == nil }
                .map { effective($0, now: now, maxAge: maxAge) }
                .compactMap { $0.fiveResetsAt }
                .filter { $0 > now }
                .min()
            return .allExhausted(nextReset: resets)
        }
        if let w = waiting() { return w }
        let why: String
        if liveEff.fiveHour >= t.hopAt {
            why = String(format: "%@ 5h %.0f%% ≥ %.0f%%", live, liveEff.fiveHour, t.hopAt)
        } else {
            why = String(format: "%@ 7d %.0f%% ≥ %.0f%%", live, liveEff.sevenDay ?? 0, t.sevenDayAt)
        }
        return .hop(to: best.name, reason: why)
    }
}
