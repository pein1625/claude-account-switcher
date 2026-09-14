import Foundation

/// File-level access to the shared account store. Read side covers the CLI's files; write side is limited to
/// what the CLI also writes (`<name>.quota`, `.hop`) plus the app's own `.switcher/` files.
public final class AccountStore {
    public init() {}

    private var claudeJSONMtime: Date?
    private var cachedLive: OAuthAccount?

    // MARK: profiles

    public func loadProfiles() -> [AccountProfile] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Paths.accountsDir.path) else { return [] }
        let dec = JSONDecoder()
        return names
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".credentials.json") && !$0.hasPrefix(".") }
            .compactMap { file -> AccountProfile? in
                let url = Paths.accountsDir.appendingPathComponent(file)
                guard let data = try? Data(contentsOf: url), let p = try? dec.decode(AccountProfile.self, from: data) else { return nil }
                return p
            }
            .sorted { $0.name < $1.name }
    }

    public func accountsDirMtime() -> Date? { mtime(Paths.accountsDir) }

    public func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// `oauthAccount` from `~/.claude.json`; the file is large, so it is re-parsed only when its mtime moves.
    public func liveOAuthAccount() -> OAuthAccount? {
        let m = mtime(Paths.claudeJSON)
        if m == claudeJSONMtime, cachedLive != nil { return cachedLive }
        claudeJSONMtime = m
        guard let data = try? Data(contentsOf: Paths.claudeJSON),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acct = root["oauthAccount"] as? [String: Any],
              let acctData = try? JSONSerialization.data(withJSONObject: acct),
              let parsed = try? JSONDecoder().decode(OAuthAccount.self, from: acctData) else {
            cachedLive = nil
            return nil
        }
        cachedLive = parsed
        return parsed
    }

    /// The full `oauthAccount` object, untyped, for writing profiles / patching the config byte-for-byte in content.
    public func liveOAuthAccountRaw() -> [String: Any]? { oauthAccountRaw(in: Paths.claudeJSON) }

    public func oauthAccountRaw(in url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["oauthAccount"] as? [String: Any]
    }

    public func profileRaw(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: Paths.profileFile(name)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public func profileExists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: Paths.profileFile(name).path) }

    /// `<name>.json` in the CLI's shape: `{name, saved_at, subscriptionType, oauthAccount}`.
    public func writeProfile(name: String, oauthAccount: [String: Any], subscriptionType: String?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.accountsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let obj: [String: Any] = ["name": name, "saved_at": ISO8601.string(Date()),
                                  "subscriptionType": subscriptionType ?? "?", "oauthAccount": oauthAccount]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: Paths.profileFile(name), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.profileFile(name).path)
    }

    public func removeProfileFiles(_ name: String) {
        try? FileManager.default.removeItem(at: Paths.profileFile(name))
        try? FileManager.default.removeItem(at: Paths.quotaFile(name))
    }

    public func moveQuota(_ old: String, to new: String) {
        try? FileManager.default.moveItem(at: Paths.quotaFile(old), to: Paths.quotaFile(new))
    }

    /// Replaces `.oauthAccount` in `~/.claude.json`, everything else untouched; atomic write, mode 600.
    public func patchClaudeJSON(oauthAccount: [String: Any]) throws {
        let url = Paths.claudeJSON
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ShellError("\(url.path) is not a JSON object")
        }
        root["oauthAccount"] = oauthAccount
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".claude.json.switcher-\(ProcessInfo.processInfo.processIdentifier)")
        try out.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        claudeJSONMtime = nil
    }

    public func setCurrentMarker(name: String, uuid: String) { writePrivate(Paths.currentMarker, "\(name)\t\(uuid)\n") }
    public func removeCurrentMarker() { try? FileManager.default.removeItem(at: Paths.currentMarker) }

    public func liveName(profiles: [AccountProfile], live: OAuthAccount?) -> String? {
        guard let uuid = live?.accountUuid else { return nil }
        return profiles.first { $0.uuid == uuid }?.name
    }

    public struct CurrentMarker: Equatable {
        public var name: String
        public var uuid: String
        public var mtime: Date?
    }

    public func currentMarker() -> CurrentMarker? {
        guard let s = try? String(contentsOf: Paths.currentMarker, encoding: .utf8) else { return nil }
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", omittingEmptySubsequences: false)
        guard let name = parts.first, !name.isEmpty else { return nil }
        return CurrentMarker(name: String(name), uuid: parts.count > 1 ? String(parts[1]) : "", mtime: mtime(Paths.currentMarker))
    }

    // MARK: quota records (CLI format)

    public func quotaRecord(_ name: String) -> QuotaRecord? {
        guard let s = try? String(contentsOf: Paths.quotaFile(name), encoding: .utf8) else { return nil }
        return QuotaRecord(line: s)
    }

    public func writeQuotaRecord(_ name: String, _ rec: QuotaRecord, now: Date = Date()) {
        writePrivate(Paths.quotaFile(name), rec.line(now: now))
    }

    // MARK: hop file (CLI format: name + newline)

    public func readHop() -> String? {
        guard let s = try? String(contentsOf: Paths.hopFile, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    public func writeHop(_ name: String) { writePrivate(Paths.hopFile, name + "\n") }
    public func removeHop() { try? FileManager.default.removeItem(at: Paths.hopFile) }

    /// Per-loop relaunch target for this app's `claude-as` (`.switcher/hop-<CLAUDE_AS_ID>`).
    public func writeHopMarker(id: String, _ name: String) { Paths.ensureSwitcherDir(); writePrivate(Paths.hopMarker(id), name + "\n") }

    public func hopMarkers() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: Paths.switcherDir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("hop-") } ?? []
    }

    /// The hook and the CLI check this before waiting on the app.
    public func appAlive(now: Date = Date(), maxAge: TimeInterval = 120) -> Bool {
        guard let m = mtime(Paths.aliveFile) else { return false }
        return now.timeIntervalSince(m) < maxAge
    }

    public func appendEvent(_ e: RateLimitEvent) {
        Paths.ensureSwitcherDir()
        append(Paths.eventsLog, "\(Int(e.at.timeIntervalSince1970))\trate_limit\t\(e.pid)\n")
    }

    public func appendRestartLog(_ line: String) {
        Paths.ensureSwitcherDir()
        append(Paths.restartsLog, line + "\n")
    }

    // MARK: app-owned files

    public func touchAlive(pid: Int32 = ProcessInfo.processInfo.processIdentifier, now: Date = Date()) {
        Paths.ensureSwitcherDir()
        writePrivate(Paths.aliveFile, "\(pid)\t\(ISO8601.string(now))\n")
    }

    public func readSwitches() -> [SwitchEvent] {
        guard let s = try? String(contentsOf: Paths.switchesLog, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard p.count >= 4, let ts = TimeInterval(p[0]) else { return nil }
            return SwitchEvent(at: Date(timeIntervalSince1970: ts), from: p[1].isEmpty ? nil : String(p[1]),
                               to: String(p[2]), by: String(p[3]))
        }.sorted { $0.at < $1.at }
    }

    public func appendSwitch(_ e: SwitchEvent) {
        Paths.ensureSwitcherDir()
        let line = "\(Int(e.at.timeIntervalSince1970))\t\(e.from ?? "")\t\(e.to)\t\(e.by)\n"
        append(Paths.switchesLog, line)
    }

    public func readUsageCache() -> [String: AccountUsage] {
        guard let data = try? Data(contentsOf: Paths.usageCache) else { return [:] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: AccountUsage].self, from: data)) ?? [:]
    }

    public func writeUsageCache(_ cache: [String: AccountUsage]) {
        Paths.ensureSwitcherDir()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(cache) { writePrivate(Paths.usageCache, String(decoding: data, as: UTF8.self)) }
    }

    public func readRestartPlan() -> RestartPlan? {
        guard let data = try? Data(contentsOf: Paths.restartPlan) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(RestartPlan.self, from: data)
    }

    public func writeRestartPlan(_ plan: RestartPlan?) {
        guard let plan, !plan.pids.isEmpty else {
            try? FileManager.default.removeItem(at: Paths.restartPlan)
            return
        }
        Paths.ensureSwitcherDir()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(plan) else { return }
        // atomic: the hook may read while we write
        let tmp = Paths.restartPlan.appendingPathExtension("tmp")
        try? data.write(to: tmp, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try? FileManager.default.replaceItemAt(Paths.restartPlan, withItemAt: tmp)
    }

    /// New `rate_limit` events appended by the hook since `offset` bytes; returns the new offset.
    public func readEvents(from offset: UInt64) -> (events: [RateLimitEvent], offset: UInt64) {
        guard let fh = try? FileHandle(forReadingFrom: Paths.eventsLog) else { return ([], offset) }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = offset > size ? 0 : offset
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return ([], size) }
        let text = String(decoding: data, as: UTF8.self)
        var events: [RateLimitEvent] = []
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "\t")
            guard p.count >= 3, let ts = TimeInterval(p[0]), p[1] == "rate_limit", let pid = Int32(p[2]) else { continue }
            events.append(RateLimitEvent(at: Date(timeIntervalSince1970: ts), pid: pid))
        }
        return (events, size)
    }

    public func log(_ msg: String) {
        Paths.ensureSwitcherDir()
        let line = "\(ISO8601.string(Date()))  \(msg)\n"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.appLog.path),
           let size = attrs[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: Paths.appLog)
        }
        append(Paths.appLog, line)
    }

    // MARK: helpers

    private func writePrivate(_ url: URL, _ text: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func append(_ url: URL, _ text: String) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: Data(text.utf8))
    }
}
