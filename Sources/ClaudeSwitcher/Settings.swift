import Foundation
import ClaudeSwitcherCore

/// User settings, stored in UserDefaults. Defaults match the CLI (`CLAUDE_ACCOUNT_HOP_AT` = 90).
struct AppSettings {
    static let defaults = UserDefaults.standard

    enum Key: String {
        case autoSwitch, hopAt, sevenDayAt, pollSeconds, notify, terminalApp, restartSessions, extraPath, cooldownMinutes,
             autoSaveLogin, loginPrivateWindow, loginViaTerminal, pollMigrated300
    }

    static func register() {
        defaults.register(defaults: [
            Key.autoSwitch.rawValue: true,
            Key.hopAt.rawValue: 90,
            Key.sevenDayAt.rawValue: 100,
            Key.pollSeconds.rawValue: 300,
            Key.notify.rawValue: true,
            Key.terminalApp.rawValue: "Terminal",
            Key.restartSessions.rawValue: true,
            Key.extraPath.rawValue: "",
            Key.cooldownMinutes.rawValue: 10,
            Key.autoSaveLogin.rawValue: true,
            Key.loginPrivateWindow.rawValue: true,
            Key.loginViaTerminal.rawValue: false,
        ])
        migratePollInterval()
        Environment.extraPath = defaults.string(forKey: Key.extraPath.rawValue) ?? ""
    }

    /// Up to 0.3.0 the app measured every 60s. Five minutes is enough: a rate-limit hook event still reacts at
    /// once, and the policy only needs a reading fresher than `pollSeconds * 3`. Runs once; a value the user
    /// picks after the migration stays.
    private static func migratePollInterval() {
        guard !defaults.bool(forKey: Key.pollMigrated300.rawValue) else { return }
        defaults.set(true, forKey: Key.pollMigrated300.rawValue)
        if defaults.object(forKey: Key.pollSeconds.rawValue) != nil,
           defaults.integer(forKey: Key.pollSeconds.rawValue) < 300 {
            defaults.set(300, forKey: Key.pollSeconds.rawValue)
        }
    }

    static var autoSwitch: Bool { defaults.bool(forKey: Key.autoSwitch.rawValue) }
    static var hopAt: Double { Double(defaults.integer(forKey: Key.hopAt.rawValue)) }
    static var sevenDayAt: Double { Double(defaults.integer(forKey: Key.sevenDayAt.rawValue)) }
    static var pollSeconds: Int { max(15, defaults.integer(forKey: Key.pollSeconds.rawValue)) }
    static var notify: Bool { defaults.bool(forKey: Key.notify.rawValue) }
    static var terminalApp: String { defaults.string(forKey: Key.terminalApp.rawValue) ?? "Terminal" }
    static var restartSessions: Bool { defaults.bool(forKey: Key.restartSessions.rawValue) }
    static var cooldown: TimeInterval { TimeInterval(defaults.integer(forKey: Key.cooldownMinutes.rawValue) * 60) }
    static var thresholds: Thresholds { Thresholds(hopAt: hopAt, sevenDayAt: sevenDayAt) }
    static var autoSaveLogin: Bool { defaults.bool(forKey: Key.autoSaveLogin.rawValue) }
    static var loginPrivateWindow: Bool { defaults.bool(forKey: Key.loginPrivateWindow.rawValue) }
    static var loginViaTerminal: Bool { defaults.bool(forKey: Key.loginViaTerminal.rawValue) }
}
