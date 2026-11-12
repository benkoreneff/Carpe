import AppKit

// `Carpe --extract image.png` runs the extraction once in the terminal and
// exits, without starting the menu bar app.
if let command = CommandLineTool(arguments: CommandLine.arguments) {
    Task {
        exit(await command.run())
    }
    dispatchMain()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Before the delegate exists, so a copy that is about to quit or move never
// registers the shortcut or shows a menu bar icon.
LaunchGuard.run()

let delegate = AppDelegate()
app.delegate = delegate
app.run()
