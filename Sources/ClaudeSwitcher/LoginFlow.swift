import Foundation
import ClaudeSwitcherCore

enum LoginPhase: Equatable {
    case starting
    /// link ready to copy; its redirect is a localhost callback - paste the address the browser lands on
    case awaitingLink
    /// only the printed fallback link was seen; its page ends on a code to paste
    case needCode
    case finishing
    case done(String)
    case failed(String)

    var isTerminal: Bool { if case .done = self { return true }; if case .failed = self { return true }; return false }
}

struct LoginState: Equatable {
    var name: String
    var email: String?
    var relogin = false
    var phase: LoginPhase = .starting
    var url: URL?
    var transcript: String = ""
    var lastError: String?
}

/// In-app `claude auth login`: runs claude on a pty inside a scratch CLAUDE_CONFIG_DIR, intercepts its browser
/// launch (a fake `open` first on PATH logs the URL instead) and hands the link to the user to open wherever
/// the right claude.ai session lives. The user pastes back the localhost callback address the browser lands on
/// (or the code of the fallback page); the app delivers it to claude and snapshots the result. No browser is
/// opened by the app, and the live login is never touched.
@MainActor
final class LoginFlow {
    private(set) var state: LoginState
    private let switcher: Switcher
    private let ctx: Switcher.LoginContext
    private var proc: PTYProcess?
    private var raw = Data()
    private var gotURL = false
    private var outputURLScheduled = false
    private var lastOpenLogSize = 0
    private let onChange: (LoginState) -> Void

    var name: String { state.name }

    init(name: String, email: String?, relogin: Bool = false, switcher: Switcher, onChange: @escaping (LoginState) -> Void) async throws {
        self.switcher = switcher
        self.onChange = onChange
        state = LoginState(name: name, email: email, relogin: relogin)
        ctx = try await switcher.loginPrepare(name: name, relogin: relogin)
        guard let claude = Environment.which("claude") else {
            try? FileManager.default.removeItem(at: ctx.scratch)
            throw SwitcherError("không thấy `claude` trên PATH — thêm đường dẫn trong Cài đặt › Shell › PATH thêm")
        }
        // fake `open`: claude calls it to launch the browser; we want the URL, not its window
        let bin = ctx.scratch.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let shim = bin.appendingPathComponent("open")
        try "#!/bin/sh\n# claude-switcher: records the URL claude wanted to open; the app shows it instead\nprintf '%s\\n' \"$@\" >> \"$CLAUDE_SWITCHER_OPEN_LOG\"\nexit 0\n"
            .write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

        var env: [String: String] = [
            "HOME": Paths.home.path, "USER": NSUserName(), "LANG": "en_US.UTF-8", "TERM": "xterm-256color",
            "CLAUDE_CONFIG_DIR": ctx.scratch.path,
            "CLAUDE_SWITCHER_OPEN_LOG": openLog.path,
            "PATH": bin.path + ":" + Environment.path,
        ]
        for key in ["TMPDIR", "SHELL", "LOGNAME"] { if let v = ProcessInfo.processInfo.environment[key] { env[key] = v } }
        var args = ["auth", "login"]
        if let email, !email.isEmpty { args += ["--email", email] }
        let p = try PTYProcess(path: claude, args: args, env: env)
        proc = p
        let flow = self
        Task.detached(priority: .userInitiated) {
            let status = p.run(onOutput: { data in Task { @MainActor in flow.consume(data) } },
                               tick: { Task { @MainActor in flow.checkOpenLog() } })
            await flow.exited(status: status)
        }
    }

    private var openLog: URL { ctx.scratch.appendingPathComponent("open.log") }

    private func publish() { onChange(state) }

    private func consume(_ data: Data) {
        raw.append(data)
        if raw.count > 64_000 { raw = raw.suffix(48_000) }
        let text = TerminalText.strip(String(decoding: raw, as: UTF8.self))
        state.transcript = String(text.suffix(4000))
        // The `open` shim delivers the exact URL; the printed one is a fallback (terminal rendering can alter it),
        // used only when the shim has not reported within a moment.
        if !gotURL, !outputURLScheduled, let url = TerminalText.firstURL(in: text, host: "claude.com") {
            outputURLScheduled = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !self.gotURL else { return }
                self.checkOpenLog()
                if !self.gotURL { self.offer(url, from: "output") }
            }
        }
        if text.contains("Login successful") {
            if state.phase != .finishing { state.phase = .finishing }
        }
        publish()
    }

    private func checkOpenLog() {
        guard !gotURL, let data = try? Data(contentsOf: openLog), data.count > lastOpenLogSize else { return }
        lastOpenLogSize = data.count
        let text = String(decoding: data, as: UTF8.self)
        if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("http") }), let url = URL(string: String(line)) {
            offer(url, from: "open")
        }
    }

    /// `from == "open"`: the URL claude handed to the browser launcher - its redirect_uri is a localhost
    /// callback that claude is listening on. `from == "output"`: the printed fallback URL redirects to
    /// platform.claude.com and shows a code the user must paste.
    private func offer(_ url: URL, from: String) {
        gotURL = true
        state.url = url
        state.phase = from == "output" ? .needCode : .awaitingLink
        publish()
    }

    /// Accepts what the user pasted back: the localhost callback address (fetched here, so claude's own listener
    /// gets the code), a platform callback URL (its code#state goes to the paste prompt), or a bare code.
    func submit(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !state.phase.isTerminal else { return }
        if let pasted = URLComponents(string: text), pasted.scheme?.hasPrefix("http") == true {
            let items = pasted.queryItems ?? []
            guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                state.lastError = "link này không có code — copy link trên thanh địa chỉ SAU khi bấm Authorize"
                publish(); return
            }
            if Self.loopback.contains(pasted.host ?? "") {
                guard let expected = callback else {
                    state.lastError = "phiên này dùng link dự phòng — dán code trang Claude hiện ra, không phải link localhost"
                    publish(); return
                }
                guard pasted.port == expected.port, pasted.path == expected.path else {
                    state.lastError = "link kết quả không khớp phiên đăng nhập này (cổng \(expected.port.map(String.init) ?? "?")) — có thể là của lần đăng nhập trước"
                    publish(); return
                }
                deliver(callbackURL: text)
                return
            }
            let st = items.first(where: { $0.name == "state" })?.value
            writeCode(st.map { "\(code)#\($0)" } ?? code)
            return
        }
        writeCode(text)
    }

    private static let loopback: Set<String> = ["localhost", "127.0.0.1"]

    /// redirect_uri of the offered link when it is a local callback
    private var callback: URLComponents? {
        guard let url = state.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = comps.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let cb = URLComponents(string: raw), Self.loopback.contains(cb.host ?? "") else { return nil }
        return cb
    }

    private func deliver(callbackURL: String) {
        state.lastError = nil
        state.phase = .finishing
        publish()
        Task {
            // curl, not URLSession: `localhost` may resolve to ::1 or 127.0.0.1 depending on where claude bound
            let r = try? await Shell.run("/usr/bin/curl", ["-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20", callbackURL], timeout: 30)
            guard !state.phase.isTerminal else { return }
            if r?.ok != true {
                state.phase = .awaitingLink
                state.lastError = "không gửi được link về claude: \(r?.trimmedErr ?? "curl lỗi") — claude có thể đã hết thời gian chờ, huỷ rồi đăng nhập lại"
                publish()
            }
        }
    }

    private func writeCode(_ code: String) {
        proc?.write(code + "\r")
        state.lastError = nil
        state.phase = .finishing
        publish()
    }

    private func exited(status: Int32) async {
        proc = nil
        if status == 0 {
            state.phase = .finishing; publish()
            do {
                let msg = try await switcher.loginFinish(name: state.name, ctx: ctx)
                state.phase = .done(msg)
            } catch {
                state.phase = .failed(error.localizedDescription)
            }
        } else {
            let tail = state.transcript.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.suffix(3).joined(separator: " · ")
            state.phase = .failed("claude auth login kết thúc với mã \(status)" + (tail.isEmpty ? "" : ": \(tail)"))
            try? FileManager.default.removeItem(at: ctx.scratch)
        }
        publish()
    }

    func cancel() {
        proc?.terminate()
        proc = nil
        try? FileManager.default.removeItem(at: ctx.scratch)
        state.phase = .failed("đã huỷ")
        publish()
    }
}
