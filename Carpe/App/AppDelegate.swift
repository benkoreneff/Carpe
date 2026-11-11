import AppKit
import os
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.koreneff.carpe", category: "app")

    private let notifier = Notifier()
    private let windows = WindowPresenter()
    private let google = GoogleAccount(store: KeychainStore(), openURL: { NSWorkspace.shared.open($0) })
    private let apple = AppleCalendarService(openURL: { NSWorkspace.shared.open($0) })
    private lazy var pipeline = Pipeline(calendar: { [unowned self] in calendar($0) }, notifier: notifier)
    private let calendarPicker = CalendarPicker()
    private var statusItem: StatusItemController?
    private lazy var hotKeys = HotKeyCenter { [weak self] in self?.pipeline.trigger() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Google was the only service before there was a choice, so a Mac
        // where it is already set up keeps using it without being asked.
        if Preferences.chosenCalendarService == nil, google.status != .notConfigured {
            Preferences.chosenCalendarService = .google
        }

        installEditMenu()
        notifier.activate()

        notifier.onOpen = { [weak self] in self?.open($0) }
        notifier.onUndo = { [weak self] in self?.pipeline.undo($0) }

        Self.log.info("Hotkey \(self.hotKeys.combo.displayString, privacy: .public) registered: \(self.hotKeys.isRegistered)")

        let statusItem = StatusItemController(
            pipeline: pipeline,
            google: google,
            apple: apple,
            hotKeys: hotKeys,
            actions: .init(
                capture: { [weak self] in self?.pipeline.trigger() },
                showSettings: { [weak self] in self?.showSettings() },
                connectGoogle: { [weak self] in self?.connectGoogle() },
                open: { [weak self] in self?.open($0) },
                showPermissions: { [weak self] in self?.showPermissions() }
            )
        )
        self.statusItem = statusItem

        pipeline.onChange = { [weak statusItem] in statusItem?.refresh() }
        pipeline.onNeedsScreenRecording = { [weak self] in self?.showPermissions() }
        pipeline.onNeedsAPIKey = { [weak self] in self?.showSettings() }
        pipeline.onNeedsCalendarAccess = { [weak self] in self?.showPermissions() }
        pipeline.chooseCalendar = { [calendarPicker] in await calendarPicker.choose($0) }

        Task { await showPermissionsIfNeeded() }
    }

    // MARK: - Calendars

    private var googleCalendar: GoogleCalendarService {
        GoogleCalendarService(
            accessToken: { [google] in try await google.accessToken(forceRefresh: $0) },
            openURL: { NSWorkspace.shared.open($0) }
        )
    }

    /// The service that saves and deletes events of the given kind.
    private func calendar(_ kind: CalendarServiceKind) -> CalendarService {
        switch kind {
        case .apple:
            return apple
        case .google:
            // Until Google is set up, a run ends in a preview instead of an error.
            switch google.status {
            case .notConfigured, .disconnected, .connecting: return StubCalendarService()
            case .connected, .needsReconnect: return googleCalendar
            }
        }
    }

    /// Shows the event in Calendar or on its Google Calendar page. A capture
    /// with several events opens the first one.
    private func open(_ capture: SavedCapture) {
        guard let event = capture.eventToOpen else { return }
        switch capture.service {
        case .apple: apple.open(event)
        // A page opens in the browser whether or not Google is connected here.
        case .google: googleCalendar.open(event)
        }
    }

    // MARK: - Google

    /// The menu's Connect and Reconnect. Settings has its own button, which
    /// shows the result in the window instead.
    private func connectGoogle() {
        guard google.status != .notConfigured else { return showSettings() }
        Task {
            do {
                try await google.connect()
                notifier.post(title: "Google Calendar connected", body: "New captures are saved to your calendar.")
            } catch is CancellationError {
            } catch {
                notifier.post(title: "Couldn't connect Google Calendar", body: error.localizedDescription)
            }
        }
    }

    // MARK: - Windows

    private func showSettings() {
        windows.show(id: "settings", title: "Carpe Settings") {
            SettingsView(
                google: google, apple: apple, hotKeys: hotKeys,
                googleCalendars: { [googleCalendar] in try await googleCalendar.calendars() }
            )
        }
    }

    private func showPermissions() {
        windows.show(id: "permissions", title: "Welcome to Carpe") {
            PermissionsView(
                notifier: notifier, apple: apple, google: google,
                showSettings: { [weak self] in self?.showSettings() }
            )
        }
    }

    /// First run, or a permission was taken away since: walk through them.
    private func showPermissionsIfNeeded() async {
        let notifications = await notifier.authorizationStatus()
        let calendarNeedsSetup = Preferences.chosenCalendarService == nil
            || (Preferences.calendarService == .apple && apple.access != .granted)
        if !Permissions.hasScreenRecording || notifications == .notDetermined || calendarNeedsSetup {
            showPermissions()
        }
    }

    // MARK: - Menu

    /// An accessory app has no visible menu bar, but text fields only get
    /// Cmd-V, Cmd-C and friends through an Edit menu, so install one anyway.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let main = NSMenu()
        for submenu in [NSMenu(title: "Carpe"), edit, window] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }
}
