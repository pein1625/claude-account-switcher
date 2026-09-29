import Foundation
import CryptoKit

/// The Keychain blob Claude Code stores under service `Claude Code-credentials`.
/// Only the fields the app needs are parsed; `raw` is kept verbatim for copy operations and never logged.
public struct OAuthBlob {
    public let raw: String
    public let accessToken: String
    public let hasRefreshToken: Bool
    public let expiresAt: Date?
    public let refreshTokenExpiresAt: Date?
    public let subscriptionType: String?

    /// SHA-256 of the raw blob: lets callers notice "the live item changed" without holding the secret.
    public var fingerprint: String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Claude Code can sign in with it. `claude-account`'s `is_oauth_blob` applies the same rule: a blob that
    /// only one of the two tools accepts lets the CLI switch into a login the app then calls unreadable.
    public var isComplete: Bool { !accessToken.isEmpty && hasRefreshToken }

    /// Any `claudeAiOauth` object parses, empty tokens included; `isComplete` says whether it can be used.
    public init?(raw: String) {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        self.raw = raw
        self.accessToken = (oauth["accessToken"] as? String) ?? ""
        self.hasRefreshToken = !((oauth["refreshToken"] as? String) ?? "").isEmpty
        self.expiresAt = OAuthBlob.ms(oauth["expiresAt"])
        self.refreshTokenExpiresAt = OAuthBlob.ms(oauth["refreshTokenExpiresAt"])
        self.subscriptionType = oauth["subscriptionType"] as? String
    }

    private static func ms(_ v: Any?) -> Date? {
        if let n = v as? Double, n > 0 { return Date(timeIntervalSince1970: n / 1000) }
        if let n = v as? Int, n > 0 { return Date(timeIntervalSince1970: Double(n) / 1000) }
        return nil
    }

    public func isExpired(at now: Date) -> Bool {
        guard let e = expiresAt else { return false }
        return e <= now
    }
}

/// Why a Keychain item cannot be switched to or measured with.
public enum CredentialProblem: Equatable {
    case missing
    case unreadable(String)
    case notOAuth
    case incomplete
    /// Anthropic answered 401 for an access token that has not expired: revoked or superseded by a newer login.
    case rejected(Int)
    /// The token works but belongs to another account than the snapshot's name says.
    case wrongOwner(String)

    /// For the menu (Vietnamese, like the rest of the UI).
    public var text: String {
        switch self {
        case .missing: return "không có token trong Keychain"
        case .unreadable(let why): return "không đọc được Keychain (\(why))"
        case .notOAuth: return "Keychain item không phải token OAuth"
        case .incomplete: return "token trong Keychain thiếu access/refresh token"
        case .rejected(let code): return "token bị Anthropic từ chối (HTTP \(code))"
        case .wrongOwner(let who): return "snapshot đang giữ token của \(who)"
        }
    }

    /// For CLI errors: completes "saved credentials for 'x' ...".
    public var detail: String {
        switch self {
        case .missing: return "are missing from the Keychain"
        case .unreadable(let why): return "cannot be read from the Keychain (\(why))"
        case .notOAuth: return "are not a Claude Code OAuth blob"
        case .incomplete: return "are incomplete (no access or refresh token)"
        case .rejected(let code): return "were rejected by Anthropic (HTTP \(code))"
        case .wrongOwner(let who): return "hold the token of \(who)"
        }
    }
}

/// All Keychain access goes through `/usr/bin/security`, exactly like Claude Code and `claude-account` do,
/// so the item ACLs already trust the caller and no permission dialog appears.
public enum Keychain {
    public static let storePrefix = "Claude Code-credentials-acct-"

    public static var liveService: String {
        let env = ProcessInfo.processInfo.environment["CLAUDE_ACCOUNT_LIVE_SERVICE"] ?? ""
        return env.isEmpty ? "Claude Code-credentials" : env
    }

    public static func savedService(_ name: String) -> String { storePrefix + name }

    /// Only a complete blob: callers treat nil as "nothing usable here".
    public static func read(service: String) async -> OAuthBlob? {
        let r = await inspect(service: service)
        return r.problem == nil ? r.blob : nil
    }

    /// The blob plus, when it cannot be used, why - for the menu, `doctor` and error messages.
    public static func inspect(service: String) async -> (blob: OAuthBlob?, problem: CredentialProblem?) {
        let r: ShellResult
        do {
            r = try await Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"], timeout: 20)
        } catch {
            return (nil, .unreadable(error.localizedDescription))
        }
        guard r.ok else { return (nil, r.status == itemNotFound ? .missing : .unreadable("security exit \(r.status)")) }
        guard let blob = OAuthBlob(raw: r.trimmedOut) else { return (nil, .notOAuth) }
        return (blob, blob.isComplete ? nil : .incomplete)
    }

    /// `security` exit status for errSecItemNotFound.
    static let itemNotFound: Int32 = 44

    public static func readLive() async -> OAuthBlob? { await read(service: liveService) }
    public static func readSaved(_ name: String) async -> OAuthBlob? { await read(service: savedService(name)) }

    /// Copies a blob into a Keychain item (create or update). Used only by the drift repair.
    public static func write(service: String, raw: String) async throws {
        let r = try await Shell.run("/usr/bin/security",
                                    ["add-generic-password", "-U", "-a", NSUserName(), "-s", service, "-w", raw], timeout: 20)
        guard r.ok else { throw ShellError("security add-generic-password failed: \(r.trimmedErr)") }
    }

    public static func delete(service: String) async {
        _ = try? await Shell.run("/usr/bin/security", ["delete-generic-password", "-s", service], timeout: 20)
    }

    /// Every `Claude Code-credentials*` service in the login keychain (metadata only, no secrets).
    public static func listClaudeServices() async -> Set<String> {
        guard let r = try? await Shell.run("/usr/bin/security", ["dump-keychain"], timeout: 60), r.ok else { return [] }
        return parseServices(r.stdout)
    }

    /// Lines look like `    "svce"<blob>="Claude Code-credentials-acct-m04"`.
    public static func parseServices(_ dump: String) -> Set<String> {
        var out = Set<String>()
        for line in dump.split(separator: "\n") where line.contains("\"svce\"<blob>=\"Claude Code-credentials") {
            guard let start = line.range(of: "<blob>=\"") else { continue }
            var rest = line[start.upperBound...]
            if let end = rest.lastIndex(of: "\"") { rest = rest[..<end] }
            out.insert(String(rest))
        }
        return out
    }

    public static func exists(service: String) async -> Bool {
        guard let r = try? await Shell.run("/usr/bin/security", ["find-generic-password", "-s", service], timeout: 20) else { return false }
        return r.ok
    }
}
