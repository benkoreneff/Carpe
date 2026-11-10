import AppKit
import CoreGraphics

enum Permissions {
    /// Whether ShotCal may capture other apps' windows. `screencapture` runs as
    /// a child of ShotCal, so macOS checks ShotCal's grant, not Terminal's.
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt once and adds ShotCal to the Screen Recording
    /// list in System Settings, where it can then be switched on.
    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")
    }

    /// macOS only applies a new Screen Recording grant to a fresh process.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }
}
