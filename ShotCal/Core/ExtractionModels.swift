import Foundation

/// One event exactly as Claude returned it. Dates are still strings here;
/// `EventDateResolver` turns them into real dates.
struct ExtractedEvent: Codable, Equatable, Sendable {
    var title: String
    /// Local ISO 8601: `YYYY-MM-DDTHH:MM:SS`, or `YYYY-MM-DD` when `allDay`.
    var start: String
    /// Timed events: the end time, or nil when the screenshot shows none.
    /// All-day events: the last day (inclusive), or nil for a single day.
    var end: String?
    var allDay: Bool
    /// False when the screenshot showed no year and Claude had to pick one.
    var yearGiven: Bool
    var location: String?
    var description: String?

    enum CodingKeys: String, CodingKey {
        case title, start, end, location, description
        case allDay = "all_day"
        case yearGiven = "year_given"
    }

    init(
        title: String, start: String, end: String? = nil, allDay: Bool = false,
        yearGiven: Bool = true, location: String? = nil, description: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.yearGiven = yearGiven
        self.location = location
        self.description = description
    }

    // Structured outputs always send every key. The plain-JSON fallback for
    // other models may drop some, so the optional ones get safe defaults:
    // a missing `year_given` counts as given, which leaves the date untouched.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        start = try c.decode(String.self, forKey: .start)
        end = try c.decodeIfPresent(String.self, forKey: .end)
        allDay = try c.decodeIfPresent(Bool.self, forKey: .allDay) ?? false
        yearGiven = try c.decodeIfPresent(Bool.self, forKey: .yearGiven) ?? true
        location = try c.decodeIfPresent(String.self, forKey: .location)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }
}

/// The whole structured response for one screenshot.
struct Extraction: Codable, Equatable, Sendable {
    var events: [ExtractedEvent]
    /// Why nothing was extracted. Only meaningful when `events` is empty.
    var reasonIfNone: String?
    /// The calendar Claude would put the events in: one of the names it was
    /// given, or nil. Always nil when it was given none.
    var suggestedCalendar: String?

    enum CodingKeys: String, CodingKey {
        case events
        case reasonIfNone = "reason_if_none"
        case suggestedCalendar = "suggested_calendar"
    }

    init(events: [ExtractedEvent], reasonIfNone: String? = nil, suggestedCalendar: String? = nil) {
        self.events = events
        self.reasonIfNone = reasonIfNone
        self.suggestedCalendar = suggestedCalendar
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decodeIfPresent([ExtractedEvent].self, forKey: .events) ?? []
        reasonIfNone = try c.decodeIfPresent(String.self, forKey: .reasonIfNone)
        suggestedCalendar = try c.decodeIfPresent(String.self, forKey: .suggestedCalendar)
    }

    /// Decodes Claude's text output. Tolerates a Markdown code fence, which
    /// only the plain-JSON fallback can produce.
    static func decode(fromModelText text: String) throws -> Extraction {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.split(separator: "\n", omittingEmptySubsequences: false)
                .dropFirst()
                .joined(separator: "\n")
            if let fence = body.range(of: "```", options: .backwards) {
                body = String(body[..<fence.lowerBound])
            }
        }
        return try JSONDecoder().decode(Extraction.self, from: Data(body.utf8))
    }
}
