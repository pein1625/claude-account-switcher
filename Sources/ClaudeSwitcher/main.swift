import AppKit
import ClaudeSwitcherCore

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--version") {
    print(AppInfo.version)
    exit(0)
}
if arguments.contains("--print-hook") {
    print(HookScript.normalized, terminator: "")
    exit(0)
}
if arguments.contains("--status") || arguments.contains("--doctor") {
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await Headless.run(status: arguments.contains("--status"), doctor: arguments.contains("--doctor"), noAPI: arguments.contains("--no-api"))
        done.signal()
    }
    done.wait()
    exit(0)
}
if arguments.contains("--uninstall") {
    let done = DispatchSemaphore(value: 0)
    var ok = true
    Task.detached {
        ok = await Uninstaller.run(removeApp: !arguments.contains("--keep-app"), dryRun: arguments.contains("--dry-run")) { print($0) }
        done.signal()
    }
    done.wait()
    exit(ok ? 0 : 1)
}
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    ClaudeSwitcher [--status [--no-api]] [--doctor] [--print-hook] [--version]
      (no flags)   run the menu bar app
      --status     accounts, usage, decision, running sessions as text
      --doctor     dependency + store check (also runs `claude-account doctor`)
      --no-api     skip the usage API, use recorded .quota lines
      --print-hook print the Stop/StopFailure hook script the app installs
      --uninstall [--dry-run] [--keep-app]
                   remove hook, login item, .switcher files, preferences and (unless --keep-app) the app bundle
    """)
    exit(0)
}

ClaudeSwitcherApp.main()
