import AppKit
import ServiceManagement
import ClaudeSwitcherCore

/// Removes what the app itself created. The account store (snapshots, profiles, .quota, live login) is shared
/// with the claude-account plugin and is never touched here.
enum Uninstaller {
    typealias Step = (what: String, run: () async throws -> Void)

    static let keeps = "Giữ nguyên: snapshot Keychain Claude Code-credentials-acct-*, ~/.claude/accounts/*.json, *.quota, .current và login live — gỡ bằng `claude-switcher remove <name>` nếu muốn."

    static func plan(removeApp: Bool) -> [Step] {
        let fm = FileManager.default
        var steps: [Step] = []
        if HookInstaller.isMentionedInSettings() {
            steps.append(("Gỡ hook Stop/StopFailure khỏi \(Paths.settingsJSON.path) (có backup .bak-*)", { try await HookInstaller.unwireSettings() }))
        }
        if fm.fileExists(atPath: Paths.oldHookScript.path) {
            steps.append(("Xoá hook cũ \(Paths.oldHookScript.path)", { try fm.removeItem(at: Paths.oldHookScript) }))
        }
        if fm.fileExists(atPath: Paths.shim.path) {
            steps.append(("Xoá shim \(Paths.shim.path)", { ShellInstaller.removeShim() }))
        }
        let rc = ShellInstaller.rcFile()
        switch ShellInstaller.rcStatus(rc: rc) {
        case .ours: steps.append(("Gỡ block claude-as + alias claude khỏi \(rc.path)", { try ShellInstaller.removeRC(rc: rc) }))
        case .plugin: steps.append(("Giữ block claude-as trong \(rc.path): là bản của plugin claude-account", {}))
        case .missing: break
        }
        if SMAppService.mainApp.status == .enabled {
            steps.append(("Bỏ “Chạy khi đăng nhập máy”", { try SMAppService.mainApp.unregister() }))
        }
        let store = AccountStore()
        if let hop = store.readHop(), hop == store.liveName(profiles: store.loadProfiles(), live: store.liveOAuthAccount()) {
            steps.append(("Xoá \(Paths.hopFile.path) (cờ hop trỏ vào account đang live)", { store.removeHop() }))
        }
        if fm.fileExists(atPath: Paths.switcherDir.path) {
            steps.append(("Xoá \(Paths.switcherDir.path) (heartbeat, log, cache usage, plan restart, hop markers)", { try fm.removeItem(at: Paths.switcherDir) }))
        }
        let domain = Bundle.main.bundleIdentifier ?? AppInfo.bundleID
        steps.append(("Xoá preferences \(domain)", { UserDefaults.standard.removePersistentDomain(forName: domain) }))
        if removeApp, Bundle.main.bundleURL.pathExtension == "app" {
            let url = Bundle.main.bundleURL
            steps.append(("Chuyển \(url.path) vào Thùng rác", { _ = try await NSWorkspace.shared.recycle([url]) }))
        }
        return steps
    }

    static func run(removeApp: Bool, dryRun: Bool, log: (String) -> Void) async -> Bool {
        var ok = true
        for step in plan(removeApp: removeApp) {
            if dryRun { log("[dry-run] \(step.what)"); continue }
            do { try await step.run(); log("done  \(step.what)") }
            catch { ok = false; log("FAIL  \(step.what): \(error.localizedDescription)") }
        }
        log(keeps)
        return ok
    }
}
