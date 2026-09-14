import Foundation

/// `claude auth login` needs a real terminal (browser round-trip, paste-code fallback), so adding an account
/// opens a Terminal window running `claude-account login <name>`; the live login stays untouched (the CLI
/// signs in inside a scratch config dir and only snapshots the result).
public enum LoginLauncher {
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func loginScript(cli: String, name: String, email: String?) -> String {
        var cmd = "\(shellQuote(cli)) login \(shellQuote(name))"
        if let email, !email.isEmpty { cmd += " --email \(shellQuote(email))" }
        return """
        #!/bin/bash
        export PATH=\(shellQuote(Environment.path))
        echo "Claude Switcher: đăng nhập account '\(name)' (trình duyệt sẽ mở; login hiện tại không bị đụng)"
        echo
        \(cmd)
        status=$?
        echo
        if [ $status -eq 0 ]; then echo "Xong. Quay lại Claude Switcher, account sẽ xuất hiện trong danh sách."
        else echo "Thất bại (exit $status). Xem thông báo phía trên."; fi
        echo "Có thể đóng cửa sổ này."
        """
    }

    public static func open(cli: String, name: String, email: String?, terminalApp: String) async throws {
        Paths.ensureSwitcherDir()
        let file = Paths.switcherDir.appendingPathComponent("login-\(name).command")
        try loginScript(cli: cli, name: name, email: email).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let r = try await Shell.run("/usr/bin/open", ["-a", terminalApp, file.path], timeout: 20)
        guard r.ok else { throw ShellError("open -a \(terminalApp) failed: \(r.trimmedErr)") }
    }
}
