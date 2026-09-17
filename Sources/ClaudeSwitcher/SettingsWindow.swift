import AppKit

/// SwiftUI's `Settings` scene opens an ordinary window, but a menu bar app runs as `.accessory` and such an app
/// cannot reliably take the front: the window landed behind whatever was on screen, and when it was already
/// open the gear button looked like it did nothing. While the window is up the app becomes `.regular` (a real
/// activation, plus a Dock icon), and the policy goes back to `.accessory` when it closes.
enum SettingsWindow {
    private static var closeObserver: NSObjectProtocol?

    static func present(_ open: () -> Void) {
        open()
        raise(attempt: 0)
    }

    private static func raise(attempt: Int) {
        guard let w = window() else {
            // `openSettings()` is a no-op in some states; the AppKit action behind Settings… is the fallback.
            if attempt == 3 { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            guard attempt < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { raise(attempt: attempt + 1) }
            return
        }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        w.collectionBehavior.insert(.moveToActiveSpace)
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        watchClose(w)
    }

    static func window() -> NSWindow? {
        NSApp.windows.first { w in
            let id = (w.identifier?.rawValue ?? "").lowercased()
            return id.contains("settings") || id.contains("preferences")
        }
    }

    private static func watchClose(_ w: NSWindow) {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            if let o = closeObserver { NotificationCenter.default.removeObserver(o); closeObserver = nil }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
