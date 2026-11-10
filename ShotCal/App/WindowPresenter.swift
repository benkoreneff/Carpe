import AppKit
import SwiftUI

/// Shows SwiftUI views in ordinary windows. A menu bar app has no window
/// scenes that can be opened from an AppKit menu, so the windows are made here.
final class WindowPresenter {
    private var windows: [String: NSWindow] = [:]
    private var closeObservers: [String: NSObjectProtocol] = [:]

    func show<Content: View>(id: String, title: String, @ViewBuilder content: () -> Content) {
        let window = windows[id] ?? {
            let host = NSHostingController(rootView: content())
            // Let the window follow the view when a status line appears.
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = title
            window.styleMask = [.titled, .closable]
            window.setContentSize(host.view.fittingSize)
            window.isReleasedWhenClosed = false
            window.center()
            windows[id] = window
            // Drop the window when it closes, so its view stops any timers and
            // the next opening shows fresh state.
            closeObservers[id] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.forget(id) }
            }
            return window
        }()

        // An accessory app is never frontmost by itself, so bring it forward
        // or the window opens behind whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func forget(_ id: String) {
        if let observer = closeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        // Released on the next turn of the run loop, after the close finishes.
        if let window = windows.removeValue(forKey: id) {
            Task { window.contentViewController = nil }
        }
    }
}
