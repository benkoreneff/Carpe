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
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
