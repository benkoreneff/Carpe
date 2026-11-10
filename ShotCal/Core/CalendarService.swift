import Foundation

/// A calendar entry that was created, with what is needed to open or undo it.
struct CreatedEvent: Equatable, Sendable, Codable {
    var id: String
    var calendarID: String
    /// The event's page in the calendar's web UI, when there is one.
    var htmlLink: URL?
}

/// What one capture put in the calendar. It travels inside the notification,
/// so Open and Undo still work after ShotCal has been relaunched.
struct SavedCapture: Equatable, Sendable, Codable {
    /// The event's title, or "3 events".
    var summary: String
    var events: [CreatedEvent]

    /// What Open shows: the first event that has a page.
    var linkToOpen: URL? { events.lazy.compactMap(\.htmlLink).first }

    /// Notification payloads only hold property-list values, so the capture
    /// goes in as a JSON string.
    var encoded: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    init(summary: String, events: [CreatedEvent]) {
        self.summary = summary
        self.events = events
    }

    init?(encoded: String) {
        guard let capture = try? JSONDecoder().decode(SavedCapture.self, from: Data(encoded.utf8)),
              !capture.events.isEmpty
        else { return nil }
        self = capture
    }
}

/// Where extracted events end up: `GoogleCalendarService` once Google is
/// connected, `StubCalendarService` until then.
protocol CalendarService {
    /// False for a service that only pretends, so the UI can say "not saved".
    var savesEvents: Bool { get }
    /// Checks that saving can work, before any other work is done.
    func prepare() async throws
    func insert(_ event: ResolvedEvent) async throws -> CreatedEvent
    func delete(_ event: CreatedEvent) async throws
}

/// Creates nothing. The pipeline still runs end to end, and the notification
/// shows what would have been added.
struct StubCalendarService: CalendarService {
    let savesEvents = false

    func prepare() async throws {}

    func insert(_ event: ResolvedEvent) async throws -> CreatedEvent {
        CreatedEvent(id: "stub-\(UUID().uuidString)", calendarID: "stub", htmlLink: nil)
    }

    func delete(_ event: CreatedEvent) async throws {}
}
