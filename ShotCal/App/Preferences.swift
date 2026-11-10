import Foundation

/// Non-secret settings, kept in UserDefaults.
enum Preferences {
    enum Key {
        static let modelID = "modelID"
        static let calendarID = "calendarID"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let keepCaptures = "keepCaptures"
        static let captureToFile = "captureToFile"
    }

    static let defaultModelID = "claude-haiku-5-5"

    private static var defaults: UserDefaults { .standard }

    static var modelID: String {
        let stored = defaults.string(forKey: Key.modelID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultModelID : stored
    }

    static let defaultCalendarID = "primary"

    /// "primary" is the signed-in account's main calendar.
    static var calendarID: String {
        let stored = defaults.string(forKey: Key.calendarID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultCalendarID : stored
    }

    static var hotKey: HotKeyCombo {
        get {
            guard defaults.object(forKey: Key.hotKeyCode) != nil else { return .standard }
            return HotKeyCombo(
                keyCode: UInt32(defaults.integer(forKey: Key.hotKeyCode)),
                carbonModifiers: UInt32(defaults.integer(forKey: Key.hotKeyModifiers))
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.hotKeyCode)
            defaults.set(Int(newValue.carbonModifiers), forKey: Key.hotKeyModifiers)
        }
    }

    /// Debugging aid: leave each screenshot in the temp folder and log its
    /// path. `defaults write com.koreneff.ShotCal keepCaptures -bool YES`
    static var keepCaptures: Bool { defaults.bool(forKey: Key.keepCaptures) }

    /// Have screencapture write the PNG itself instead of going through the
    /// clipboard. Off by default because that path can stall for a minute when
    /// Spotlight is slow. `defaults write com.koreneff.ShotCal captureToFile -bool YES`
    static var captureToFile: Bool { defaults.bool(forKey: Key.captureToFile) }
}
