import Foundation

/// Version check and in-place upgrade. The upgrade itself is `scripts/install.sh` - the same one-liner the
/// README hands out: it already knows where the dmg lives (GitHub Release, else the copy committed under
/// `releases/`), downloads it with curl so Gatekeeper never quarantines it, replaces a running app and
/// reopens it. The app only decides *whether* there is something newer.
public enum Updater {
    public static let repo = "pein1625/claude-account-switcher"
    public static var installScript: String { "https://raw.githubusercontent.com/\(repo)/main/scripts/install.sh" }
    private static var releaseAPI: URL { URL(string: "https://api.github.com/repos/\(repo)/releases/latest")! }
    private static var rawLatest: URL { URL(string: "https://raw.githubusercontent.com/\(repo)/main/releases/latest")! }

    public struct Release: Equatable {
        public var version: String
        public var pageURL: URL?
        public init(version: String, pageURL: URL? = nil) { self.version = version; self.pageURL = pageURL }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        return URLSession(configuration: cfg)
    }()

    /// `make release` publishes a GitHub Release, `make publish-file` only commits the dmg and bumps
    /// `releases/latest`; either can be the newer one, so both are read and the higher version wins.
    public static func latest() async -> Release? {
        async let a = fromReleaseAPI()
        async let b = fromRepoFile()
        switch await (a, b) {
        case let (api?, raw?): return isNewer(raw.version, than: api.version) ? raw : api
        case let (api?, nil): return api
        case let (nil, raw?): return raw
        case (nil, nil): return nil
        }
    }

    private static func fromReleaseAPI() async -> Release? {
        var req = URLRequest(url: releaseAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeSwitcher/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String else { return nil }
        let v = normalize(tag)
        guard !v.isEmpty else { return nil }
        return Release(version: v, pageURL: (root["html_url"] as? String).flatMap { URL(string: $0) })
    }

    private static func fromRepoFile() async -> Release? {
        var req = URLRequest(url: rawLatest)
        req.setValue("ClaudeSwitcher/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        let v = normalize(String(decoding: data, as: UTF8.self))
        guard !v.isEmpty, v.first?.isNumber == true else { return nil }
        return Release(version: v, pageURL: URL(string: "https://github.com/\(repo)/releases"))
    }

    public static func normalize(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("v") ? String(t.dropFirst()) : t
    }

    /// Numeric, component-wise; a missing component counts as 0, so "0.10" beats "0.9.9".
    public static func isNewer(_ v: String, than current: String) -> Bool {
        let a = parts(v), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parts(_ v: String) -> [Int] {
        normalize(v).split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
    }

    /// The command `startUpgrade` runs. Kept separate so `doctor` and the log can show exactly what ran.
    public static func upgradeCommand(dest: String, version: String?) -> String {
        var env = "DEST=\(quote(dest))"
        if let version, !version.isEmpty { env += " CLAUDE_SWITCHER_VERSION=\(quote(version))" }
        return "curl -fsSL \(quote(installScript)) | \(env) bash"
    }

    /// Starts the installer and returns without waiting: the script stops this very app before copying the new
    /// bundle, so nothing here survives to report the result - the log file is the record.
    @discardableResult
    public static func startUpgrade(dest: String, version: String?, log: URL) throws -> Int32 {
        Paths.ensureSwitcherDir()
        let cmd = "{ echo \"--- \(ISO8601.string(Date())) update \(AppInfo.version) -> \(version ?? "latest")\"; "
            + upgradeCommand(dest: dest, version: version)
            + "; echo \"--- exit $?\"; } >> \(quote(log.path)) 2>&1"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Environment.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw ShellError("cannot start the installer: \(error.localizedDescription)") }
        return p.processIdentifier
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
