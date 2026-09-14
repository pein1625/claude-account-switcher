import Foundation
import Darwin
import ClaudeSwitcherCore

/// A child on its own pseudo-terminal. `claude auth login` is an Ink TUI: it needs isatty() stdio and raw mode,
/// and a Foundation `Process` child inheriting a real terminal gets stopped by SIGTTOU. A pty owned by the app
/// gives it a tty with no job-control strings attached, so the login can run without any Terminal window.
final class PTYProcess {
    let pid: pid_t
    private let master: Int32
    private let lock = NSLock()
    private var finished = false

    init(path: String, args: [String], env: [String: String], cols: UInt16 = 1000, rows: UInt16 = 50) throws {
        let m = posix_openpt(O_RDWR | O_NOCTTY)
        guard m >= 0 else { throw ShellError("posix_openpt: \(String(cString: strerror(errno)))") }
        guard grantpt(m) == 0, unlockpt(m) == 0, let name = ptsname(m) else {
            close(m); throw ShellError("pty setup failed: \(String(cString: strerror(errno)))")
        }
        let s = open(name, O_RDWR | O_NOCTTY)
        guard s >= 0 else { close(m); throw ShellError("open pty slave: \(String(cString: strerror(errno)))") }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(s, 0x8008_7467 /* TIOCSWINSZ */, &ws)

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, s, 0)
        posix_spawn_file_actions_adddup2(&fa, s, 1)
        posix_spawn_file_actions_adddup2(&fa, s, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // own session (pid == pgid, so kill(-pid) reaches claude's own children too); every fd but 0-2 closed
        posix_spawnattr_setflags(&attr, Int16(truncatingIfNeeded: POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            posix_spawn_file_actions_destroy(&fa)
            posix_spawnattr_destroy(&attr)
            close(s)
        }
        var child: pid_t = 0
        let rc = posix_spawn(&child, path, &fa, &attr, argv, envp)
        guard rc == 0 else { close(m); throw ShellError("posix_spawn \(path): \(String(cString: strerror(rc)))") }
        pid = child
        master = m
    }

    /// Reads until the child exits. `onOutput` gets raw terminal bytes as they arrive; `tick` runs every poll
    /// interval (~300 ms) so the caller can watch side files. Returns the exit status (or -signal).
    func run(onOutput: @escaping (Data) -> Void, tick: @escaping () -> Void) -> Int32 {
        var buf = [UInt8](repeating: 0, count: 8192)
        var status: Int32 = 0
        var exited = false
        while true {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, 300)
            if r > 0 {
                let n = read(master, &buf, buf.count)
                if n > 0 {
                    onOutput(Data(buf[0..<Int(n)]))
                } else if exited {
                    break
                } else if n < 0 && errno != EAGAIN && errno != EINTR {
                    if waitpid(pid, &status, WNOHANG) == pid { exited = true }
                    if exited { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            tick()
            if !exited, waitpid(pid, &status, WNOHANG) == pid {
                exited = true
                // drain whatever is still buffered on the master side
                while true {
                    var p2 = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                    guard poll(&p2, 1, 50) > 0 else { break }
                    let n = read(master, &buf, buf.count)
                    guard n > 0 else { break }
                    onOutput(Data(buf[0..<Int(n)]))
                }
                break
            }
        }
        lock.lock(); finished = true; lock.unlock()
        close(master)
        if status & 0x7f == 0 { return (status >> 8) & 0xff }
        return -(status & 0x7f)
    }

    func write(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        let bytes = Array(text.utf8)
        var off = 0
        while off < bytes.count {
            let n = Darwin.write(master, Array(bytes[off...]), bytes.count - off)
            if n <= 0 { break }
            off += Int(n)
        }
    }

    func terminate() {
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [pid] in kill(-pid, SIGKILL) }
    }
}

enum TerminalText {
    /// Drops CSI / OSC escape sequences and carriage returns so the transcript reads as plain text.
    static func strip(_ s: String) -> String {
        var out = s
        for pattern in ["\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", "\u{1B}[()][A-Za-z0-9]", "\u{1B}[=>]"] {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return out.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func firstURL(in s: String, host: String) -> URL? {
        guard let r = s.range(of: "https://\(NSRegularExpression.escapedPattern(for: host))/[A-Za-z0-9./?=&%_+:~-]+", options: .regularExpression) else { return nil }
        return URL(string: String(s[r]))
    }
}
