import Foundation

/// An event with real dates, ready for a calendar.
struct ResolvedEvent: Equatable, Sendable {
    var title: String
    var start: Date
    /// Timed events: the end instant. All-day events: midnight after the last
    /// day, i.e. exclusive, which is what Google Calendar expects.
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var timeZone: TimeZone
}

enum EventDateError: LocalizedError, Equatable {
    case unreadableStart(title: String, value: String)

    var errorDescription: String? {
        switch self {
        case let .unreadableStart(title, value):
            "Couldn't read the start date \"\(value)\" for \"\(title)\"."
        }
    }
}

/// Turns Claude's date strings into calendar dates and applies the rules that
/// are safer in code than in a prompt: the one-hour default, all-day ranges,
/// and moving a year-less date that landed in the past to its next occurrence.
struct EventDateResolver {
    static let defaultDuration: TimeInterval = 60 * 60

    let calendar: Calendar
    let now: Date

    init(now: Date = Date(), timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.now = now
    }

    func resolve(_ event: ExtractedEvent) throws -> ResolvedEvent {
        guard let start = stamp(event.start) else {
            throw EventDateError.unreadableStart(title: event.title, value: event.start)
        }
        // An unreadable end is not worth failing over; the defaults cover it.
        let end = event.end.flatMap(stamp)

        // A start with no time of day can only be an all-day event.
        let isAllDay = event.allDay || !start.hasTime
        let range = isAllDay
            ? allDayRange(start: start, end: end, yearGiven: event.yearGiven)
            : timedRange(start: start, end: end, yearGiven: event.yearGiven)

        return ResolvedEvent(
            title: event.title.trimmingCharacters(in: .whitespacesAndNewlines),
            start: range.start,
            end: range.end,
            isAllDay: isAllDay,
            location: event.location.nonBlank,
            notes: event.description.nonBlank,
            timeZone: calendar.timeZone
        )
    }

    // MARK: - Ranges

    private func timedRange(start: Stamp, end: Stamp?, yearGiven: Bool) -> (start: Date, end: Date) {
        var startDate = start.date
        var endDate = startDate.addingTimeInterval(Self.defaultDuration)

        if let end, end.hasTime {
            if end.date > startDate {
                endDate = end.date
            } else if let nextDay = calendar.date(byAdding: .day, value: 1, to: end.date),
                      nextDay > startDate,
                      nextDay.timeIntervalSince(startDate) < 24 * 60 * 60 {
                // "22:00-01:00" written with a single date runs past midnight.
                endDate = nextDay
            }
        }

        if !yearGiven {
            let duration = endDate.timeIntervalSince(startDate)
            startDate = nextOccurrence(of: startDate)
            endDate = startDate.addingTimeInterval(duration)
        }
        return (startDate, endDate)
    }

    private func allDayRange(start: Stamp, end: Stamp?, yearGiven: Bool) -> (start: Date, end: Date) {
        var firstDay = calendar.startOfDay(for: start.date)
        var lastDay = end.map { calendar.startOfDay(for: $0.date) } ?? firstDay
        if lastDay < firstDay { lastDay = firstDay }
        let extraDays = calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0

        if !yearGiven { firstDay = nextOccurrence(of: firstDay) }

        // Claude gives the last day inclusively; calendars want it exclusive.
        let endExclusive = calendar.date(byAdding: .day, value: extraDays + 1, to: firstDay)
            ?? firstDay.addingTimeInterval(24 * 60 * 60)
        return (firstDay, endExclusive)
    }

    // MARK: - Year rollover

    /// For a date whose year was not in the screenshot: if it is before today,
    /// move it to the next year in which that day and month exist and are not
    /// in the past. Today itself counts as upcoming, whatever the time.
    func nextOccurrence(of date: Date) -> Date {
        let today = calendar.startOfDay(for: now)
        guard calendar.startOfDay(for: date) < today else { return date }

        var parts = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: date)
        let currentYear = calendar.component(.year, from: now)
        // Eight years covers 29 February across a skipped century leap year.
        for year in currentYear...(currentYear + 8) {
            parts.year = year
            guard let candidate = calendar.date(from: parts),
                  calendar.component(.month, from: candidate) == parts.month,
                  calendar.component(.day, from: candidate) == parts.day,
                  calendar.startOfDay(for: candidate) >= today
            else { continue }
            return candidate
        }
        return date
    }

    // MARK: - Parsing

    private struct Stamp {
        var date: Date
        var hasTime: Bool
    }

    /// Reads `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM[:SS]` as local wall-clock time.
    /// A trailing `Z` or UTC offset is honoured in case the model adds one.
    private func stamp(_ raw: String) -> Stamp? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?$/
        guard let match = text.wholeMatch(of: pattern),
              let year = Int(match.1), let month = Int(match.2), let day = Int(match.3)
        else { return nil }

        var parts = DateComponents(year: year, month: month, day: day)
        // Calendar silently rolls 31 February into March; reject it instead.
        guard let dayOnly = calendar.date(from: parts),
              calendar.component(.year, from: dayOnly) == year,
              calendar.component(.month, from: dayOnly) == month,
              calendar.component(.day, from: dayOnly) == day
        else { return nil }

        guard let hourText = match.4, let minuteText = match.5,
              let hour = Int(hourText), let minute = Int(minuteText)
        else { return Stamp(date: dayOnly, hasTime: false) }

        let second = match.6.flatMap { Int($0) } ?? 0
        // 24:00 is a legitimate way to write the end of a day.
        guard (0...24).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        parts.hour = hour
        parts.minute = minute
        parts.second = second

        var zoned = calendar
        if let offset = match.7, let zone = Self.timeZone(fromOffset: String(offset)) {
            zoned.timeZone = zone
        }
        guard let date = zoned.date(from: parts) else { return nil }
        return Stamp(date: date, hasTime: true)
    }

    private static func timeZone(fromOffset offset: String) -> TimeZone? {
        if offset == "Z" { return TimeZone(secondsFromGMT: 0) }
        let digits = offset.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else {
            return nil
        }
        let sign = offset.hasPrefix("-") ? -1 : 1
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }
}

private extension Optional where Wrapped == String {
    /// Nil for nil, empty and whitespace-only strings.
    var nonBlank: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
