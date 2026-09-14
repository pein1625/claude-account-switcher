import Foundation

/// `claude auth login` needs a real terminal (browser round-trip, paste-code fallback), so adding an account
/// opens a Terminal window running `claude-switcher login <name>`; the live login stays untouched.
public enum LoginLauncher {
    public static func loginScript(cli: String, name: String, email: String?) -> String {
        var cmd = "\(ShellInstaller.shellQuote(cli)) login \(ShellInstaller.shellQuote(name))"
        if let email, !email.isEmpty { cmd += " --email \(ShellInstaller.shellQuote(email))" }
        return """
        #!/bin/bash
        export PATH=\(ShellInstaller.shellQuote(Environment.path))
        echo "Claude Switcher: đăng nhập account '\(name)' (login hiện tại không bị đụng)"
        echo "claude: $(command -v claude || echo 'KHÔNG THẤY trên PATH') $(claude --version 2>/dev/null | head -1)"
        echo "Trình duyệt sẽ mở trang đăng nhập Claude. Không mở → copy URL mà claude in ra bên dưới vào trình duyệt."
        echo
        \(cmd)
        status=$?
        echo
        if [ $status -eq 0 ]; then echo "Xong. Quay lại Claude Switcher, account sẽ xuất hiện trong danh sách."
        else echo "Thất bại (exit $status). Xem thông báo phía trên; gửi nội dung cửa sổ này nếu cần hỗ trợ."; fi
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
