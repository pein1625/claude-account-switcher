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

    /// The app binary an installed shim execs, if any.
    public static func shimTarget() -> String? {
        guard let s = try? String(contentsOf: Paths.shim, encoding: .utf8),
              let line = s.split(separator: "\n").first(where: { $0.hasPrefix("APP=") }) else { return nil }
        let quoted = String(line.dropFirst(4))
        return quoted.hasPrefix("'") && quoted.hasSuffix("'") && quoted.count >= 2
            ? String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
            : quoted
    }

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
        #   login and resumes the same conversation (`claude --resume <its id>`, else `--continue`) with the launch
        #   options it was started with.
        # Launch options to carry onto `claude --resume`: everything except what picks the conversation (-c, -r,
        # --session-id, --fork-session, --from-pr, --teleport) and the opening prompt, which was already sent.
        # Values are consumed the way claude parses them: <x> takes one, [x] one unless it starts with -, <x...> until the next flag.
        _claude_as_keep() {
          local a mode="" drop=""
          _claude_as_kept=()
          for a in "$@"; do
            case "$mode" in
              one) mode=""; [ -z "$drop" ] && _claude_as_kept+=("$a"); continue ;;
              opt) mode=""; case "$a" in -*) ;; *) [ -z "$drop" ] && _claude_as_kept+=("$a"); continue ;; esac ;;
              many) case "$a" in -*) mode="" ;; *) _claude_as_kept+=("$a"); continue ;; esac ;;
            esac
            drop=""
            case "$a" in
              -c|--continue|--fork-session) ;;
              --resume=*|--session-id=*|--from-pr=*|--teleport=*) ;;
              -r|--resume|--from-pr|--teleport) drop=1; mode=opt ;;
              --session-id) drop=1; mode=one ;;
              --add-dir|--allowedTools|--allowed-tools|--betas|--disallowedTools|--disallowed-tools|--file|--mcp-config|--tools)
                _claude_as_kept+=("$a"); mode=many ;;
              --agent|--agents|--append-system-prompt|--append-system-prompt-file|--autocompact|--client-data-url|--debug-file|\
              --effort|--environment|--fallback-model|--input-format|--json-schema|--max-budget-usd|--model|-n|--name|\
              --output-format|--permission-mode|--permission-prompts|--permission-prompt-tool|--plugin-dir|--plugin-url|\
              --remote-control-session-name-prefix|--setting-sources|--settings|--system-prompt|--system-prompt-file|\
              --system-prompt-snapshot)
                _claude_as_kept+=("$a"); mode=one ;;
              -d|--debug|--cloud|--prompt-suggestions|--remote-control|-w|--worktree)
                _claude_as_kept+=("$a"); mode=opt ;;
              -*) _claude_as_kept+=("$a") ;;
            esac
          done
        }
        claude-as() {
          local dir="${CLAUDE_ACCOUNT_DIR:-$HOME/.claude/accounts}" cs="$HOME/.local/bin/claude-switcher" sw id next sid rc keep
          sw="$dir/.switcher"
          if [ -n "${1:-}" ] && [ -f "$dir/$1.json" ]; then
            "$cs" use "$1" || return $?
            shift
          fi
          case " $* " in
            *" -p "*|*" --print "*) CLAUDE_AS_LOOP=1 command claude "$@"; return $? ;;
          esac
          _claude_as_keep "$@"; keep=("${_claude_as_kept[@]}")
          while :; do
            id="$$-$RANDOM$RANDOM"
            CLAUDE_AS_LOOP=1 CLAUDE_AS_ID="$id" command claude "$@"
            rc=$?
            sid=""
            if [ -s "$sw/hop-$id" ]; then
              next=$(cat "$sw/hop-$id"); rm -f "$sw/hop-$id"
              [ -s "$sw/hop-$id.session" ] && sid=$(cat "$sw/hop-$id.session")
              rm -f "$sw/hop-$id.session"
            elif [ -s "$dir/.hop" ]; then
              next=$(cat "$dir/.hop"); rm -f "$dir/.hop"
            else
              return $rc
            fi
            # a failed switch must not end the session: resume on whatever login is live
            if "$cs" use "$next"; then
              printf 'claude-as: resuming as %s\n' "$next"
            else
              printf 'claude-as: switch to %s failed - resuming on the current login\n' "$next" >&2
            fi
            # --continue would pick the newest conversation in this directory - another session's, when
            # several run here; the hook hands over this one's id
            if [ -n "$sid" ]; then set -- "${keep[@]}" --resume "$sid"; else set -- "${keep[@]}" --continue; fi
          done
        }
        # an alias another startup file already set for `claude` is kept, not overridden
        case "$(alias claude 2>/dev/null)" in
          ''|*claude-as*) alias claude='claude-as' ;;
        esac
        # <<< claude-account <<<
        """#
    }

    /// Our block exists and is exactly what this version writes.
    public static func rcIsCurrent(rc: URL) -> Bool {
        guard let s = try? String(contentsOf: rc, encoding: .utf8) else { return false }
        return existingBlock(in: s) == rcBlock()
    }

    public static func rcStatus(rc: URL) -> RCStatus {
        guard let s = try? String(contentsOf: rc, encoding: .utf8), let block = existingBlock(in: s) else { return .missing }
        return block.contains("claude-switcher") ? .ours : .plugin
    }

    /// The first end marker and the begin marker closest before it. A begin marker whose block lost its end
    /// (a truncated earlier write, with the user's own lines appended after it) stays outside the range, so a
    /// replace never swallows those lines.
    static func blockRange(_ lines: [String]) -> ClosedRange<Int>? {
        guard let e = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == markEnd }),
              let b = lines[...e].lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == markBegin }) else { return nil }
        return b...e
    }

    public static func existingBlock(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        return blockRange(lines).map { lines[$0].joined(separator: "\n") }
    }

    /// Replaces the marked block (or appends one); `nil` removes it.
    public static func replaceBlock(in text: String, with block: String?) -> String {
        var lines = text.components(separatedBy: "\n")
        if let range = blockRange(lines) {
            let (b, e) = (range.lowerBound, range.upperBound)
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

    public struct Conflict: Equatable {
        public let line: Int
        public let text: String
        public init(line: Int, text: String) { self.line = line; self.text = text }
    }

    /// Lines outside the marked block that alias `claude` or `claude-as`, or define a `claude-as` function: names
    /// the block defines, so one of the two definitions would silently shadow the other. `alias claude='claude-as'`
    /// is the same wiring (plugin users add it by hand) and is not a conflict.
    public static func conflicts(in text: String) -> [Conflict] {
        let lines = text.components(separatedBy: "\n")
        let block = blockRange(lines)
        return lines.indices.compactMap { i in
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard block?.contains(i) != true, !line.hasPrefix("#"), redefinesOurNames(line) else { return nil }
            return Conflict(line: i + 1, text: line)
        }
    }

    static func redefinesOurNames(_ line: String) -> Bool {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = words.first else { return false }
        if first == "alias" {
            return words.dropFirst().contains { w in
                guard !w.hasPrefix("-"), let eq = w.firstIndex(of: "=") else { return false }
                let name = w[..<eq], value = w[w.index(after: eq)...]
                return name == "claude-as" || (name == "claude" && !["claude-as", "'claude-as'", "\"claude-as\""].contains(String(value)))
            }
        }
        let isKeyword = first == "function"
        guard let fn = isKeyword ? words.dropFirst().first : first, fn.hasPrefix("claude-as") else { return false }
        let bare = fn.hasSuffix("()") ? String(fn.dropLast(2)) : fn
        guard bare == "claude-as" else { return false }
        return isKeyword || fn.hasSuffix("()") || (words.count > 1 && words[1].hasPrefix("("))
    }

    public static func conflictMessage(rc: URL, _ conflicts: [Conflict]) -> String {
        "\(rc.path) đã có sẵn alias/hàm trùng tên với claude-as (claude, claude-as) — sửa hoặc xoá rồi cài lại:\n"
            + conflicts.map { "  dòng \($0.line): \($0.text)" }.joined(separator: "\n")
    }

    /// Refuses to write while the rc already defines one of our names elsewhere, so neither definition is lost.
    public static func installRC(rc: URL) throws {
        let existing = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
        let found = conflicts(in: existing)
        guard found.isEmpty else { throw ShellError(conflictMessage(rc: rc, found)) }
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
