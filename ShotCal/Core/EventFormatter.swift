import Foundation

/// Human-readable date lines for notifications and the menu.
enum EventFormatter {
    /// "17 Nov 2026 at 14.00 – 15.00", "24 Dec 2026", "3 – 5 Jul 2027".
    static func when(_ event: ResolvedEvent, locale: Locale = .current) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.timeZone = event.timeZone
        formatter.dateStyle = .medium

        guard event.isAllDay else {
            formatter.timeStyle = .short
            return formatter.string(from: event.start, to: event.end)
        }

        formatter.timeStyle = .none
        // The stored end is exclusive; show the last day the event covers.
        let lastDay = event.end.addingTimeInterval(-1)
        return formatter.string(from: event.start, to: lastDay)
    }

    /// One line per event, for a notification body.
    static func line(_ event: ResolvedEvent, locale: Locale = .current) -> String {
        "\(when(event, locale: locale)): \(event.title)"
    }
}
