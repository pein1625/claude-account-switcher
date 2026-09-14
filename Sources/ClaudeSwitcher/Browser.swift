import AppKit
import ClaudeSwitcherCore

/// Opens the OAuth page. The browser approves whichever claude.ai session it already holds, so "add another
/// account" wants a private window; Chromium and Firefox families take a flag for that, Safari does not.
enum Browser {
    static func defaultBundleID() -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://claude.com")!) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }

    static func privateFlag(bundleID: String) -> String? {
        switch bundleID {
        case "com.google.chrome", "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
             "com.brave.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium", "company.thebrowser.Browser",
             "com.operasoftware.Opera":
            return "--incognito"
        case "com.microsoft.edgemac": return "--inprivate"
        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly": return "-private-window"
        default: return nil
        }
    }

    /// Returns a short description of where the page went.
    @discardableResult
    static func open(_ url: URL, privateWindow: Bool) async -> String {
        let id = defaultBundleID() ?? ""
        if privateWindow, let flag = privateFlag(bundleID: id) {
            let r = try? await Shell.run("/usr/bin/open", ["-n", "-b", id, "--args", flag, url.absoluteString], timeout: 20)
            if r?.ok == true { return "cửa sổ riêng tư (\(name(id)))" }
        }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
        return privateWindow ? "\(name(id)) — không có chế độ riêng tư qua dòng lệnh, đã mở cửa sổ thường" : name(id)
    }

    static func name(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return "trình duyệt mặc định" }
        return url.deletingPathExtension().lastPathComponent
    }
}
