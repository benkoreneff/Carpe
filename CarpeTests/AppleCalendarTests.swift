import CoreGraphics
import Foundation
import Testing

/// The parts of the Apple Calendar service that don't touch the calendar
/// store. Anything that does would ask for the calendar permission.
@Suite struct AppleCalendarServiceTests {
    static let helsinki = TimeZone(identifier: "Europe/Helsinki")!
    static let newYork = TimeZone(identifier: "America/New_York")!

    static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @Test func timedEventsKeepTheirInstants() {
        let event = ResolvedEvent(
            title: "Tiimipalaveri", start: Self.date("2026-11-17T12:00:00Z"), end: Self.date("2026-11-17T13:00:00Z"),
            isAllDay: false, timeZone: Self.helsinki
        )
        let span = AppleCalendarService.span(for: event, systemTimeZone: Self.newYork)
        #expect(span.start == event.start)
        #expect(span.end == event.end)
    }

    /// EventKit wants the last second of the last day, not the next midnight.
    @Test func allDayEventEndsOnItsLastDay() {
        // 24 Dec 2026 in Helsinki (UTC+2).
        let event = ResolvedEvent(
            title: "Jouluaatto", start: Self.date("2026-12-23T22:00:00Z"), end: Self.date("2026-12-24T22:00:00Z"),
            isAllDay: true, timeZone: Self.helsinki
        )
        let span = AppleCalendarService.span(for: event, systemTimeZone: Self.helsinki)
        #expect(span.start == Self.date("2026-12-23T22:00:00Z"))
        #expect(span.end == Self.date("2026-12-24T21:59:59Z"))
    }

    @Test func aMultiDayEventCoversEveryDay() {
        // 3–5 Jul 2027 in Helsinki (UTC+3): the exclusive end is 6 Jul.
        let event = ResolvedEvent(
            title: "Festari", start: Self.date("2027-07-02T21:00:00Z"), end: Self.date("2027-07-05T21:00:00Z"),
            isAllDay: true, timeZone: Self.helsinki
        )
        let span = AppleCalendarService.span(for: event, systemTimeZone: Self.helsinki)
        #expect(span.start == Self.date("2027-07-02T21:00:00Z"))
        #expect(span.end == Self.date("2027-07-05T20:59:59Z"))
    }

    /// The same calendar day, wherever the Mac is.
    @Test func allDayDatesAreReadInTheMacsTimeZone() {
        let event = ResolvedEvent(
            title: "Jouluaatto", start: Self.date("2026-12-23T22:00:00Z"), end: Self.date("2026-12-24T22:00:00Z"),
            isAllDay: true, timeZone: Self.helsinki
        )
        let span = AppleCalendarService.span(for: event, systemTimeZone: Self.newYork)
        // 24 Dec in New York (UTC-5).
        #expect(span.start == Self.date("2026-12-24T05:00:00Z"))
        #expect(span.end == Self.date("2026-12-25T04:59:59Z"))
    }

    @Test func showLinkNamesTheEvent() {
        #expect(AppleCalendarService.showURL(itemIdentifier: "8A3B6C1E-0F2D-4B7A-9C55-1D2E3F4A5B6C").absoluteString ==
            "ical://ekevent/8A3B6C1E-0F2D-4B7A-9C55-1D2E3F4A5B6C?method=show&options=more")
        #expect(AppleCalendarService.showURL(itemIdentifier: "a/b?c").absoluteString ==
            "ical://ekevent/a%2Fb%3Fc?method=show&options=more")
    }

    @Test func withoutAnEventTheLinkOnlyOpensCalendar() {
        #expect(AppleCalendarService.showURL(itemIdentifier: nil).absoluteString == "ical://")
    }

    @Test func calendarColoursBecomeHex() {
        #expect(AppleCalendarService.hex(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)) == "#FF8000")
        #expect(AppleCalendarService.hex(CGColor(gray: 1, alpha: 1)) == "#FFFFFF")
        #expect(AppleCalendarService.hex(nil) == nil)
    }

    @Test func onlyAccessProblemsPointToSystemSettings() {
        #expect(AppleCalendarError.accessDenied.isAccessProblem)
        #expect(AppleCalendarError.addOnlyAccess.isAccessProblem)
        #expect(!AppleCalendarError.calendarNotFound.isAccessProblem)
        #expect(!AppleCalendarError.saveFailed("x").isAccessProblem)
    }
}
