import Foundation

/// Wires `claude-switcher hook` into `~/.claude/settings.json` as a `Stop` and `StopFailure(rate_limit)` hook.
/// The hook restarts only the pids the app listed in `.switcher/restart.json`, so sessions already on the new
/// account are never bounced (unlike a global flag). `jq` keeps the file's key order when present; otherwise
/// Foundation rewrites it (keys sorted) - a backup is kept either way.
public enum HookInstaller {
    public static let command = "\"$HOME/.local/bin/claude-switcher\" hook"
    static let tag = "claude-switcher"

    public static func wiredEvents() -> Set<String> {
        guard let root = readSettings(), let hooks = root["hooks"] as? [String: Any] else { return [] }
        var events = Set<String>()
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            if groups.contains(where: { g in
                ((g["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String) == command }
            }) { events.insert(event) }
        }
        return events
    }

    public static func isSettingsWired() -> Bool { wiredEvents().isSuperset(of: ["Stop", "StopFailure"]) }

    /// Any hook entry of ours, including the 0.1.0 bash hook.
    public static func isMentionedInSettings() -> Bool {
        guard let root = readSettings(), let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            ((value as? [[String: Any]]) ?? []).contains { g in
                ((g["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(tag) == true }
            }
        }
    }

    static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: Paths.settingsJSON) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func backupSettings() throws {
        let settings = Paths.settingsJSON
        let backup = settings.deletingLastPathComponent().appendingPathComponent("settings.json.bak-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.copyItem(at: settings, to: backup)
    }

    // MARK: pure transforms (Foundation path; the jq filters below do the same)

    static func strip(_ hooks: [String: Any]) -> [String: Any] {
        var out = hooks
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            out[event] = groups.filter { g in
                !((g["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(tag) == true }
            }
        }
        return out
    }

    public static func addHooks(_ root: [String: Any]) -> [String: Any] {
        var root = root
        var hooks = strip(root["hooks"] as? [String: Any] ?? [:])
        var stop = hooks["Stop"] as? [[String: Any]] ?? []
        stop.append(["hooks": [["type": "command", "command": command, "timeout": 10]]])
        hooks["Stop"] = stop
        var fail = hooks["StopFailure"] as? [[String: Any]] ?? []
        fail.append(["matcher": "rate_limit", "hooks": [["type": "command", "command": command, "timeout": 15]]])
        hooks["StopFailure"] = fail
        root["hooks"] = hooks
        return root
    }

    public static func removeHooks(_ root: [String: Any]) -> [String: Any] {
        var root = root
        if let hooks = root["hooks"] as? [String: Any] { root["hooks"] = strip(hooks) }
        return root
    }

    static let jqStrip = #"def strip: if type == "array" then map(select(any(.hooks[]?; (.command // "") | contains("claude-switcher")) | not)) else . end;"#
    static let jqAdd = jqStrip + """
     .hooks //= {} | .hooks |= with_entries(.value |= strip) |
     .hooks.Stop //= [] | .hooks.Stop += [{"hooks":[{"type":"command","command":$cmd,"timeout":10}]}] |
     .hooks.StopFailure //= [] | .hooks.StopFailure += [{"matcher":"rate_limit","hooks":[{"type":"command","command":$cmd,"timeout":15}]}]
    """
    static let jqRemove = jqStrip + " if .hooks then .hooks |= with_entries(.value |= strip) else . end"

    static func rewrite(jqFilter: String, transform: ([String: Any]) -> [String: Any]) async throws {
        let settings = Paths.settingsJSON
        if !FileManager.default.fileExists(atPath: settings.path) {
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "{}\n".write(to: settings, atomically: true, encoding: .utf8)
        }
        try backupSettings()
        if let jq = Environment.which("jq") {
            let r = try await Shell.run(jq, ["--arg", "cmd", command, jqFilter, settings.path], timeout: 20)
            guard r.ok, !r.stdout.isEmpty else { throw ShellError("jq failed: \(r.trimmedErr)") }
            try r.stdout.write(to: settings, atomically: true, encoding: .utf8)
        } else {
            guard let root = readSettings() else { throw ShellError("\(settings.path) is not a JSON object") }
            let data = try JSONSerialization.data(withJSONObject: transform(root), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (String(decoding: data, as: UTF8.self) + "\n").write(to: settings, atomically: true, encoding: .utf8)
        }
    }

    public static func wireSettings() async throws { try await rewrite(jqFilter: jqAdd, transform: addHooks) }

    public static func unwireSettings() async throws {
        guard FileManager.default.fileExists(atPath: Paths.settingsJSON.path), isMentionedInSettings() else { return }
        try await rewrite(jqFilter: jqRemove, transform: removeHooks)
    }
}
