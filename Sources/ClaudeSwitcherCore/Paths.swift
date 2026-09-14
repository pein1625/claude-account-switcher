import Foundation

/// Every path the app touches. Layout mirrors the `claude-account` CLI so both tools share one store:
/// `~/.claude/accounts/<name>.json` (profile), `<name>.quota`, `.current`, `.hop` are the CLI's;
/// everything under `~/.claude/accounts/.switcher/` belongs to this app.
public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser

    public static var accountsDir: URL {
        if let d = ProcessInfo.processInfo.environment["CLAUDE_ACCOUNT_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d)
        }
        return home.appendingPathComponent(".claude/accounts")
    }

    public static var claudeJSON: URL { home.appendingPathComponent(".claude.json") }
    public static var settingsJSON: URL { home.appendingPathComponent(".claude/settings.json") }
    public static var currentMarker: URL { accountsDir.appendingPathComponent(".current") }
    public static var hopFile: URL { accountsDir.appendingPathComponent(".hop") }

    public static var switcherDir: URL { accountsDir.appendingPathComponent(".switcher") }
    public static var aliveFile: URL { switcherDir.appendingPathComponent("alive") }
    public static var switchesLog: URL { switcherDir.appendingPathComponent("switches.log") }
    public static var usageCache: URL { switcherDir.appendingPathComponent("usage.json") }
    public static var restartPlan: URL { switcherDir.appendingPathComponent("restart.json") }
    public static var eventsLog: URL { switcherDir.appendingPathComponent("events.log") }
    public static var restartsLog: URL { switcherDir.appendingPathComponent("restarts.log") }
    public static var appLog: URL { switcherDir.appendingPathComponent("app.log") }

    public static var lockFile: URL { switcherDir.appendingPathComponent("lock") }
    public static func hopMarker(_ id: String) -> URL { switcherDir.appendingPathComponent("hop-\(id)") }

    public static var localBin: URL { home.appendingPathComponent(".local/bin") }
    /// `claude-switcher` on PATH: a two-line shim that execs the app binary (rewritten when the app moves).
    public static var shim: URL { localBin.appendingPathComponent("claude-switcher") }
    /// Bash hook shipped by 0.1.0; removed by uninstall, superseded by `claude-switcher hook`.
    public static var oldHookScript: URL { localBin.appendingPathComponent("claude-switcher-hook") }
    /// The team plugin's CLI, if installed. Same store, so both tools can be used side by side.
    public static var pluginCLI: URL { localBin.appendingPathComponent("claude-account") }

    public static func profileFile(_ name: String) -> URL { accountsDir.appendingPathComponent("\(name).json") }
    public static func quotaFile(_ name: String) -> URL { accountsDir.appendingPathComponent("\(name).quota") }

    public static func ensureSwitcherDir() {
        let fm = FileManager.default
        try? fm.createDirectory(at: switcherDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }
}
