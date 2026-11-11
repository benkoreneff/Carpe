import Foundation

/// The calendars offered when Carpe asks where an event goes: what each one
/// is called, and which one starts out selected.
struct CalendarChoices: Equatable, Sendable {
    let calendars: [CalendarInfo]
    /// One label per calendar, in the same order. A title shared by several
    /// calendars gets the account added: "Home (iCloud)".
    let labels: [String]

    init(_ calendars: [CalendarInfo]) {
        self.calendars = calendars
        let titleCounts = Dictionary(calendars.map { ($0.title, 1) }, uniquingKeysWith: +)
        labels = calendars.map { calendar in
            guard titleCounts[calendar.title, default: 0] > 1, let account = calendar.account, !account.isEmpty else {
                return calendar.title
            }
            return "\(calendar.title) (\(account))"
        }
    }

    /// The names Claude chooses from. Labels that are still not unique are
    /// left out, since a suggestion couldn't tell those calendars apart.
    var namesForClaude: [String] {
        let counts = Dictionary(labels.map { ($0, 1) }, uniquingKeysWith: +)
        return labels.filter { !$0.isEmpty && counts[$0] == 1 }
    }

    func label(for calendar: CalendarInfo) -> String {
        index(ofID: calendar.id).map { labels[$0] } ?? calendar.title
    }

    private func index(ofID id: String?) -> Int? {
        guard let id else { return nil }
        return calendars.firstIndex { $0.id == id }
    }

    /// Which calendar is selected when the list appears: Claude's suggestion,
    /// else the calendar used last time, else the default from Settings, else
    /// the service's own default.
    func preselectedIndex(suggestion: String?, lastUsedID: String?, defaultID: String?) -> Int {
        if let suggestion, namesForClaude.contains(suggestion), let index = labels.firstIndex(of: suggestion) {
            return index
        }
        return index(ofID: lastUsedID)
            ?? index(ofID: defaultID)
            ?? calendars.firstIndex(where: \.isDefault)
            ?? 0
    }
}
