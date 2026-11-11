import Foundation
import ServiceManagement

/// Launch at login through SMAppService. macOS lists the app under
/// System Settings > General > Login Items, where the user can also turn it off.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registered, but switched off or not yet allowed in System Settings.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The login item is this copy of the app. One inside a build folder
    /// disappears with the next `make clean`.
    static var runsFromApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
            || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}
