import SwiftUI
import AppKit
import ClaudeSwitcherCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        if !AppModel.smokeMode { Notifier.requestPermission() }
    }

    /// The app turns `.regular` while Settings is open (see `SettingsWindow`); closing that window must not
    /// take the menu bar app down with it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct ClaudeSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel = {
        let m = AppModel()
        m.start()
        return m
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
