import AppKit
import os

/// What happens before the menu bar app starts: a release build outside
/// Applications offers to move itself there, and a second copy of Carpe quits
/// in favour of the one that is already running.
enum LaunchGuard {
    private static let log = Logger(subsystem: "com.koreneff.carpe", category: "launch")

    /// Returns only if this copy should go on starting. Call it before
    /// anything registers the shortcut or adds the menu bar icon.
    ///
    /// The move comes first: a new version opened from its disk image has to
    /// be able to replace the older one that is running.
    static func run(
        applications: URL = InstallLocation.applications,
        askToMove: @MainActor (_ replacing: String?) -> Bool = askToMove
    ) {
        #if !DEBUG
        offerToMove(to: applications, ask: askToMove)
        #endif
        quitIfAlreadyRunning()
    }

    // MARK: - Single instance

    /// Other running copies of Carpe, from any folder.
    private static var otherInstances: [NSRunningApplication] {
        guard let bundleID = Bundle.main.bundleIdentifier else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
    }

    private static func quitIfAlreadyRunning() {
        guard let other = otherInstances.first else { return }
        log.notice("Carpe is already running (pid \(other.processIdentifier)), so this copy quits")
        other.activate()
        exit(0)
    }

    // MARK: - Moving to Applications

    private static func offerToMove(to applications: URL, ask: @MainActor (String?) -> Bool) {
        let source = Bundle.main.bundleURL
        guard !InstallLocation.isInstalled(source, in: applications) else { return }

        let destination = applications.appendingPathComponent("Carpe.app", isDirectory: true)
        let installedVersion = Bundle(url: destination)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let replacing = FileManager.default.fileExists(atPath: destination.path) ? installedVersion ?? "" : nil
        guard ask(replacing) else {
            log.notice("Staying outside Applications")
            return
        }

        do {
            try move(source, to: destination)
        } catch {
            log.error("Move to Applications failed: \(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Carpe couldn't be moved to Applications"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can drag Carpe to the Applications folder in Finder instead."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        log.notice("Moved to Applications; reopening from there")
        Relauncher.openAfterExit(destination)
        exit(0)
    }

    /// The question itself. `replacing` is the version in Applications that
    /// would be replaced ("" when it can't be read), or nil when there is none.
    static func askToMove(replacing: String?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move Carpe to Applications?"
        var text = "This copy of Carpe is outside the Applications folder. Carpe can move itself there and reopen."
        if let replacing {
            text += replacing.isEmpty
                ? "\n\nIt replaces the Carpe that is there now."
                : "\n\nIt replaces Carpe \(replacing), which is there now."
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Not now")
        // An accessory app is never frontmost by itself.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private struct StillRunning: LocalizedError {
        var errorDescription: String? { "Another copy of Carpe is running and didn't quit." }
    }

    private static func move(_ source: URL, to destination: URL) throws {
        let files = FileManager.default

        // The copy being replaced can't be running, and afterwards only the
        // moved one should be.
        try quit(otherInstances)

        // Copy next to the destination first, then swap, so Applications never
        // holds half an app.
        let staging = try files.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true
        )
        defer { try? files.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try files.copyItem(at: source, to: copy)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: copy)
        } else {
            try files.moveItem(at: copy, to: destination)
        }

        // The copy that was opened goes to the Trash, when there is one to
        // remove: not in a read-only disk image, and not when macOS runs the
        // app from a random path that only mirrors the real one.
        let readOnly = (try? source.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        if !readOnly, !InstallLocation.isTranslocated(source) {
            do {
                try files.trashItem(at: source, resultingItemURL: nil)
            } catch {
                log.error("Couldn't move the old copy to the Trash: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Asks the copies to quit, waits, and insists if one is stuck (in an
    /// alert of its own, say). Carpe has nothing unsaved to lose.
    private static func quit(_ instances: [NSRunningApplication]) throws {
        func wait(_ seconds: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if instances.allSatisfy(\.isTerminated) { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            return instances.allSatisfy(\.isTerminated)
        }

        guard !instances.isEmpty else { return }
        instances.forEach { $0.terminate() }
        if wait(5) { return }
        instances.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        guard wait(3) else { throw StillRunning() }
    }
}

/// Reopens the app after this process has gone. A copy started while this one
/// is still alive would find it running and quit.
enum Relauncher {
    /// Leaves a small shell process behind that waits for this one to exit
    /// (ten seconds at most) and then opens `bundle`. The caller quits.
    static func openAfterExit(_ bundle: URL = Bundle.main.bundleURL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path travels as an argument, never as part of the script.
        process.arguments = [
            "-c",
            "i=0; while /bin/kill -0 \(pid) 2>/dev/null && [ $i -lt 100 ]; do /bin/sleep 0.1; i=$((i+1)); done; exec /usr/bin/open \"$0\"",
            bundle.path,
        ]
        try? process.run()
    }
}
