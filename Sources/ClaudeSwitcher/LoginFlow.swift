import Foundation
import ClaudeSwitcherCore

enum LoginPhase: Equatable {
    case starting
    case waitingBrowser
    case needCode
    case finishing
    case done(String)
    case failed(String)

    var isTerminal: Bool { if case .done = self { return true }; if case .failed = self { return true }; return false }
}

struct LoginState: Equatable {
    var name: String
    var email: String?
    var phase: LoginPhase = .starting
    var url: URL?
    var openedIn: String?
    var transcript: String = ""
}

/// In-app `claude auth login`: runs claude on a pty inside a scratch CLAUDE_CONFIG_DIR, intercepts its browser
/// launch (a fake `open` first on PATH logs the URL instead), opens that URL itself - in a private window by
/// default - and snapshots the result. The live login is never touched.
@MainActor
final class LoginFlow {
    private(set) var state: LoginState
    private let switcher: Switcher
    private let ctx: Switcher.LoginContext
    private var proc: PTYProcess?
    private var raw = Data()
    private var openedURL = false
    private var outputURLScheduled = false
    private var lastOpenLogSize = 0
    private let onChange: (LoginState) -> Void
    private let privateWindow: Bool

    var name: String { state.name }

    init(name: String, email: String?, switcher: Switcher, privateWindow: Bool, onChange: @escaping (LoginState) -> Void) async throws {
        self.switcher = switcher
        self.privateWindow = privateWindow
        self.onChange = onChange
        state = LoginState(name: name, email: email)
        ctx = try await switcher.loginPrepare(name: name)
        guard let claude = Environment.which("claude") else {
            try? FileManager.default.removeItem(at: ctx.scratch)
            throw SwitcherError("không thấy `claude` trên PATH — thêm đường dẫn trong Cài đặt › Shell › PATH thêm")
        }
        // fake `open`: claude calls it to launch the browser; we want the URL, not its window
        let bin = ctx.scratch.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let shim = bin.appendingPathComponent("open")
        try "#!/bin/sh\n# claude-switcher: records the URL claude wanted to open; the app opens it itself\nprintf '%s\\n' \"$@\" >> \"$CLAUDE_SWITCHER_OPEN_LOG\"\nexit 0\n"
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
        if !openedURL, !outputURLScheduled, let url = TerminalText.firstURL(in: text, host: "claude.com") {
            outputURLScheduled = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !self.openedURL else { return }
                self.checkOpenLog()
                if !self.openedURL { self.openURL(url, from: "output") }
            }
        }
        if text.contains("Login successful") {
            if state.phase != .finishing { state.phase = .finishing }
        } else if text.contains("Opening browser") && state.phase == .starting {
            state.phase = .waitingBrowser
        }
        publish()
    }

    private func checkOpenLog() {
        guard !openedURL, let data = try? Data(contentsOf: openLog), data.count > lastOpenLogSize else { return }
        lastOpenLogSize = data.count
        let text = String(decoding: data, as: UTF8.self)
        if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("http") }), let url = URL(string: String(line)) {
            openURL(url, from: "open")
        }
    }

    /// `from == "open"`: the URL claude handed to the browser launcher - its redirect_uri is a localhost
    /// callback, so the code comes back by itself. `from == "output"`: the printed fallback URL redirects to
    /// platform.claude.com and shows a code the user must paste.
    private func openURL(_ url: URL, from: String) {
        openedURL = true
        state.url = url
        state.phase = from == "output" ? .needCode : .waitingBrowser
        publish()
        Task { [privateWindow] in
            let where_ = await Browser.open(url, privateWindow: privateWindow)
            state.openedIn = where_
            publish()
        }
    }

    func reopen(privateWindow: Bool) {
        guard let url = state.url else { return }
        Task {
            state.openedIn = await Browser.open(url, privateWindow: privateWindow)
            publish()
        }
    }

    func submitCode(_ code: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        proc?.write(c + "\r")
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
