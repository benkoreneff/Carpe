import Foundation

/// The calendar services Carpe can save to. The raw value is what is stored
/// in UserDefaults and inside notifications.
enum CalendarServiceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple
    case google

    var id: Self { self }

    var displayName: String {
        switch self {
        case .apple: "Apple Calendar"
        case .google: "Google Calendar"
        }
    }
}

/// A calendar that events can be added to.
struct CalendarInfo: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    /// The account the calendar belongs to ("iCloud", "Google"), when known.
    var account: String?
    /// "#RRGGBB", when the service gives the calendar a colour.
    var colorHex: String?
    /// Where an event goes when no calendar is named.
    var isDefault = false
}

/// A calendar entry that was created, with what is needed to open or undo it.
struct CreatedEvent: Equatable, Sendable, Codable {
    var id: String
    var calendarID: String
    /// The event's page in the calendar's web UI, when there is one.
    var htmlLink: URL?
}

/// What one capture put in the calendar. It travels inside the notification,
/// so Open and Undo still work after Carpe has been relaunched.
struct SavedCapture: Equatable, Sendable, Codable {
    /// Where the events were saved, which is not always the service that is
    /// selected by the time Open or Undo is used.
    var service: CalendarServiceKind
    /// The event's title, or "3 events".
    var summary: String
    var events: [CreatedEvent]

    /// What Open shows: the first event that has a page, or else the first.
    var eventToOpen: CreatedEvent? { events.first { $0.htmlLink != nil } ?? events.first }

    /// Notification payloads only hold property-list values, so the capture
    /// goes in as a JSON string.
    var encoded: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    init(service: CalendarServiceKind, summary: String, events: [CreatedEvent]) {
        self.service = service
        self.summary = summary
        self.events = events
    }

    init?(encoded: String) {
        guard let capture = try? JSONDecoder().decode(SavedCapture.self, from: Data(encoded.utf8)),
              !capture.events.isEmpty
        else { return nil }
        self = capture
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Notifications from before Apple Calendar support name no service.
        service = try c.decodeIfPresent(CalendarServiceKind.self, forKey: .service) ?? .google
        summary = try c.decode(String.self, forKey: .summary)
        events = try c.decode([CreatedEvent].self, forKey: .events)
    }
}

/// Everything Carpe does with a calendar. `AppleCalendarService` and
/// `GoogleCalendarService` are the real ones; `StubCalendarService` stands in
/// for Google until it is connected.
protocol CalendarService {
    /// False for a service that only pretends, so the UI can say "not saved".
    var savesEvents: Bool { get }
    /// Checks that saving can work, before any other work is done.
    func prepare() async throws
    /// The calendars that events can be added to.
    func calendars() async throws -> [CalendarInfo]
    /// Creates the event. Without a calendar ID it goes to the service's default.
    func insert(_ event: ResolvedEvent, into calendarID: String?) async throws -> CreatedEvent
    func delete(_ event: CreatedEvent) async throws
    /// Shows the event in the service's own calendar app or page.
    func open(_ event: CreatedEvent)
}

/// Creates nothing. The pipeline still runs end to end, and the notification
/// shows what would have been added.
struct StubCalendarService: CalendarService {
    let savesEvents = false

    func prepare() async throws {}

    func calendars() async throws -> [CalendarInfo] { [] }

    func insert(_ event: ResolvedEvent, into calendarID: String?) async throws -> CreatedEvent {
        CreatedEvent(id: "stub-\(UUID().uuidString)", calendarID: calendarID ?? "stub", htmlLink: nil)
    }

    func delete(_ event: CreatedEvent) async throws {}

    func open(_ event: CreatedEvent) {}
}
