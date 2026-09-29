import Foundation

public struct SwitcherError: LocalizedError {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// The account store operations, natively. Same Keychain service names, same files and the same rules as the
/// `claude-account` CLI, so a machine may run both. Every mutation runs under one lock: several `claude-as`
/// loops relaunching at the same moment would otherwise re-snapshot the wrong blob into the wrong account.
/// Whose token a blob is, according to Anthropic's profile endpoint.
public enum TokenOwner: Equatable {
    case confirmed(uuid: String, email: String?)
    /// 401 on an access token that has not expired.
    case rejected(Int)
    /// Offline, endpoint trouble, an expired access token (asking would need a refresh), or verification disabled.
    case unknown
}

/// Where the live Keychain blob gets copied to.
public enum SnapshotDecision: Equatable {
    case save(String)
    case skip(String)
}

public struct Switcher {
    public let store: AccountStore
    public let client: UsageClient

    /// Owner checks run while the lock is held, and other `claude-as` loops wait at most 30s for it: two checks
    /// per `use` must fit well inside that.
    public init(store: AccountStore = AccountStore(), client: UsageClient? = nil) {
        self.store = store
        if let client { self.client = client } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 6
            cfg.timeoutIntervalForResource = 8
            self.client = UsageClient(session: URLSession(configuration: cfg))
        }
    }

    /// `CLAUDE_SWITCHER_NO_VERIFY=1`: never call the profile endpoint (offline scripts, smoke runs).
    static var verifyDisabled: Bool { ProcessInfo.processInfo.environment["CLAUDE_SWITCHER_NO_VERIFY"] == "1" }

    public func tokenOwner(_ blob: OAuthBlob, now: Date = Date()) async -> TokenOwner {
        guard !Switcher.verifyDisabled, !blob.accessToken.isEmpty, !blob.isExpired(at: now),
              let p = await client.fetchProfile(token: blob.accessToken) else { return .unknown }
        if (200..<300).contains(p.status), let uuid = p.uuid { return .confirmed(uuid: uuid, email: p.email) }
        // 403 can be a token without the user:profile scope, which says nothing about whose it is
        if p.status == 401 { return .rejected(p.status) }
        return .unknown
    }

    /// A running session of any account writes its refreshed token into the live item, so `~/.claude.json` alone
    /// does not say whose token sits there - the profile endpoint does. The freshest token of an account belongs
    /// in that account's snapshot; a rejected one belongs nowhere. `trustConfig`: when the owner cannot be asked,
    /// fall back to the account `~/.claude.json` names (what every version before 0.5 did).
    public static func snapshotDecision(configName: String?, owner: TokenOwner, profiles: [AccountProfile], trustConfig: Bool) -> SnapshotDecision {
        switch owner {
        case .confirmed(let uuid, let email):
            if let configName, profiles.first(where: { $0.name == configName })?.uuid == uuid { return .save(configName) }
            if let p = profiles.first(where: { $0.uuid == uuid }) { return .save(p.name) }
            return .skip("live token belongs to an account that is not saved (\(email ?? uuid))")
        case .rejected(let code):
            return .skip("live token rejected by Anthropic (HTTP \(code))")
        case .unknown:
            guard trustConfig, let configName else { return .skip("owner of the live token not verified") }
            return .save(configName)
        }
    }

    /// Why a saved snapshot must not be put live, judged by its owner; nil = fine or cannot tell.
    public static func targetProblem(owner: TokenOwner, expectedUuid: String?, profiles: [AccountProfile]) -> CredentialProblem? {
        switch owner {
        case .confirmed(let uuid, let email):
            guard let expectedUuid, uuid != expectedUuid else { return nil }
            return .wrongOwner(profiles.first { $0.uuid == uuid }.map { "'\($0.name)'" } ?? email ?? uuid)
        case .rejected(let code): return .rejected(code)
        case .unknown: return nil
        }
    }

    /// Copies the live blob into the snapshot of the account it belongs to (Keychain item only: the profile file
    /// describes the account, not the token). Caller holds the lock.
    func snapshotLiveUnlocked(configName: String?, trustConfig: Bool) async throws -> (SnapshotDecision, TokenOwner, wrote: Bool) {
        guard let live = await Keychain.readLive() else {
            return (.skip("live Keychain item missing or incomplete"), .unknown, false)
        }
        let owner = await tokenOwner(live)
        let d = Switcher.snapshotDecision(configName: configName, owner: owner, profiles: store.loadProfiles(), trustConfig: trustConfig)
        guard case .save(let name) = d else { return (d, owner, false) }
        if await Keychain.readSaved(name)?.raw == live.raw { return (d, owner, false) }
        try await Keychain.write(service: Keychain.savedService(name), raw: live.raw)
        return (d, owner, true)
    }

    public struct LiveSync: Equatable {
        public var decision: SnapshotDecision
        public var owner: TokenOwner
        public var wrote: Bool
        /// Account uuid `~/.claude.json` names; differs from a confirmed owner when the Keychain drifted.
        public var configUuid: String?
    }

    /// The app's periodic pass: keep the live account's snapshot as fresh as the live item (a snapshot left
    /// behind a rotated refresh token dies), and report whose token is live. Writes only a verified owner.
    public func syncLiveSnapshot() async throws -> LiveSync {
        try await withLock {
            let cfg = store.liveOAuthAccount()
            let (d, owner, wrote) = try await snapshotLiveUnlocked(configName: currentName(), trustConfig: false)
            return LiveSync(decision: d, owner: owner, wrote: wrote, configUuid: cfg?.accountUuid)
        }
    }

    public static func isValidName(_ n: String) -> Bool {
        !n.isEmpty && n.range(of: "^[A-Za-z0-9._@-]+$", options: .regularExpression) != nil
    }

    /// `miracle04@x.com` -> `miracle04`; invalid characters become `-`; `-2`, `-3`... on collision.
    public static func suggestName(email: String?, taken: [String]) -> String {
        var base = (email ?? "account").split(separator: "@", omittingEmptySubsequences: false).first.map(String.init) ?? "account"
        base = String(base.lowercased().map { "abcdefghijklmnopqrstuvwxyz0123456789._-".contains($0) ? $0 : "-" })
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        if base.isEmpty { base = "account" }
        var name = base
        var n = 2
        while taken.contains(name) { name = "\(base)-\(n)"; n += 1 }
        return name
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
        let (live, problem) = await Keychain.inspect(service: Keychain.liveService)
        guard let blob = live, problem == nil else {
            throw SwitcherError("the live store holds no usable OAuth credentials (\(problem.map { "they \($0.detail)" } ?? "unusable")) - API-key logins cannot be snapshotted")
        }
        let email = profile["emailAddress"] as? String ?? "unknown"
        let uuid = profile["accountUuid"] as? String ?? ""
        let name = (requested?.isEmpty == false) ? requested! : email
        try Switcher.validate(name)
        switch await tokenOwner(blob) {
        case .confirmed(let tokenUuid, let tokenEmail) where tokenUuid != uuid:
            let owner = store.loadProfiles().first { $0.uuid == tokenUuid }.map { "'\($0.name)'" } ?? tokenEmail ?? tokenUuid
            throw SwitcherError("the live Keychain token belongs to \(owner), not to \(email) that \(Paths.claudeJSON.path) names; saving would file it under the wrong account. Log in again (/login) or fix the drift in the app first")
        case .rejected(let code):
            throw SwitcherError("the live token was rejected by Anthropic (HTTP \(code)) - log in again (/login) before saving")
        default: break
        }
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

    /// Files the live token under the account it really belongs to (its refresh token rotates while live), then
    /// writes the target's tokens and profile into the live locations. Nothing is logged out, so no token is
    /// revoked. A target that is already live needs no snapshot at all - the `claude-as` loops of a restart plan
    /// all call `use <live account>`.
    public func use(_ name: String, force: Bool = false) async throws -> String {
        try Switcher.validate(name)
        return try await withLock {
            let profiles = store.loadProfiles()
            guard let target = profiles.first(where: { $0.name == name }) else {
                throw SwitcherError("no saved account '\(name)' - see `claude-switcher list`")
            }
            guard let targetProfile = store.profileRaw(name)?["oauthAccount"] as? [String: Any] else {
                throw SwitcherError("profile file for '\(name)' is unreadable")
            }

            var note = ""
            if let cur = store.liveOAuthAccountRaw() {
                let curUuid = cur["accountUuid"] as? String ?? ""
                let curEmail = cur["emailAddress"] as? String ?? "unknown"
                let curName = profiles.first { $0.uuid == curUuid }?.name
                if curName == nil && !force {
                    throw SwitcherError("current login (\(curEmail)) was never saved and would be lost. Run `claude-switcher save <name>` first, or `use \(name) --force` to discard it.")
                }
                let (d, _, _) = try await snapshotLiveUnlocked(configName: curName, trustConfig: true)
                switch d {
                case .save(let owner) where owner == name && curName == name:
                    let sub = await Keychain.readLive()?.subscriptionType
                    try store.writeProfile(name: name, oauthAccount: cur, subscriptionType: sub ?? target.subscriptionType)
                    store.setCurrentMarker(name: name, uuid: curUuid)
                    return "Already on '\(name)' (\(curEmail)) - snapshot refreshed"
                case .save(let owner) where owner != curName:
                    note += "\nnote: the live token belonged to '\(owner)', not '\(curName ?? "?")' - saved it back to '\(owner)'"
                case .skip(let why) where curName != nil:
                    note += "\nnote: live login not snapshotted: \(why)"
                default: break
                }
            }

            let (read, problem) = await Keychain.inspect(service: Keychain.savedService(name))
            guard let targetBlob = read, problem == nil else {
                throw SwitcherError("saved credentials for '\(name)' \(problem?.detail ?? "are unusable") - log in again: claude-switcher relogin \(name)")
            }
            if let bad = Switcher.targetProblem(owner: await tokenOwner(targetBlob), expectedUuid: target.uuid, profiles: profiles) {
                throw SwitcherError("saved credentials for '\(name)' \(bad.detail) - log in again: claude-switcher relogin \(name)")
            }
            if let exp = targetBlob.refreshTokenExpiresAt, exp < Date() {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                note += "\nwarning: refresh token for '\(name)' expired on \(f.string(from: exp)). If Claude asks you to log in, run `claude-switcher relogin \(name)`."
            }
            store.removeHop()
            try await Keychain.write(service: Keychain.liveService, raw: targetBlob.raw)
            try store.patchClaudeJSON(oauthAccount: targetProfile)
            store.setCurrentMarker(name: name, uuid: target.uuid ?? "")
            return "Switched to '\(name)'  (\(target.email), \(target.org))" + note
        }
    }

    // MARK: drift repair

    /// The live token belongs to X while `~/.claude.json` names Y: file the token under X, then put Y's snapshot
    /// live - after checking that snapshot really is Y's. Judged on the state now, never on an earlier reading:
    /// repairing with a stale picture copied one account's token into the other's snapshot (0.4.0).
    public func realign() async throws -> String {
        try await withLock {
            let profiles = store.loadProfiles()
            guard let cfg = store.liveOAuthAccount(), let cfgUuid = cfg.accountUuid,
                  let cfgName = profiles.first(where: { $0.uuid == cfgUuid })?.name else {
                throw SwitcherError("the current login is not saved - nothing to realign to")
            }
            guard let live = await Keychain.readLive() else { throw SwitcherError("no usable token in the live Keychain item") }
            let owner = await tokenOwner(live)
            var saved = ""
            switch owner {
            case .confirmed(let uuid, _) where uuid == cfgUuid:
                return "No drift: the live token belongs to '\(cfgName)'"
            case .confirmed(let uuid, let email):
                if let ownerName = profiles.first(where: { $0.uuid == uuid })?.name {
                    try await Keychain.write(service: Keychain.savedService(ownerName), raw: live.raw)
                    saved = "live token saved back to '\(ownerName)', "
                } else {
                    saved = "live token of unsaved \(email ?? uuid) dropped, "
                }
            case .rejected(let code):
                saved = "rejected live token (HTTP \(code)) dropped, "
            case .unknown:
                throw SwitcherError("cannot verify whose token is live (offline, or its access token expired) - try again later")
            }
            let (read, problem) = await Keychain.inspect(service: Keychain.savedService(cfgName))
            guard let target = read, problem == nil else {
                throw SwitcherError("\(saved)but the snapshot of '\(cfgName)' \(problem?.detail ?? "is unusable") - log in again: claude-switcher relogin \(cfgName)")
            }
            if let bad = Switcher.targetProblem(owner: await tokenOwner(target), expectedUuid: cfgUuid, profiles: profiles) {
                throw SwitcherError("\(saved)but the snapshot of '\(cfgName)' \(bad.detail) - log in again: claude-switcher relogin \(cfgName)")
            }
            try await Keychain.write(service: Keychain.liveService, raw: target.raw)
            return "Realigned: \(saved)'\(cfgName)' restored to the live login"
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
            let (read, problem) = await Keychain.inspect(service: Keychain.savedService(old))
            guard let blob = read, problem == nil else {
                throw SwitcherError("saved credentials for '\(old)' \(problem?.detail ?? "are unusable")")
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

    public struct LoginContext: Codable {
        public let scratch: URL
        public let servicesBefore: Set<String>
        public let liveBeforeName: String?
        public let liveFingerprintBefore: String?
        /// Signing in again as an account that is already saved (its snapshot died); optional so a context
        /// written by 0.4 still decodes.
        public var relogin: Bool? = nil

        static let fileName = ".switcher-login.json"

        /// Persisted inside the scratch dir so `login-prepare` and `login-finish` can be separate processes
        /// (the Terminal script runs `claude auth login` itself in between).
        public func save() throws {
            let data = try JSONEncoder().encode(self)
            try data.write(to: scratch.appendingPathComponent(LoginContext.fileName), options: .atomic)
        }

        public static func load(scratch: URL) throws -> LoginContext {
            let data = try Data(contentsOf: scratch.appendingPathComponent(fileName))
            return try JSONDecoder().decode(LoginContext.self, from: data)
        }
    }

    /// Signing in happens inside a scratch `CLAUDE_CONFIG_DIR`, so the live login is not touched. The live token
    /// goes into its owner's snapshot first: if `claude` writes into the live store anyway, `finish` can put it
    /// back. `relogin`: `name` must already exist and the browser must sign in as that same account.
    public func loginPrepare(name: String, relogin: Bool = false) async throws -> LoginContext {
        try Switcher.validate(name)
        if relogin {
            guard store.profileExists(name) else { throw SwitcherError("no saved account '\(name)' - use `login \(name)` to add it") }
        } else {
            guard !store.profileExists(name) else { throw SwitcherError("'\(name)' already exists - `relogin \(name)` signs in again, or remove it / pick another name") }
        }
        guard Environment.which("claude") != nil else { throw SwitcherError("claude not found on PATH") }
        let scratch = Paths.home.appendingPathComponent(".claude-login.\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let before = await Keychain.listClaudeServices()
        let liveName = currentName()
        let fingerprint = await Keychain.readLive()?.fingerprint
        if liveName != nil { _ = try? await withLock { try await snapshotLiveUnlocked(configName: liveName, trustConfig: true) } }
        var ctx = LoginContext(scratch: scratch, servicesBefore: before, liveBeforeName: liveName, liveFingerprintBefore: fingerprint)
        ctx.relogin = relogin ? true : nil
        try ctx.save()
        return ctx
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

        // The browser approves whichever claude.ai session it already has: signing in "as another account"
        // silently yields the same account again. Refuse rather than store a duplicate under a new name - or,
        // for a relogin, rather than file another account's token under this name.
        let relogin = ctx.relogin == true
        let uuid = profile["accountUuid"] as? String
        let signedInAs = profile["emailAddress"] as? String ?? uuid ?? "?"
        if relogin, let expected = store.loadProfiles().first(where: { $0.name == name }), let uuid, expected.uuid != uuid {
            if let service, service != Keychain.liveService { await Keychain.delete(service: service) }
            throw SwitcherError("the browser signed in as \(signedInAs), not as '\(name)' (\(expected.email)). Log out of claude.ai in the browser (or use a private window) and retry `relogin \(name)`.")
        }
        if !relogin, let uuid, let dup = store.loadProfiles().first(where: { $0.uuid == uuid }) {
            if let service, service != Keychain.liveService { await Keychain.delete(service: service) }
            throw SwitcherError("the browser signed in as '\(dup.name)' (\(dup.email)) again - that account is already saved. Log out of claude.ai in the browser (or use a private window) and retry `login \(name)`.")
        }

        return try await withLock {
            try await Keychain.write(service: Keychain.savedService(name), raw: blob.raw)
            try store.writeProfile(name: name, oauthAccount: profile, subscriptionType: blob.subscriptionType)
            var note = ""
            // a relogin of the account that is live: its dead live token gets the new one too
            if relogin, service != Keychain.liveService, currentName() == name {
                try await Keychain.write(service: Keychain.liveService, raw: blob.raw)
                note = "\nthe live login ('\(name)') now uses the new tokens as well"
            }
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
            if relogin { return "Signed in again as '\(name)'  (\(email), \(org))." + note }
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
