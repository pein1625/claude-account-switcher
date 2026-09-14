import Foundation

public struct OAuthAccount: Codable, Equatable {
    public var accountUuid: String?
    public var emailAddress: String?
    public var organizationUuid: String?
    public var organizationName: String?
    public var displayName: String?
    public var hasExtraUsageEnabled: Bool?
    public var organizationRateLimitTier: String?

    public init(accountUuid: String? = nil, emailAddress: String? = nil, organizationUuid: String? = nil,
                organizationName: String? = nil, displayName: String? = nil,
                hasExtraUsageEnabled: Bool? = nil, organizationRateLimitTier: String? = nil) {
        self.accountUuid = accountUuid
        self.emailAddress = emailAddress
        self.organizationUuid = organizationUuid
        self.organizationName = organizationName
        self.displayName = displayName
        self.hasExtraUsageEnabled = hasExtraUsageEnabled
        self.organizationRateLimitTier = organizationRateLimitTier
    }
}

/// `~/.claude/accounts/<name>.json` as written by `claude-account save`.
public struct AccountProfile: Codable, Identifiable, Equatable {
    public var name: String
    public var saved_at: String?
    public var subscriptionType: String?
    public var oauthAccount: OAuthAccount

    public var id: String { name }
    public var email: String { oauthAccount.emailAddress ?? "?" }
    public var plan: String { subscriptionType ?? "-" }
    public var org: String { oauthAccount.organizationName ?? "-" }
    public var uuid: String? { oauthAccount.accountUuid }

    public init(name: String, saved_at: String? = nil, subscriptionType: String? = nil, oauthAccount: OAuthAccount) {
        self.name = name
        self.saved_at = saved_at
        self.subscriptionType = subscriptionType
        self.oauthAccount = oauthAccount
    }
}

public struct WindowUsage: Codable, Equatable {
    public var pct: Double
    public var resetsAt: Date?
    public init(pct: Double, resetsAt: Date?) { self.pct = pct; self.resetsAt = resetsAt }
}

public enum UsageSource: String, Codable {
    case api        // fetched from the OAuth usage endpoint with the account's own token
    case recorded   // last `<name>.quota` reading the statusline / app wrote
    case event      // a StopFailure(rate_limit) hook event for a session on this account
    case none
}

public struct AccountUsage: Codable, Equatable {
    public var fiveHour: WindowUsage?
    public var sevenDay: WindowUsage?
    public var extras: [String: WindowUsage]
    public var fetchedAt: Date
    public var source: UsageSource
    public var httpStatus: Int?
    public var error: String?
    public var tokenExpiresAt: Date?

    public init(fiveHour: WindowUsage? = nil, sevenDay: WindowUsage? = nil, extras: [String: WindowUsage] = [:],
                fetchedAt: Date, source: UsageSource, httpStatus: Int? = nil, error: String? = nil,
                tokenExpiresAt: Date? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.extras = extras
        self.fetchedAt = fetchedAt
        self.source = source
        self.httpStatus = httpStatus
        self.error = error
        self.tokenExpiresAt = tokenExpiresAt
    }

    public var isFreshAPI: Bool { source == .api && error == nil && fiveHour != nil }
}

/// One line of `<name>.quota`: `pct<TAB>resets_epoch<TAB>recorded_epoch`.
public struct QuotaRecord: Equatable {
    public var pct: Int
    public var resetsAt: Date?
    public var recordedAt: Date?

    public init(pct: Int, resetsAt: Date?, recordedAt: Date?) {
        self.pct = pct; self.resetsAt = resetsAt; self.recordedAt = recordedAt
    }

    public init?(line: String) {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", omittingEmptySubsequences: false)
        guard let first = parts.first, let pct = Int(first.split(separator: ".").first ?? "") else { return nil }
        self.pct = pct
        self.resetsAt = parts.count > 1 ? QuotaRecord.epoch(parts[1]) : nil
        self.recordedAt = parts.count > 2 ? QuotaRecord.epoch(parts[2]) : nil
    }

    private static func epoch(_ s: Substring) -> Date? {
        guard let v = TimeInterval(s), v > 0 else { return nil }
        return Date(timeIntervalSince1970: v)
    }

    public func line(now: Date) -> String {
        let resets = resetsAt.map { Int($0.timeIntervalSince1970) } ?? 0
        let rec = Int((recordedAt ?? now).timeIntervalSince1970)
        return "\(pct)\t\(resets)\t\(rec)\n"
    }

    /// Same rule as `claude-account`'s quota_score: a window whose reset time has passed counts as 0.
    public func effectivePct(now: Date) -> Int {
        if let r = resetsAt, now >= r { return 0 }
        return pct
    }
}

public struct SwitchEvent: Equatable {
    public var at: Date
    public var from: String?
    public var to: String
    public var by: String

    public init(at: Date, from: String?, to: String, by: String) {
        self.at = at; self.from = from; self.to = to; self.by = by
    }
}

public enum Attribution: Equatable {
    case known(String)
    case assumed(String)
    case unknown

    public var name: String? {
        switch self {
        case .known(let n), .assumed(let n): return n
        case .unknown: return nil
        }
    }
    public var isAssumed: Bool { if case .assumed = self { return true } else { return false } }
}

/// What the `claude-as` wrapper exported into a session's environment: `CLAUDE_AS_LOOP=1` (any wrapper) and
/// `CLAUDE_AS_ID` (this app's wrapper; lets the hook hand the relaunch target to exactly that loop).
public struct LoopInfo: Equatable {
    public var isLoop: Bool
    public var id: String?
    public init(isLoop: Bool, id: String?) { self.isLoop = isLoop; self.id = id }
}

public struct Session: Identifiable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var startedAt: Date
    public var command: String
    public var isLoop: Bool
    public var loopID: String?
    public var cwd: String?
    public var account: Attribution

    public var id: Int32 { pid }

    public init(pid: Int32, ppid: Int32, startedAt: Date, command: String, isLoop: Bool, loopID: String? = nil, cwd: String?, account: Attribution) {
        self.pid = pid; self.ppid = ppid; self.startedAt = startedAt; self.command = command
        self.isLoop = isLoop; self.loopID = loopID; self.cwd = cwd; self.account = account
    }
}

/// `.switcher/restart.json`: sessions the hook may restart at their next turn boundary, pid -> target account.
public struct RestartPlan: Codable, Equatable {
    public var to: String
    public var created: Date
    public var pids: [String: String]

    public init(to: String, created: Date, pids: [String: String]) {
        self.to = to; self.created = created; self.pids = pids
    }

    /// A damaged `created` must not disable the hook: only `pids` carries meaning.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        to = try c.decode(String.self, forKey: .to)
        pids = try c.decode([String: String].self, forKey: .pids)
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
    }
}

public struct RateLimitEvent: Equatable {
    public var at: Date
    public var pid: Int32
    public init(at: Date, pid: Int32) { self.at = at; self.pid = pid }
}

public enum AppInfo {
    public static let version = "0.2.1"
    public static let bundleID = "com.hapk.claude-switcher"
    public static let name = "Claude Switcher"
}
