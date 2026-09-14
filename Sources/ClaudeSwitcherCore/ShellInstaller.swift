import Foundation

/// Puts `claude-switcher` on PATH and wraps `claude` in the `claude-as` loop. The rc block uses the same
/// markers as the claude-account plugin, so at most one block exists and either tool's installer replaces it.
public enum ShellInstaller {
    public static let markBegin = "# >>> claude-account >>>"
    public static let markEnd = "# <<< claude-account <<<"

    public enum ShimStatus: Equatable { case missing, current, stale }
    public enum RCStatus: Equatable { case missing, ours, plugin }

    // MARK: shim

    public static func shimText(appBinary: String) -> String {
        """
        #!/bin/sh
        # claude-switcher shim, written by Claude Switcher.app (rewritten on launch when the app moves).
        APP=\(shellQuote(appBinary))
        if [ ! -x "$APP" ]; then
          [ "${1:-}" = hook ] && exit 0
          echo "claude-switcher: Claude Switcher.app not found at $APP" >&2
          exit 1
        fi
        exec "$APP" "$@"

        """
    }

    public static func shimStatus(appBinary: String) -> ShimStatus {
        guard let s = try? String(contentsOf: Paths.shim, encoding: .utf8) else { return .missing }
        return s == shimText(appBinary: appBinary) ? .current : .stale
    }

    public static func installShim(appBinary: String) throws {
        try FileManager.default.createDirectory(at: Paths.localBin, withIntermediateDirectories: true)
        try shimText(appBinary: appBinary).write(to: Paths.shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.shim.path)
    }

    public static func removeShim() { try? FileManager.default.removeItem(at: Paths.shim) }

    // MARK: rc block

    public static func rcFile() -> URL {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return Paths.home.appendingPathComponent(shell.hasSuffix("/bash") ? ".bashrc" : ".zshrc")
    }

    public static func rcBlock() -> String {
        #"""
        # >>> claude-account >>>
        # claude-as [account] [claude args...]   (written by Claude Switcher.app; `claude` is aliased to it)
        #   Starts claude, optionally after switching to <account>. When Claude Switcher moves this session to
        #   another account, its Stop hook ends the process at the end of a turn; this loop then switches the
        #   login and resumes the same conversation with `claude --continue`.
        claude-as() {
          local dir="${CLAUDE_ACCOUNT_DIR:-$HOME/.claude/accounts}" cs="$HOME/.local/bin/claude-switcher" sw id next rc
          sw="$dir/.switcher"
          if [ -n "${1:-}" ] && [ -f "$dir/$1.json" ]; then
            "$cs" use "$1" || return $?
            shift
          fi
          case " $* " in
            *" -p "*|*" --print "*) CLAUDE_AS_LOOP=1 command claude "$@"; return $? ;;
          esac
          while :; do
            id="$$-$RANDOM$RANDOM"
            CLAUDE_AS_LOOP=1 CLAUDE_AS_ID="$id" command claude "$@"
            rc=$?
            if [ -s "$sw/hop-$id" ]; then
              next=$(cat "$sw/hop-$id"); rm -f "$sw/hop-$id"
            elif [ -s "$dir/.hop" ]; then
              next=$(cat "$dir/.hop"); rm -f "$dir/.hop"
            else
              return $rc
            fi
            "$cs" use "$next" || return $?
            printf 'claude-as: resuming as %s\n' "$next"
            set -- --continue
          done
        }
        alias claude='claude-as'
        # <<< claude-account <<<
        """#
    }

    public static func rcStatus(rc: URL) -> RCStatus {
        guard let s = try? String(contentsOf: rc, encoding: .utf8), let block = existingBlock(in: s) else { return .missing }
        return block.contains("claude-switcher") ? .ours : .plugin
    }

    public static func existingBlock(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let b = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == markBegin }),
              let e = lines[b...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == markEnd }) else { return nil }
        return lines[b...e].joined(separator: "\n")
    }

    /// Replaces the marked block (or appends one); `nil` removes it.
    public static func replaceBlock(in text: String, with block: String?) -> String {
        var lines = text.components(separatedBy: "\n")
        if let b = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == markBegin }),
           let e = lines[b...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == markEnd }) {
            var start = b
            if block == nil, start > 0, lines[start - 1].isEmpty { start -= 1 }
            lines.removeSubrange(start...e)
            if let block {
                lines.insert(contentsOf: block.components(separatedBy: "\n"), at: start)
            }
            return lines.joined(separator: "\n")
        }
        guard let block else { return text }
        var out = text
        if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        return out + "\n" + block + "\n"
    }

    public static func installRC(rc: URL) throws {
        let existing = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
        if FileManager.default.fileExists(atPath: rc.path) {
            let backup = rc.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))")
            try FileManager.default.copyItem(at: rc, to: backup)
        }
        try replaceBlock(in: existing, with: rcBlock()).write(to: rc, atomically: true, encoding: .utf8)
    }

    /// Removes the block only when it is ours; the plugin's block is left for the plugin.
    public static func removeRC(rc: URL) throws {
        guard rcStatus(rc: rc) == .ours, let existing = try? String(contentsOf: rc, encoding: .utf8) else { return }
        try replaceBlock(in: existing, with: nil).write(to: rc, atomically: true, encoding: .utf8)
    }

    public static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
