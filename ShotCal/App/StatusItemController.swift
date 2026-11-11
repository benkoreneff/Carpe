import AppKit

/// The menu bar icon and its menu. The icon turns into a spinner while a
/// screenshot is being processed, then briefly shows how it went.
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        var capture: () -> Void
        var showSettings: () -> Void
        var connectGoogle: () -> Void
        var open: (SavedCapture) -> Void
        var showPermissions: () -> Void
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let spinner = NSProgressIndicator()
    private let icon: NSImage?
    private let pipeline: Pipeline
    private let google: GoogleAccount
    private let apple: AppleCalendarService
    private let hotKeys: HotKeyCenter
    private let actions: Actions

    init(
        pipeline: Pipeline, google: GoogleAccount, apple: AppleCalendarService, hotKeys: HotKeyCenter, actions: Actions
    ) {
        self.pipeline = pipeline
        self.google = google
        self.apple = apple
        self.hotKeys = hotKeys
        self.actions = actions

        let icon = Self.symbol("calendar.badge.plus", "ShotCal")
        self.icon = icon
        super.init()

        if let button = item.button {
            button.image = icon
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// Call when the pipeline's state changes.
    func refresh() {
        let busy = pipeline.isWorking
        if busy {
            item.button?.image = nil
            spinner.startAnimation(nil)
            return
        }
        spinner.stopAnimation(nil)
        switch pipeline.recentOutcome {
        case .success: item.button?.image = Self.symbol("checkmark.circle.fill", "ShotCal: done")
        case .needsAttention: item.button?.image = Self.symbol("exclamationmark.triangle.fill", "ShotCal: needs attention")
        case nil: item.button?.image = icon
        }
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    // The menu is rebuilt each time it opens, so it always shows current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let capture = add("Capture Event", #selector(capture), to: menu)
        let hotKey = hotKeys.combo
        if !hotKeys.isRegistered {
            menu.addItem(info("\(hotKey.displayString) is taken by another app"))
        } else if hotKey.menuKeyEquivalent.isEmpty {
            menu.addItem(info("Shortcut: \(hotKey.displayString)"))
        } else {
            capture.keyEquivalent = hotKey.menuKeyEquivalent
            capture.keyEquivalentModifierMask = hotKey.menuModifiers
        }

        if pipeline.isWorking {
            menu.addItem(info("Reading screenshot…"))
        } else if let summary = pipeline.lastSummary {
            menu.addItem(info(summary))
        }
        // The same two actions as on the notification, which a Focus mode can hide.
        if let saved = pipeline.lastSaved, !pipeline.isWorking {
            add(saved.events.count == 1 ? "Open Last Event" : "Open Last Events", #selector(openLast), to: menu)
            add(saved.events.count == 1 ? "Undo Last Event" : "Undo Last \(saved.events.count) Events", #selector(undoLast), to: menu)
        }
        if pipeline.lastJSON != nil {
            add("Copy Last Result as JSON", #selector(copyLastJSON), to: menu)
        }

        menu.addItem(.separator())
        // Only the selected service gets a line here.
        switch Preferences.calendarService {
        case .apple:
            if apple.access != .granted {
                add("Allow Calendar Access…", #selector(showPermissions), to: menu)
            }
        case .google:
            switch google.status {
            case .notConfigured: add("Set Up Google Calendar…", #selector(connectGoogle), to: menu)
            case .disconnected: add("Connect Google…", #selector(connectGoogle), to: menu)
            case .needsReconnect: add("Reconnect Google…", #selector(connectGoogle), to: menu)
            case .connecting: menu.addItem(info("Waiting for the Google sign-in…"))
            case .connected: break
            }
        }
        add("Settings…", #selector(showSettings), to: menu).keyEquivalent = ","
        add("Permissions…", #selector(showPermissions), to: menu)
        menu.addItem(.separator())
        menu.addItem(info(Self.versionLine))
        let quit = menu.addItem(withTitle: "Quit ShotCal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
    }

    /// "ShotCal 0.1.0", so a user can say which copy they are running.
    private static var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "ShotCal \(version ?? "(unknown version)")"
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func info(_ text: String) -> NSMenuItem {
        // Menus do not wrap, so keep status lines to a sensible width.
        let shown = text.count > 60 ? text.prefix(59) + "…" : text
        let item = NSMenuItem(title: shown, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func capture() { actions.capture() }
    @objc private func showSettings() { actions.showSettings() }
    @objc private func connectGoogle() { actions.connectGoogle() }

    @objc private func openLast() {
        if let saved = pipeline.lastSaved { actions.open(saved) }
    }

    @objc private func undoLast() {
        if let saved = pipeline.lastSaved { pipeline.undo(saved) }
    }
    @objc private func showPermissions() { actions.showPermissions() }

    @objc private func copyLastJSON() {
        guard let json = pipeline.lastJSON else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }
}
