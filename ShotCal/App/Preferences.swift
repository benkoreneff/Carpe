import Foundation

/// Non-secret settings, kept in UserDefaults.
enum Preferences {
    enum Key {
        static let modelID = "modelID"
        static let calendarService = "calendarService"
        static let calendarID = "calendarID"
        static let appleCalendarID = "appleCalendarID"
        static let askForCalendar = "askForCalendar"
        static let lastCalendarID = "lastCalendarID"
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

    /// The service the user picked, or nil while nobody has been asked.
    static var chosenCalendarService: CalendarServiceKind? {
        get { defaults.string(forKey: Key.calendarService).flatMap(CalendarServiceKind.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: Key.calendarService) }
    }

    /// Where events go. Apple Calendar until something else is chosen: it
    /// needs no account setup, only a permission.
    static var calendarService: CalendarServiceKind { chosenCalendarService ?? .apple }

    static let defaultCalendarID = GoogleCalendarService.primaryCalendarID

    /// The Google calendar. "primary" is the signed-in account's main calendar.
    static var calendarID: String {
        let stored = defaults.string(forKey: Key.calendarID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultCalendarID : stored
    }

    /// The Apple calendar picked in Settings, or nil for the Calendar app's
    /// own default.
    static var appleCalendarID: String? {
        let stored = defaults.string(forKey: Key.appleCalendarID) ?? ""
        return stored.isEmpty ? nil : stored
    }

    /// The calendar new events go to. Each service keeps its own, since the
    /// IDs mean nothing to the other one.
    static func calendarID(for service: CalendarServiceKind) -> String? {
        switch service {
        case .apple: appleCalendarID
        case .google: calendarID
        }
    }

    /// Show the calendar picker after every capture instead of using the default.
    static var askForCalendar: Bool { defaults.bool(forKey: Key.askForCalendar) }

    /// The calendar picked the last time ShotCal asked, per service.
    static func lastCalendarID(for service: CalendarServiceKind) -> String? {
        defaults.string(forKey: "\(Key.lastCalendarID).\(service.rawValue)")
    }

    static func setLastCalendarID(_ id: String, for service: CalendarServiceKind) {
        defaults.set(id, forKey: "\(Key.lastCalendarID).\(service.rawValue)")
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
