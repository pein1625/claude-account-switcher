import Foundation

/// `claude auth login` needs a real terminal (browser round-trip, paste-code fallback), so adding an account
/// opens a Terminal window running `claude-switcher login <name>`; the live login stays untouched.
public enum LoginLauncher {
    /// bash runs `claude auth login` itself (same shape as the proven claude-account script); the binary only
    /// prepares the scratch dir and snapshots the result.
    /// `scratch` given: the caller already ran login-prepare (the `claude-switcher login` command execs this).
    public static func loginScript(cli: String, name: String, email: String?, scratch: String? = nil) -> String {
        let q = ShellInstaller.shellQuote
        let emailArg = (email?.isEmpty == false) ? " --email \(q(email!))" : ""
        let prepare = scratch.map { "scratch=\(q($0))" } ?? #"scratch=$("$cs" login-prepare "$name") || exit 1"#
        return """
        #!/bin/bash
        export PATH=\(q(Environment.path))
        cs=\(q(cli))
        name=\(q(name))
        echo "Claude Switcher: đăng nhập account '\(name)' (login hiện tại không bị đụng)"
        if ! command -v claude >/dev/null 2>&1; then
          echo "KHÔNG THẤY claude trên PATH. Cài Claude Code hoặc thêm đường dẫn vào Cài đặt › Shell › PATH thêm." >&2
          echo "PATH=$PATH" >&2
          exit 1
        fi
        echo "claude: $(command -v claude) ($(claude --version 2>/dev/null | head -1))"
        \(prepare)
        echo
        echo "Trình duyệt sẽ mở trang đăng nhập Claude. Không mở → copy URL claude in ra bên dưới vào trình duyệt, rồi dán code lại đây."
        echo "LƯU Ý: trình duyệt đang đăng nhập claude.ai bằng account nào thì sẽ lấy account đó. Muốn account KHÁC → đăng xuất claude.ai trước hoặc mở URL trong cửa sổ riêng tư."
        echo
        CLAUDE_CONFIG_DIR="$scratch" claude auth login\(emailArg)
        status=$?
        echo
        if [ $status -eq 0 ]; then
          "$cs" login-finish "$name" "$scratch" && echo "Xong. Quay lại Claude Switcher, account sẽ xuất hiện trong danh sách."
        else
          rm -rf "$scratch"
          echo "claude auth login thất bại (exit $status). Xem thông báo phía trên; gửi nội dung cửa sổ này nếu cần hỗ trợ."
        fi
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
