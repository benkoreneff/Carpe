import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A button that shows the capture shortcut and records a new one when
/// clicked. Keys are read with a local event monitor, which only sees this
/// app's own windows, so no Accessibility permission is involved.
struct ShortcutRecorder: View {
    let hotKeys: HotKeyCenter
    @Binding var message: String?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(isRecording ? "Type a shortcut…" : hotKeys.combo.displayString) {
                isRecording ? stop() : start()
            }
            if isRecording {
                Button("Cancel", action: stop)
            } else if hotKeys.combo != .standard {
                Button("Reset") { apply(.standard) }
            }
        }
        .onDisappear(perform: stop)
        // Recording must not outlive the window's focus: the global shortcut
        // is switched off for as long as it runs.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private func start() {
        message = "Press the new shortcut, with at least one of ⌃ ⌥ ⌘. Esc cancels."
        isRecording = true
        hotKeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil // the key belongs to the recorder, not to the window
        }
    }

    private func stop() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        hotKeys.resume()
        if message?.hasPrefix("Press the new shortcut") == true { message = nil }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
        if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty { return stop() }
        guard let combo = HotKeyCombo(event: event) else { return } // keep waiting
        stop()
        apply(combo)
    }

    private func apply(_ combo: HotKeyCombo) {
        if hotKeys.change(to: combo) {
            message = nil
        } else {
            message = "\(combo.displayString) is taken by another app. The shortcut is still \(hotKeys.combo.displayString)."
        }
    }
}
