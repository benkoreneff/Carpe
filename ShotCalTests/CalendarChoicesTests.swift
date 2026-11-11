import Foundation
import Testing

/// What the calendar picker lists and which row starts out selected.
@Suite struct CalendarChoicesTests {
    static let work = CalendarInfo(id: "w", title: "Työ", account: "Exchange")
    static let home = CalendarInfo(id: "h", title: "Koti", account: "iCloud", isDefault: true)
    static let kids = CalendarInfo(id: "k", title: "Lapset", account: "iCloud")
    static let choices = CalendarChoices([work, home, kids])

    @Test func labelsAreTheTitlesWhenTheyDiffer() {
        #expect(Self.choices.labels == ["Työ", "Koti", "Lapset"])
        #expect(Self.choices.namesForClaude == ["Työ", "Koti", "Lapset"])
        #expect(Self.choices.label(for: Self.kids) == "Lapset")
    }

    @Test func aSharedTitleGetsItsAccount() {
        let choices = CalendarChoices([
            CalendarInfo(id: "1", title: "Koti", account: "iCloud"),
            CalendarInfo(id: "2", title: "Koti", account: "Google"),
            Self.work,
        ])
        #expect(choices.labels == ["Koti (iCloud)", "Koti (Google)", "Työ"])
        #expect(choices.namesForClaude == ["Koti (iCloud)", "Koti (Google)", "Työ"])
        #expect(choices.preselectedIndex(suggestion: "Koti (Google)", lastUsedID: nil, defaultID: nil) == 1)
    }

    /// Claude couldn't say which one it means, so it isn't offered either.
    @Test func calendarsThatCannotBeToldApartAreNotNamedToClaude() {
        let choices = CalendarChoices([
            CalendarInfo(id: "1", title: "Tiimi"),
            CalendarInfo(id: "2", title: "Tiimi"),
            Self.work,
        ])
        #expect(choices.labels == ["Tiimi", "Tiimi", "Työ"])
        #expect(choices.namesForClaude == ["Työ"])
        // Both are still in the list for the user to pick.
        #expect(choices.calendars.count == 3)
        #expect(choices.preselectedIndex(suggestion: "Tiimi", lastUsedID: "2", defaultID: nil) == 1)
    }

    @Test func theSuggestionComesFirst() {
        #expect(Self.choices.preselectedIndex(suggestion: "Lapset", lastUsedID: "w", defaultID: "h") == 2)
    }

    @Test func withoutASuggestionTheLastUsedCalendarIsSelected() {
        #expect(Self.choices.preselectedIndex(suggestion: nil, lastUsedID: "w", defaultID: "h") == 0)
        #expect(Self.choices.preselectedIndex(suggestion: "Not a calendar", lastUsedID: "k", defaultID: "h") == 2)
    }

    @Test func thenTheDefaultFromSettingsThenTheServicesOwn() {
        #expect(Self.choices.preselectedIndex(suggestion: nil, lastUsedID: nil, defaultID: "k") == 2)
        // A last-used calendar that has been deleted since.
        #expect(Self.choices.preselectedIndex(suggestion: nil, lastUsedID: "gone", defaultID: "k") == 2)
        // Google's "primary" is not an ID in the list; the primary calendar is flagged instead.
        #expect(Self.choices.preselectedIndex(suggestion: nil, lastUsedID: nil, defaultID: "primary") == 1)
        #expect(Self.choices.preselectedIndex(suggestion: nil, lastUsedID: nil, defaultID: nil) == 1)
    }

    @Test func withNothingToGoOnTheFirstRowIsSelected() {
        let choices = CalendarChoices([Self.work, Self.kids])
        #expect(choices.preselectedIndex(suggestion: nil, lastUsedID: nil, defaultID: nil) == 0)
    }
}
