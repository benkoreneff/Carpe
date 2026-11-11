import Foundation

enum GoogleCalendarError: LocalizedError, Equatable {
    case calendarNotFound(String)
    /// The sign-in lacks the calendar list scope: it predates the picker, or
    /// that box was unticked on Google's consent screen.
    case calendarListNotAllowed
    case api(status: Int, message: String)
    case unreadableReply

    var errorDescription: String? {
        switch self {
        case .calendarNotFound(let id):
            "Google has no calendar with the ID \"\(id)\" for this account. Check the calendar ID in Settings."
        case .calendarListNotAllowed:
            "This Google sign-in doesn't let Carpe see your list of calendars. "
                + "In Settings, click Disconnect and then Connect Google, and leave every box ticked."
        case .api(403, let message):
            "Google Calendar refused the request: \(message)"
        case .api(let status, _) where status >= 500:
            "Google Calendar is having trouble (HTTP \(status)). Try again in a moment."
        case .api(let status, let message):
            "Google Calendar returned an error (HTTP \(status)): \(message)"
        case .unreadableReply:
            "Google Calendar's answer couldn't be read."
        }
    }
}

/// Lists calendars and creates and deletes events with the Calendar API v3
/// over plain URLSession.
/// https://developers.google.com/workspace/calendar/api/v3/reference
struct GoogleCalendarService: CalendarService {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    static let base = "https://www.googleapis.com/calendar/v3"
    /// The signed-in account's main calendar.
    static let primaryCalendarID = "primary"
    static let webCalendar = URL(string: "https://calendar.google.com/")!

    /// Returns an access token; the argument asks for a fresh one.
    var accessToken: (_ forceRefresh: Bool) async throws -> String
    var transport: Transport = { try await URLSession.shared.data(for: $0) }
    var openURL: (URL) -> Void = { _ in }

    let savesEvents = true

    /// Fails early, before a screenshot is sent anywhere, if the sign-in is gone.
    func prepare() async throws {
        _ = try await accessToken(false)
    }

    /// The calendars the account can add events to, the main one first.
    /// https://developers.google.com/workspace/calendar/api/v3/reference/calendarList/list
    func calendars() async throws -> [CalendarInfo] {
        struct Reply: Decodable {
            struct Item: Decodable {
                var id: String
                var summary: String?
                /// The name the user gave a calendar that someone else owns.
                var summaryOverride: String?
                var backgroundColor: String?
                var primary: Bool?
            }
            var items: [Item]?
            var nextPageToken: String?
        }

        var found: [CalendarInfo] = []
        var pageToken: String?
        repeat {
            let request = URLRequest(url: Self.calendarListURL(pageToken: pageToken), timeoutInterval: 30)
            let (status, data) = try await send(request)
            guard status == 200 else {
                throw Self.meansScopeIsMissing(status, data) ? GoogleCalendarError.calendarListNotAllowed : failure(status, data)
            }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
                throw GoogleCalendarError.unreadableReply
            }
            found += (reply.items ?? []).map {
                CalendarInfo(
                    id: $0.id, title: $0.summaryOverride ?? $0.summary ?? $0.id,
                    colorHex: $0.backgroundColor?.uppercased(), isDefault: $0.primary ?? false
                )
            }
            pageToken = reply.nextPageToken
        } while pageToken != nil

        return found.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func insert(_ event: ResolvedEvent, into calendarID: String?) async throws -> CreatedEvent {
        struct Reply: Decodable {
            var id: String
            var htmlLink: String?
        }

        let calendarID = calendarID ?? Self.primaryCalendarID
        var request = URLRequest(url: Self.eventsURL(calendarID: calendarID), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: event))

        let (status, data) = try await send(request)
        guard status == 200 else { throw failure(status, data, calendarID: calendarID) }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw GoogleCalendarError.unreadableReply
        }
        return CreatedEvent(id: reply.id, calendarID: calendarID, htmlLink: reply.htmlLink.flatMap(URL.init(string:)))
    }

    func delete(_ event: CreatedEvent) async throws {
        var request = URLRequest(url: Self.eventsURL(calendarID: event.calendarID, eventID: event.id), timeoutInterval: 30)
        request.httpMethod = "DELETE"

        let (status, data) = try await send(request)
        // 404 and 410: the event is already gone, which is what was wanted.
        guard [200, 204, 404, 410].contains(status) else { throw failure(status, data, calendarID: event.calendarID) }
    }

    /// Shows the event's page in the browser, or Google Calendar itself when
    /// the event has no page.
    func open(_ event: CreatedEvent) {
        openURL(event.htmlLink ?? Self.webCalendar)
    }

    // MARK: - Request building

    /// Only calendars the account can write to, 250 per page (Google's maximum).
    static func calendarListURL(pageToken: String? = nil) -> URL {
        var fields = [("minAccessRole", "writer"), ("maxResults", "250")]
        if let pageToken { fields.append(("pageToken", pageToken)) }
        return URL(string: "\(base)/users/me/calendarList?\(GoogleOAuth.formEncoded(fields))")!
    }

    static func eventsURL(calendarID: String, eventID: String? = nil) -> URL {
        var path = "\(base)/calendars/\(GoogleOAuth.escape(calendarID))/events"
        if let eventID { path += "/\(GoogleOAuth.escape(eventID))" }
        return URL(string: path)!
    }

    /// The event resource. Timed events carry the local time with its UTC
    /// offset plus the zone's name; all-day events carry plain dates, with the
    /// end date exclusive.
    static func body(for event: ResolvedEvent) -> [String: Any] {
        var body: [String: Any] = ["summary": event.title]
        if let location = event.location { body["location"] = location }
        if let notes = event.notes { body["description"] = notes }

        if event.isAllDay {
            body["start"] = ["date": day(event.start, in: event.timeZone)]
            body["end"] = ["date": day(event.end, in: event.timeZone)]
        } else {
            let zone = event.timeZone.identifier
            body["start"] = ["dateTime": instant(event.start, in: event.timeZone), "timeZone": zone]
            body["end"] = ["dateTime": instant(event.end, in: event.timeZone), "timeZone": zone]
        }
        return body
    }

    /// RFC 3339 with the zone's offset, e.g. 2026-11-17T14:00:00+02:00.
    static func instant(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    static func day(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Transport

    /// Sends with a bearer token. If Google says the token is no good, gets a
    /// fresh one and tries once more.
    private func send(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        var request = request
        request.setValue("Bearer \(try await accessToken(false))", forHTTPHeaderField: "Authorization")
        var (data, response) = try await transport(request)

        if (response as? HTTPURLResponse)?.statusCode == 401 {
            request.setValue("Bearer \(try await accessToken(true))", forHTTPHeaderField: "Authorization")
            (data, response) = try await transport(request)
        }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// A 403 that is about the token's scopes, not about the API being
    /// switched off or a quota.
    static func meansScopeIsMissing(_ status: Int, _ data: Data) -> Bool {
        struct ErrorReply: Decodable {
            struct Detail: Decodable {
                struct Item: Decodable { var reason: String? }
                var message: String?
                var status: String?
                var errors: [Item]?
                var details: [Item]?
            }
            var error: Detail
        }
        guard status == 403, let error = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error else {
            return false
        }
        let reasons = ((error.errors ?? []) + (error.details ?? [])).compactMap(\.reason)
        return reasons.contains("insufficientPermissions")
            || reasons.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT")
            || (error.message ?? "").localizedCaseInsensitiveContains("insufficient authentication scopes")
    }

    /// `calendarID` is the calendar the request was about, if it was about one.
    private func failure(_ status: Int, _ data: Data, calendarID: String? = nil) -> GoogleCalendarError {
        struct ErrorReply: Decodable {
            struct Detail: Decodable { var message: String? }
            var error: Detail
        }
        if status == 404, let calendarID { return .calendarNotFound(calendarID) }
        let message = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error.message
        return .api(status: status, message: message ?? String(decoding: data.prefix(200), as: UTF8.self))
    }
}
