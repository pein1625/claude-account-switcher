import Foundation

/// Reads the account's rate-limit windows straight from Anthropic with the OAuth token Claude Code already holds.
/// Read-only: the app never refreshes or mints tokens; an expired token simply means "no live reading".
public struct UsageClient {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    public var session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: cfg)
        }
    }

    private func request(_ url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeSwitcher/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        return req
    }

    public func fetchUsage(token: String, now: Date = Date()) async -> AccountUsage {
        do {
            let (data, resp) = try await session.data(for: request(Self.usageURL, token: token))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let body = String(decoding: data.prefix(300), as: UTF8.self)
                return AccountUsage(fetchedAt: now, source: .api, httpStatus: code, error: "HTTP \(code) \(body)")
            }
            guard var parsed = Self.parseUsage(data, now: now) else {
                return AccountUsage(fetchedAt: now, source: .api, httpStatus: code, error: "unexpected usage payload")
            }
            parsed.httpStatus = code
            return parsed
        } catch {
            return AccountUsage(fetchedAt: now, source: .api, error: error.localizedDescription)
        }
    }

    public struct Profile: Equatable {
        public var email: String?
        public var uuid: String?
        public var status: Int
    }

    public func fetchProfile(token: String) async -> Profile? {
        guard let (data, resp) = try? await session.data(for: request(Self.profileURL, token: token)) else { return nil }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Profile(email: nil, uuid: nil, status: code)
        }
        let account = root["account"] as? [String: Any] ?? root
        return Profile(email: account["email"] as? String ?? account["email_address"] as? String,
                       uuid: account["uuid"] as? String ?? account["account_uuid"] as? String,
                       status: code)
    }

    /// Accepts `{ "five_hour": {"utilization": 25.0, "resets_at": "..."}, "seven_day": {...}, ... }`.
    /// Any other top-level object carrying `utilization` is kept under `extras` (opus / sonnet windows).
    public static func parseUsage(_ data: Data, now: Date) -> AccountUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var five: WindowUsage?, seven: WindowUsage?
        var extras: [String: WindowUsage] = [:]
        for (key, value) in root {
            guard let obj = value as? [String: Any], let w = window(obj) else { continue }
            switch key {
            case "five_hour": five = w
            case "seven_day": seven = w
            default: extras[key] = w
            }
        }
        guard five != nil || seven != nil else { return nil }
        return AccountUsage(fiveHour: five, sevenDay: seven, extras: extras, fetchedAt: now, source: .api)
    }

    private static func window(_ obj: [String: Any]) -> WindowUsage? {
        let raw = obj["utilization"] ?? obj["used_percentage"]
        guard let pct = (raw as? Double) ?? (raw as? Int).map(Double.init) else { return nil }
        return WindowUsage(pct: pct, resetsAt: date(obj["resets_at"]))
    }

    static func date(_ v: Any?) -> Date? {
        if let s = v as? String { return ISO8601.parse(s) }
        if let n = v as? Double, n > 0 { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        if let n = v as? Int, n > 0 { return Date(timeIntervalSince1970: n > 1_000_000_000_000 ? Double(n) / 1000 : Double(n)) }
        return nil
    }
}

public enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    public static func parse(_ s: String) -> Date? { withFraction.date(from: s) ?? plain.date(from: s) }
    public static func string(_ d: Date) -> String { plain.string(from: d) }
}
