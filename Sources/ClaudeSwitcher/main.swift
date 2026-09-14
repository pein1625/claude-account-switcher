import AppKit
import ClaudeSwitcherCore

let arguments = Array(CommandLine.arguments.dropFirst())

// Any argument means CLI use; only a bare launch (Finder, `open`) starts the menu bar app.
if !arguments.isEmpty {
    let done = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task.detached {
        code = await CLIMain.run(arguments)
        done.signal()
    }
    done.wait()
    exit(code)
}

ClaudeSwitcherApp.main()
