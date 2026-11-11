import Foundation
import Testing

/// The payload that lets a notification's Open and Undo find their events.
@Suite struct SavedCaptureTests {
    static let first = CreatedEvent(
        id: "evt1", calendarID: "team@group.calendar.google.com",
        htmlLink: URL(string: "https://www.google.com/calendar/event?eid=abc")
    )
    static let second = CreatedEvent(id: "evt2", calendarID: "primary", htmlLink: nil)

    @Test func survivesTheTripThroughANotification() throws {
        let capture = SavedCapture(service: .apple, summary: "Tiimipalaveri \"Q4\" 🎉", events: [Self.first, Self.second])
        let restored = try #require(SavedCapture(encoded: capture.encoded))
        #expect(restored == capture)
        #expect(restored.service == .apple)
        #expect(restored.events.map(\.calendarID) == ["team@group.calendar.google.com", "primary"])
    }

    /// Notifications posted before there was a choice of service.
    @Test func aCaptureThatNamesNoServiceIsFromGoogle() throws {
        let old = #"{"summary":"Lounas","events":[{"id":"evt1","calendarID":"primary"}]}"#
        let restored = try #require(SavedCapture(encoded: old))
        #expect(restored.service == .google)
        #expect(restored.events == [CreatedEvent(id: "evt1", calendarID: "primary", htmlLink: nil)])
    }

    @Test func aCaptureFromAnUnknownServiceIsRejected() {
        #expect(SavedCapture(encoded: #"{"service":"outlook","summary":"x","events":[{"id":"1","calendarID":"c"}]}"#) == nil)
    }

    @Test func opensTheFirstEventThatHasAPageOrElseTheFirst() {
        #expect(SavedCapture(service: .google, summary: "2 events", events: [Self.second, Self.first]).eventToOpen == Self.first)
        #expect(SavedCapture(service: .apple, summary: "x", events: [Self.second]).eventToOpen == Self.second)
    }

    @Test func rejectsPayloadsThatAreNotACapture() {
        #expect(SavedCapture(encoded: "") == nil)
        #expect(SavedCapture(encoded: "not json") == nil)
        #expect(SavedCapture(encoded: #"{"summary":"x"}"#) == nil)
        // Nothing to open or undo.
        #expect(SavedCapture(encoded: #"{"summary":"x","events":[]}"#) == nil)
    }
}
