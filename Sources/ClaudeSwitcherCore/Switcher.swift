import Foundation

public struct SwitcherError: LocalizedError {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// The account store operations, natively. Same Keychain service names, same files and the same rules as the
/// `claude-account` CLI, so a machine may run both. Every mutation runs under one lock: several `claude-as`
/// loops relaunching at the same moment would otherwise re-snapshot the wrong blob into the wrong account.
public struct Switcher {
    public let store: AccountStore

    public init(store: AccountStore = AccountStore()) { self.store = store }

    public static func isValidName(_ n: String) -> Bool {
        !n.isEmpty && n.range(of: "^[A-Za-z0-9._@-]+$", options: .regularExpression) != nil
    }

    static func validate(_ n: String) throws {
        guard isValidName(n) else { throw SwitcherError("invalid name '\(n)' (allowed: letters, digits, . _ @ -)") }
    }

    // MARK: lock

    public func withLock<T>(_ body: () async throws -> T) async throws -> T {
        Paths.ensureSwitcherDir()
        let fd = open(Paths.lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw SwitcherError("cannot open \(Paths.lockFile.path)") }
        defer { close(fd) }
        var waited: TimeInterval = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, waited < 30 else {
                throw SwitcherError("another switch is in progress (lock \(Paths.lockFile.path))")
            }
            try await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }

    // MARK: queries

    public func profiles() -> [AccountProfile] { store.loadProfiles() }

    public func currentName() -> String? {
        store.liveName(profiles: store.loadProfiles(), live: store.liveOAuthAccount())
    }

    public struct Current { public var name: String?; public var email: String; public var org: String }

    public func current() -> Current? {
        guard let live = store.liveOAuthAccount() else { return nil }
        return Current(name: currentName(), email: live.emailAddress ?? "?", org: live.organizationName ?? "-")
    }

    // MARK: save

    public func save(name requested: String? = nil) async throws -> String {
        try await withLock { try await saveUnlocked(name: requested) }
    }

    func saveUnlocked(name requested: String?) async throws -> String {
        guard let profile = store.liveOAuthAccountRaw() else {
            throw SwitcherError("no claude.ai login in \(Paths.claudeJSON.path) - run `claude auth login` first")
        }
        guard let blob = await Keychain.readLive(), blob.hasRefreshToken else {
            throw SwitcherError("no OAuth credentials in the live store - API-key logins cannot be snapshotted")
        }
        let email = profile["emailAddress"] as? String ?? "unknown"
        let uuid = profile["accountUuid"] as? String ?? ""
        let name = (requested?.isEmpty == false) ? requested! : email
        try Switcher.validate(name)
        var note = ""
        if let other = store.loadProfiles().first(where: { $0.uuid == uuid && $0.name != name }) {
            note = "\nwarning: this account is already saved as '\(other.name)'; saving again as '\(name)'"
        }
        try await Keychain.write(service: Keychain.savedService(name), raw: blob.raw)
        try store.writeProfile(name: name, oauthAccount: profile, subscriptionType: blob.subscriptionType)
        store.setCurrentMarker(name: name, uuid: uuid)
        return "Saved '\(name)'  (\(email), \(profile["organizationName"] as? String ?? "-"))" + note
    }

    // MARK: use

    /// Re-snapshots the account being left (its refresh token rotates while live), then writes the target's
    /// tokens and profile into the live locations. Nothing is logged out, so no token is revoked.
    public func use(_ name: String, force: Bool = false) async throws -> String {
        try Switcher.validate(name)
        return try await withLock {
            let profiles = store.loadProfiles()
            guard let target = profiles.first(where: { $0.name == name }) else {
                throw SwitcherError("no saved account '\(name)' - see `claude-switcher list`")
            }
            guard let targetBlob = await Keychain.readSaved(name), targetBlob.hasRefreshToken else {
                throw SwitcherError("saved credentials for '\(name)' are missing or unreadable - log in as that account and run `claude-switcher save \(name)`")
            }
            guard let targetProfile = store.profileRaw(name)?["oauthAccount"] as? [String: Any] else {
                throw SwitcherError("profile file for '\(name)' is unreadable")
            }

            if let cur = store.liveOAuthAccountRaw() {
                let curUuid = cur["accountUuid"] as? String ?? ""
                let curEmail = cur["emailAddress"] as? String ?? "unknown"
                let curName = profiles.first { $0.uuid == curUuid }?.name
                if curName == nil && !force {
                    throw SwitcherError("current login (\(curEmail)) was never saved and would be lost. Run `claude-switcher save <name>` first, or `use \(name) --force` to discard it.")
                }
                if curName == name {
                    _ = try await saveUnlocked(name: name)
                    return "Already on '\(name)' (\(curEmail)) - snapshot refreshed"
                }
                if let curName, let live = await Keychain.readLive(), live.hasRefreshToken {
                    _ = try await saveUnlocked(name: curName)
                }
            }

            var note = ""
            if let exp = targetBlob.refreshTokenExpiresAt, exp < Date() {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                note = "\nwarning: refresh token for '\(name)' expired on \(f.string(from: exp)). If Claude asks you to log in, do so and run `claude-switcher save \(name)`."
            }
            store.removeHop()
            try await Keychain.write(service: Keychain.liveService, raw: targetBlob.raw)
            try store.patchClaudeJSON(oauthAccount: targetProfile)
            store.setCurrentMarker(name: name, uuid: target.uuid ?? "")
            return "Switched to '\(name)'  (\(target.email), \(target.org))" + note
        }
    }

    // MARK: remove / rename

    public func remove(_ name: String) async throws -> String {
        try Switcher.validate(name)
        return try await withLock {
            guard store.profileExists(name) else { throw SwitcherError("no saved account '\(name)'") }
            await Keychain.delete(service: Keychain.savedService(name))
            store.removeProfileFiles(name)
            if store.currentMarker()?.name == name { store.removeCurrentMarker() }
            return "Removed '\(name)' (the live login is untouched)"
        }
    }

    public func rename(_ old: String, to new: String) async throws -> String {
        try Switcher.validate(old)
        try Switcher.validate(new)
        guard old != new else { throw SwitcherError("old and new name are the same") }
        return try await withLock {
            guard var profile = store.profileRaw(old), let oauth = profile["oauthAccount"] as? [String: Any] else {
                throw SwitcherError("no saved account '\(old)'")
            }
            guard !store.profileExists(new) else { throw SwitcherError("'\(new)' already exists - remove it first or pick another name") }
            guard let blob = await Keychain.readSaved(old), blob.hasRefreshToken else {
                throw SwitcherError("saved credentials for '\(old)' are missing or not an OAuth blob")
            }
            try await Keychain.write(service: Keychain.savedService(new), raw: blob.raw)
            profile["name"] = new
            try store.writeProfile(name: new, oauthAccount: oauth, subscriptionType: profile["subscriptionType"] as? String)
            await Keychain.delete(service: Keychain.savedService(old))
            try? FileManager.default.removeItem(at: Paths.profileFile(old))
            store.moveQuota(old, to: new)
            if let m = store.currentMarker(), m.name == old { store.setCurrentMarker(name: new, uuid: m.uuid) }
            return "Renamed '\(old)' -> '\(new)' (the live login is untouched)"
        }
    }

    // MARK: login (interactive; the caller runs `claude auth login` between prepare and finish)

    public struct LoginContext {
        public let scratch: URL
        public let servicesBefore: Set<String>
        public let liveBeforeName: String?
        public let liveFingerprintBefore: String?
    }

    /// Signing in happens inside a scratch `CLAUDE_CONFIG_DIR`, so the live login is not touched. The account
    /// that is live now gets a fresh snapshot first: if `claude` writes into the live store anyway, `finish`
    /// can put it back.
    public func loginPrepare(name: String) async throws -> LoginContext {
        try Switcher.validate(name)
        guard !store.profileExists(name) else { throw SwitcherError("'\(name)' already exists - remove it first or pick another name") }
        guard Environment.which("claude") != nil else { throw SwitcherError("claude not found on PATH") }
        let scratch = Paths.home.appendingPathComponent(".claude-login.\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let before = await Keychain.listClaudeServices()
        let liveName = currentName()
        var fingerprint: String?
        if let live = await Keychain.readLive() {
            fingerprint = live.fingerprint
            if let liveName, live.hasRefreshToken { _ = try await save(name: liveName) }
        }
        return LoginContext(scratch: scratch, servicesBefore: before, liveBeforeName: liveName, liveFingerprintBefore: fingerprint)
    }

    public func loginFinish(name: String, ctx: LoginContext) async throws -> String {
        defer { try? FileManager.default.removeItem(at: ctx.scratch) }
        guard let profile = store.oauthAccountRaw(in: ctx.scratch.appendingPathComponent(".claude.json")) else {
            throw SwitcherError("login finished but \(ctx.scratch.path)/.claude.json holds no oauthAccount")
        }
        let after = await Keychain.listClaudeServices()
        let fresh = after.subtracting(ctx.servicesBefore).filter { !$0.contains("-acct-") }
        var blob: OAuthBlob?
        var service: String?
        if fresh.count == 1, let s = fresh.first {
            service = s
            blob = await Keychain.read(service: s)
        } else if let live = await Keychain.readLive(), live.fingerprint != ctx.liveFingerprintBefore {
            service = Keychain.liveService
            blob = live
        } else {
            throw SwitcherError("cannot locate the new credentials in the Keychain (new entries: \(fresh.sorted().joined(separator: " ")))")
        }
        guard let blob, blob.hasRefreshToken else { throw SwitcherError("new credentials are not an OAuth blob (API-key login?)") }

        return try await withLock {
            try await Keychain.write(service: Keychain.savedService(name), raw: blob.raw)
            try store.writeProfile(name: name, oauthAccount: profile, subscriptionType: blob.subscriptionType)
            var note = ""
            if service == Keychain.liveService {
                if let prev = ctx.liveBeforeName, let prevBlob = await Keychain.readSaved(prev),
                   let prevProfile = store.profileRaw(prev)?["oauthAccount"] as? [String: Any] {
                    try await Keychain.write(service: Keychain.liveService, raw: prevBlob.raw)
                    try store.patchClaudeJSON(oauthAccount: prevProfile)
                    note = "\nwarning: claude wrote into the live store despite CLAUDE_CONFIG_DIR - restored the previous login (\(prev))"
                } else {
                    store.setCurrentMarker(name: name, uuid: profile["accountUuid"] as? String ?? "")
                    note = "\nwarning: claude wrote into the live store and the previous login was never saved - '\(name)' is live now"
                }
            } else if let service {
                await Keychain.delete(service: service)
            }
            let email = profile["emailAddress"] as? String ?? "?"
            let org = profile["organizationName"] as? String ?? "-"
            return "Saved '\(name)'  (\(email), \(org)). Live login unchanged. Switch with: claude-switcher use \(name)" + note
        }
    }

    // MARK: list

    public func listText(usage: [String: AccountUsage], now: Date = Date()) -> String {
        let profiles = store.loadProfiles()
        guard !profiles.isEmpty else { return "(none saved yet - run: claude-switcher save <name>)\n" }
        let live = currentName()
        var out = String(format: "%-1@ %-14@ %-32@ %-22@ %-8@ %-6@ %@\n", "", "NAME", "EMAIL", "ORG", "PLAN", "5H", "SAVED")
        for p in profiles {
            let state = AccountState(name: p.name, usage: usage[p.name], record: store.quotaRecord(p.name))
            let e = HopPolicy.effective(state, now: now, maxAge: 300)
            let q = e.source == .none ? "-" : "\(Int(e.fiveHour.rounded()))%"
            let saved = (p.saved_at ?? "-").split(separator: "T").first.map(String.init) ?? "-"
            out += String(format: "%-1@ %-14@ %-32@ %-22@ %-8@ %-6@ %@\n", p.name == live ? "*" : " ", p.name, p.email, p.org, p.plan, q, saved)
        }
        return out
    }
}
