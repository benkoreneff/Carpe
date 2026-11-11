import CoreGraphics
import EventKit
import Foundation

/// What macOS currently lets ShotCal do with the user's calendars.
enum AppleCalendarAccess: Equatable, Sendable {
    /// The system prompt hasn't been shown yet.
    case notDetermined
    case granted
    /// "Add Only": events can be created, but calendars can't be listed and
    /// nothing can be deleted, so it isn't enough.
    case addOnly
    case denied
    /// Blocked by a profile or parental controls; the user can't change it.
    case restricted
}

enum AppleCalendarError: LocalizedError, Equatable {
    case accessDenied
    case addOnlyAccess
    case accessRestricted
    case calendarNotFound
    case calendarReadOnly(String)
    case noWritableCalendar
    case saveFailed(String)
    case deleteFailed(String)

    /// True when the fix is in System Settings > Privacy & Security > Calendars.
    var isAccessProblem: Bool {
        switch self {
        case .accessDenied, .addOnlyAccess, .accessRestricted: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "ShotCal doesn't have access to your calendars. Allow it in System Settings > Privacy & Security > Calendars."
        case .addOnlyAccess:
            "ShotCal can only add events, which isn't enough to list calendars or undo. "
                + "Give it Full Access in System Settings > Privacy & Security > Calendars."
        case .accessRestricted:
            "Calendar access is restricted on this Mac, so ShotCal can't use Apple Calendar."
        case .calendarNotFound:
            "The calendar chosen in Settings no longer exists. Choose another one in Settings."
        case .calendarReadOnly(let title):
            "The calendar \"\(title)\" can't be changed. Choose another one in Settings."
        case .noWritableCalendar:
            "Apple Calendar has no calendar that events can be added to."
        case .saveFailed(let reason):
            "Apple Calendar couldn't save the event: \(reason)"
        case .deleteFailed(let reason):
            "Apple Calendar couldn't remove the event: \(reason)"
        }
    }
}

/// Creates and deletes events in the calendars of the Calendar app, through
/// EventKit. That covers every account set up there: iCloud, Exchange, Google.
///
/// Needs full access: listing calendars and deleting for Undo both read the
/// store, which "Add Only" access doesn't allow.
final class AppleCalendarService: CalendarService {
    let savesEvents = true

    private var store = EKEventStore()
    /// Whether `store` was created after access was granted.
    private var storeHasAccess: Bool
    private let openURL: (URL) -> Void

    init(openURL: @escaping (URL) -> Void) {
        self.openURL = openURL
        storeHasAccess = Self.currentAccess == .granted
    }

    // MARK: - Access

    var access: AppleCalendarAccess { Self.currentAccess }

    private static var currentAccess: AppleCalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .fullAccess: .granted
        case .writeOnly: .addOnly
        case .restricted: .restricted
        default: .denied
        }
    }

    /// Shows the system prompt the first time. Afterwards it only reports the
    /// existing answer, and a denial has to be reversed in System Settings.
    @discardableResult
    func requestAccess() async -> AppleCalendarAccess {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            store.requestFullAccessToEvents { _, _ in done.resume() }
        }
        return access
    }

    /// Asks for access if that hasn't happened yet, then fails early, before a
    /// screenshot is sent anywhere, if events couldn't be saved.
    func prepare() async throws {
        if access == .notDetermined || access == .addOnly {
            await requestAccess()
        }
        _ = try authorizedStore()
    }

    private func authorizedStore() throws -> EKEventStore {
        switch access {
        case .granted: break
        case .notDetermined, .denied: throw AppleCalendarError.accessDenied
        case .addOnly: throw AppleCalendarError.addOnlyAccess
        case .restricted: throw AppleCalendarError.accessRestricted
        }
        // A store from before the grant keeps seeing no calendars.
        if !storeHasAccess {
            store = EKEventStore()
            storeHasAccess = true
        }
        return store
    }

    // MARK: - Calendars

    /// Only calendars that allow modifications: no subscriptions, birthdays
    /// or read-only shares.
    func calendars() async throws -> [CalendarInfo] {
        let store = try authorizedStore()
        let writable = Self.writableCalendars(in: store)
        let fallback = Self.defaultCalendar(in: store, among: writable)?.calendarIdentifier
        return writable.map { calendar in
            CalendarInfo(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                account: calendar.source?.title,
                colorHex: Self.hex(calendar.cgColor),
                isDefault: calendar.calendarIdentifier == fallback
            )
        }
    }

    private static func writableCalendars(in store: EKEventStore) -> [EKCalendar] {
        store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted {
                let accounts = ($0.source?.title ?? "").localizedStandardCompare($1.source?.title ?? "")
                if accounts != .orderedSame { return accounts == .orderedAscending }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    /// The calendar chosen as the default in the Calendar app's settings,
    /// unless it is read-only.
    private static func defaultCalendar(in store: EKEventStore, among writable: [EKCalendar]) -> EKCalendar? {
        if let preferred = store.defaultCalendarForNewEvents, preferred.allowsContentModifications {
            return preferred
        }
        return writable.first
    }

    private func target(_ calendarID: String?, in store: EKEventStore) throws -> EKCalendar {
        guard let calendarID else {
            guard let calendar = Self.defaultCalendar(in: store, among: Self.writableCalendars(in: store)) else {
                throw AppleCalendarError.noWritableCalendar
            }
            return calendar
        }
        guard let calendar = store.calendar(withIdentifier: calendarID) else {
            throw AppleCalendarError.calendarNotFound
        }
        guard calendar.allowsContentModifications else {
            throw AppleCalendarError.calendarReadOnly(calendar.title)
        }
        return calendar
    }

    // MARK: - Events

    func insert(_ event: ResolvedEvent, into calendarID: String?) async throws -> CreatedEvent {
        let store = try authorizedStore()
        let calendar = try target(calendarID, in: store)

        let item = EKEvent(eventStore: store)
        item.calendar = calendar
        item.title = event.title
        item.location = event.location
        item.notes = event.notes
        item.isAllDay = event.isAllDay
        let span = Self.span(for: event)
        item.startDate = span.start
        item.endDate = span.end
        if !event.isAllDay { item.timeZone = event.timeZone }

        do {
            try store.save(item, span: .thisEvent, commit: true)
        } catch {
            throw AppleCalendarError.saveFailed(error.localizedDescription)
        }
        guard let id = item.eventIdentifier else {
            throw AppleCalendarError.saveFailed("the event got no identifier.")
        }
        return CreatedEvent(id: id, calendarID: calendar.calendarIdentifier, htmlLink: nil)
    }

    func delete(_ event: CreatedEvent) async throws {
        let store = try authorizedStore()
        // Not found: already deleted in Calendar, which is what was wanted.
        guard let item = store.event(withIdentifier: event.id) else { return }
        do {
            try store.remove(item, span: .thisEvent, commit: true)
        } catch {
            throw AppleCalendarError.deleteFailed(error.localizedDescription)
        }
    }

    /// Shows the event in Calendar, which moves the view to its date. If the
    /// event is gone, Calendar just opens.
    func open(_ event: CreatedEvent) {
        let item = (try? authorizedStore())?.event(withIdentifier: event.id)
        openURL(Self.showURL(itemIdentifier: item?.calendarItemIdentifier))
    }

    // MARK: - Conversions

    /// The start and end to give EventKit. Timed events pass through.
    ///
    /// All-day events differ from `ResolvedEvent` in two ways: EventKit's end
    /// is the last moment of the last day, not the midnight after it, and the
    /// days are read in the Mac's time zone, not the event's.
    static func span(for event: ResolvedEvent, systemTimeZone: TimeZone = .current) -> (start: Date, end: Date) {
        guard event.isAllDay else { return (event.start, event.end) }

        var source = Calendar(identifier: .gregorian)
        source.timeZone = event.timeZone
        var system = Calendar(identifier: .gregorian)
        system.timeZone = systemTimeZone

        func midnight(_ date: Date) -> Date {
            system.date(from: source.dateComponents([.year, .month, .day], from: date)) ?? date
        }
        let start = midnight(event.start)
        let end = midnight(event.end).addingTimeInterval(-1)
        return (start, max(start, end))
    }

    /// The link Calendar itself uses to show one event. Without an identifier
    /// the link only brings Calendar to the front.
    static func showURL(itemIdentifier: String?) -> URL {
        let calendarApp = URL(string: "ical://")!
        guard let itemIdentifier,
              let escaped = itemIdentifier.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-")))
        else { return calendarApp }
        return URL(string: "ical://ekevent/\(escaped)?method=show&options=more") ?? calendarApp
    }

    /// "#RRGGBB" in sRGB.
    static func hex(_ color: CGColor?) -> String? {
        guard let color,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let parts = converted.components, parts.count >= 3
        else { return nil }
        let bytes = parts.prefix(3).map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }
}
