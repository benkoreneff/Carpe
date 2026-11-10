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
        let capture = SavedCapture(summary: "Tiimipalaveri \"Q4\" 🎉", events: [Self.first, Self.second])
        let restored = try #require(SavedCapture(encoded: capture.encoded))
        #expect(restored == capture)
        #expect(restored.events.map(\.calendarID) == ["team@group.calendar.google.com", "primary"])
    }

    @Test func opensTheFirstEventThatHasAPage() {
        #expect(SavedCapture(summary: "2 events", events: [Self.second, Self.first]).linkToOpen == Self.first.htmlLink)
        #expect(SavedCapture(summary: "x", events: [Self.second]).linkToOpen == nil)
    }

    @Test func rejectsPayloadsThatAreNotACapture() {
        #expect(SavedCapture(encoded: "") == nil)
        #expect(SavedCapture(encoded: "not json") == nil)
        #expect(SavedCapture(encoded: #"{"summary":"x"}"#) == nil)
        // Nothing to open or undo.
        #expect(SavedCapture(encoded: #"{"summary":"x","events":[]}"#) == nil)
    }
}
