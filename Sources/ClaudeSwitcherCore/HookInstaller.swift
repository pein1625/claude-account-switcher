import Foundation

/// The Stop / StopFailure hook the app installs into `~/.claude/settings.json`. Unlike the plugin's global
/// `accounts/.hop`, it restarts only the pids the app listed in `.switcher/restart.json`, so sessions already on
/// the new account are never bounced.
public enum HookScript {
    public static let text = #"""
    #!/usr/bin/env bash
    # claude-switcher-hook - Stop / StopFailure(rate_limit) hook installed by Claude Switcher.app.
    # Ends THIS claude process at its turn boundary when the app listed its pid in
    # ~/.claude/accounts/.switcher/restart.json; the `claude-as` loop around the process then reads
    # accounts/.hop and relaunches `claude --continue` as that account. Sessions not started through
    # `claude-as` are left alone (they could not come back). On a rate-limit failure the event is
    # reported first so the app can decide a hop before this hook looks at the plan.
    dir="${CLAUDE_ACCOUNT_DIR:-$HOME/.claude/accounts}"
    sw="$dir/.switcher"; plan="$sw/restart.json"; alive="$sw/alive"

    input=$(cat 2>/dev/null || true)
    if printf '%s' "$input" | jq -e '.agent_id // empty' >/dev/null 2>&1; then exit 0; fi
    event=$(printf '%s' "$input" | jq -r '.hook_event_name // "Stop"' 2>/dev/null || echo Stop)

    # The claude process this hook belongs to: CLAUDE_PID when it is an ancestor, else the nearest
    # ancestor whose executable is named claude (stricter than autohop-stop.sh: a shell whose command
    # line merely mentions a path containing "claude" must not be picked).
    chain=""; p=$PPID
    while [ "${p:-0}" -gt 1 ]; do
      chain="$chain $p"
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    done
    pid=""
    case " $chain " in *" ${CLAUDE_PID:-x} "*) pid="$CLAUDE_PID" ;; esac
    if [ -z "$pid" ]; then
      for p in $chain; do
        cmd=$(ps -o command= -p "$p" 2>/dev/null) || continue
        exe="${cmd%% *}"
        case "${exe##*/}" in
          claude) pid="$p"; break ;;
        esac
      done
    fi
    [ -n "$pid" ] || exit 0

    app_alive() {
      [ -f "$alive" ] || return 1
      [ $(( $(date +%s) - $(stat -f %m "$alive" 2>/dev/null || echo 0) )) -lt 120 ]
    }
    in_plan() { [ -s "$plan" ] && jq -e --arg p "$pid" '.pids[$p] // empty' "$plan" >/dev/null 2>&1; }

    if [ "$event" = StopFailure ]; then
      mkdir -p "$sw"
      printf '%s\t%s\t%s\n' "$(date +%s)" rate_limit "$pid" >> "$sw/events.log"
      if app_alive; then
        i=0
        while [ $i -lt 10 ] && ! in_plan; do sleep 0.5; i=$((i+1)); done
      fi
    fi

    in_plan || exit 0
    target=$(jq -r --arg p "$pid" '.pids[$p]' "$plan" 2>/dev/null)
    [ -n "$target" ] || exit 0
    [ "${CLAUDE_AS_LOOP:-}" = 1 ] || exit 0

    ( umask 077; printf '%s\n' "$target" > "$dir/.hop" )
    printf '%s\t%s\thop=%s\tpid=%s\n' "$(date +%FT%T)" "$event" "$target" "$pid" >> "$sw/restarts.log"
    [ -n "${CLAUDE_SWITCHER_DRY_RUN:-}" ] && exit 0
    kill -TERM "$pid"
    """#

    public static var normalized: String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.hasPrefix("    ") ? String(line.dropFirst(4)) : String(line) }
            .joined(separator: "\n") + "\n"
    }
}

public enum HookInstaller {
    public static let command = "bash \"$HOME/.local/bin/claude-switcher-hook\""

    public static func isScriptInstalled() -> Bool {
        guard let s = try? String(contentsOf: Paths.hookScript, encoding: .utf8) else { return false }
        return s == HookScript.normalized
    }

    /// Hook events in settings.json whose command mentions our script.
    public static func wiredEvents() -> Set<String> {
        guard let data = try? Data(contentsOf: Paths.settingsJSON),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return [] }
        var events = Set<String>()
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let hit = groups.contains { g in
                ((g["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains("claude-switcher-hook") == true }
            }
            if hit { events.insert(event) }
        }
        return events
    }

    public static func isSettingsWired() -> Bool { wiredEvents().isSuperset(of: ["Stop", "StopFailure"]) }
    public static func isMentionedInSettings() -> Bool { !wiredEvents().isEmpty }

    private static func backupSettings() throws {
        let settings = Paths.settingsJSON
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = settings.deletingLastPathComponent().appendingPathComponent("settings.json.bak-\(stamp)")
        try FileManager.default.copyItem(at: settings, to: backup)
    }

    public static func installScript() throws {
        try FileManager.default.createDirectory(at: Paths.localBin, withIntermediateDirectories: true)
        try HookScript.normalized.write(to: Paths.hookScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.hookScript.path)
    }

    /// Adds the hook to `Stop` and `StopFailure(rate_limit)` with `jq` (keeps key order); idempotent; keeps a backup.
    public static func wireSettings() async throws {
        guard let jq = Environment.which("jq") else { throw ShellError("jq not found on PATH") }
        let settings = Paths.settingsJSON
        if !FileManager.default.fileExists(atPath: settings.path) {
            try "{}\n".write(to: settings, atomically: true, encoding: .utf8)
        }
        try backupSettings()
        let filter = """
        .hooks //= {} |
        .hooks.Stop //= [] |
        (if any(.hooks.Stop[]?.hooks[]?; .command == $cmd) then . else
           .hooks.Stop += [{"hooks":[{"type":"command","command":$cmd,"timeout":10}]}] end) |
        .hooks.StopFailure //= [] |
        (if any(.hooks.StopFailure[]?.hooks[]?; .command == $cmd) then . else
           .hooks.StopFailure += [{"matcher":"rate_limit","hooks":[{"type":"command","command":$cmd,"timeout":15}]}] end)
        """
        let r = try await Shell.run(jq, ["--arg", "cmd", command, filter, settings.path], timeout: 20)
        guard r.ok, !r.stdout.isEmpty else { throw ShellError("jq failed: \(r.trimmedErr)") }
        try r.stdout.write(to: settings, atomically: true, encoding: .utf8)
    }

    public static func unwireSettings() async throws {
        guard let jq = Environment.which("jq") else { throw ShellError("jq not found on PATH") }
        let settings = Paths.settingsJSON
        guard FileManager.default.fileExists(atPath: settings.path), isMentionedInSettings() else { return }
        try backupSettings()
        // keep in sync with scripts/uninstall.sh
        let filter = """
        if .hooks then
          .hooks |= with_entries(.value |= (if type == "array" then map(select(any(.hooks[]?; (.command // "") | contains("claude-switcher-hook")) | not)) else . end))
        else . end
        """
        let r = try await Shell.run(jq, ["--arg", "cmd", command, filter, settings.path], timeout: 20)
        guard r.ok, !r.stdout.isEmpty else { throw ShellError("jq failed: \(r.trimmedErr)") }
        try r.stdout.write(to: settings, atomically: true, encoding: .utf8)
    }

    public static func install() async throws {
        try installScript()
        try await wireSettings()
    }

    public static func uninstall() async throws {
        try await unwireSettings()
        try? FileManager.default.removeItem(at: Paths.hookScript)
    }
}
