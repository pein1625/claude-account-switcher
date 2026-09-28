import Foundation
import ClaudeSwitcherCore

struct DoctorItem: Identifiable {
    enum Level { case ok, warn, fail }
    let id = UUID()
    var level: Level
    var text: String
}

struct SetupStatus: Equatable {
    var shim: ShellInstaller.ShimStatus = .missing
    var hookWired = false
    var rc: ShellInstaller.RCStatus = .missing

    /// Enough for sessions to hop by themselves; the plugin's own `claude-as` also qualifies.
    var complete: Bool { shim == .current && hookWired && rc != .missing }

    var missing: [String] {
        var m: [String] = []
        if shim != .current { m.append(shim == .stale ? "shim claude-switcher (trỏ sai chỗ)" : "shim claude-switcher") }
        if !hookWired { m.append("hook Stop/StopFailure") }
        if rc == .missing { m.append("claude-as + alias claude trong \(ShellInstaller.rcFile().lastPathComponent)") }
        return m
    }

    static func current(appBinary: String) -> SetupStatus {
        SetupStatus(shim: ShellInstaller.shimStatus(appBinary: appBinary),
                    hookWired: HookInstaller.isSettingsWired(),
                    rc: ShellInstaller.rcStatus(rc: ShellInstaller.rcFile()))
    }
}

enum Doctor {
    static func run(store: AccountStore, usage: [String: AccountUsage], appBinary: String) async -> [DoctorItem] {
        var items: [DoctorItem] = []
        func add(_ l: DoctorItem.Level, _ t: String) { items.append(DoctorItem(level: l, text: t)) }

        let profiles = store.loadProfiles()
        let live = store.liveOAuthAccount()
        let liveName = store.liveName(profiles: profiles, live: live)
        let setup = SetupStatus.current(appBinary: appBinary)

        if let claude = Environment.which("claude") {
            let v = (try? await Shell.run(claude, ["--version"], timeout: 20))?.trimmedOut.split(separator: "\n").first.map(String.init) ?? "?"
            add(.ok, "claude: \(claude) (\(v))")
        } else {
            add(.fail, "claude: không thấy trên PATH → không đăng nhập thêm account được (Cài đặt › Shell › PATH thêm)")
        }
        add(live != nil ? .ok : .fail, live.map { "~/.claude.json oauthAccount: \($0.emailAddress ?? "?")" } ?? "~/.claude.json không có oauthAccount → `claude auth login` trước")
        add(liveName != nil ? .ok : .warn, liveName.map { "Login hiện tại đã lưu là '\($0)'" } ?? "Login hiện tại chưa lưu → “Lưu login hiện tại…”")
        let now = Date()
        let liveItem = await Keychain.inspect(service: Keychain.liveService)
        if let problem = liveItem.snapshotProblem {
            add(.fail, "Keychain '\(Keychain.liveService)': \(problem)")
        } else {
            add(.ok, "Keychain live item có OAuth token")
        }
        if let liveBlob = liveItem.blob, let cfgUuid = live?.accountUuid {
            if liveBlob.isExpired(at: now) {
                add(.warn, "Token live hết hạn → chưa kiểm được token thuộc account nào (Claude Code tự refresh khi chạy)")
            } else if let p = await UsageClient().fetchProfile(token: liveBlob.accessToken), (200..<300).contains(p.status), let u = p.uuid {
                if u == cfgUuid {
                    add(.ok, "Token live thuộc đúng account trong ~/.claude.json")
                } else {
                    let owner = profiles.first { $0.uuid == u }?.name ?? p.email ?? u
                    add(.fail, "LỆCH: token live thuộc \(owner), ~/.claude.json nói \(liveName ?? live?.emailAddress ?? "?") → Sửa lệch")
                }
            } else {
                add(.warn, "Không kiểm được token live thuộc account nào (mạng / API)")
            }
        }
        add(.ok, "\(profiles.count) account đã lưu trong \(Paths.accountsDir.path)")
        for p in profiles {
            let item = await Keychain.inspectSaved(p.name)
            let isLive = p.name == liveName
            if let problem = item.snapshotProblem {
                add(isLive ? .warn : .fail, "\(p.name): snapshot không dùng được (\(problem))" + (isLive ? " — đang live, được chụp lại khi rời account" : " → ⋯ › Xoá snapshot rồi Thêm account lại"))
            } else if let b = item.blob {
                let refreshDead = b.refreshTokenExpiresAt.map { $0 <= now } ?? false
                var parts: [String] = []
                if let e = b.expiresAt { parts.append(e > now ? "access token tới \(Format.clock(e))" : "access token hết hạn \(Format.ago(e, now: now)) trước") }
                if let r = b.refreshTokenExpiresAt { parts.append(refreshDead ? "REFRESH TOKEN HẾT HẠN" : "refresh token tới \(ISO8601.string(r).prefix(10))") }
                add(refreshDead ? .warn : .ok, "\(p.name): snapshot có đủ token" + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"))
            }
            let u = usage[p.name]
            if let u, u.isFreshAPI { add(.ok, "\(p.name): usage API OK (5h \(Int(u.fiveHour?.pct ?? 0))%, 7d \(Int(u.sevenDay?.pct ?? 0))%)") }
            else if let u, let code = u.httpStatus { add(.warn, "\(p.name): usage API HTTP \(code) → dùng số ghi trong .quota") }
            else if let u, let e = u.error { add(.warn, "\(p.name): \(e)") }
            else { add(.warn, "\(p.name): chưa đo") }
        }
        add(setup.shim == .current ? .ok : .warn, setup.shim == .current ? "Shim \(Paths.shim.path) → app" : setup.shim == .stale ? "Shim trỏ sai chỗ (app đã chuyển?) → Cài lại" : "Chưa có shim \(Paths.shim.path)")
        add(setup.hookWired ? .ok : .warn, setup.hookWired ? "Hook Stop/StopFailure đã vào ~/.claude/settings.json" : "Hook chưa cài → session không tự restart khi hop")
        switch setup.rc {
        case .ours: add(.ok, "claude-as + alias claude (bản app) trong \(ShellInstaller.rcFile().path)")
        case .plugin: add(.ok, "claude-as của plugin claude-account trong \(ShellInstaller.rcFile().path) — dùng được, cùng store")
        case .missing: add(.warn, "Chưa có claude-as trong \(ShellInstaller.rcFile().path) → `claude` không tự relaunch --continue")
        }
        if let rc = try? String(contentsOf: ShellInstaller.rcFile(), encoding: .utf8), !rc.contains("alias claude=") , setup.rc != .missing {
            add(.warn, "Thiếu alias claude='claude-as' → phải gõ claude-as thay cho claude")
        }
        if setup.rc == .ours, ShellInstaller.rcOutdated(rc: ShellInstaller.rcFile()) {
            add(.warn, "claude-as trong \(ShellInstaller.rcFile().path) là bản cũ → Cài lại (app tự cập nhật khi mở)")
        }
        if FileManager.default.isExecutableFile(atPath: Paths.pluginCLI.path) {
            add(.ok, "Plugin claude-account cũng có mặt (\(Paths.pluginCLI.path)) — hai tool dùng chung store")
        }
        if FileManager.default.fileExists(atPath: Paths.home.appendingPathComponent("Library/LaunchAgents/com.hapk.claude-quota-ping.plist").path) {
            add(.warn, "LaunchAgent claude-quota-ping đổi account tạm 3 lần/ngày; app chờ 30s ổn định sau mỗi lần .current đổi")
        }
        return items
    }
}
