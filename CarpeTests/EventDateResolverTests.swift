import Foundation
import Testing

/// All tests run as if it were Tuesday 10 November 2026, 12:00 in Helsinki.
@Suite struct EventDateResolverTests {
    static let helsinki = TimeZone(identifier: "Europe/Helsinki")!

    let resolver = EventDateResolver(now: local(2026, 11, 10, 12, 0), timeZone: helsinki)

    static func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = helsinki
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Self.local(year, month, day, hour, minute)
    }

    // MARK: - Defaults

    @Test func timedEventWithoutEndLastsOneHour() throws {
        let event = try resolver.resolve(ExtractedEvent(title: "Hammaslääkäri", start: "2026-11-17T14:00:00"))
        #expect(event.start == local(2026, 11, 17, 14, 0))
        #expect(event.end == local(2026, 11, 17, 15, 0))
        #expect(!event.isAllDay)
        #expect(event.timeZone == Self.helsinki)
    }

    @Test func givenEndIsKept() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Workshop", start: "2026-11-17T09:00:00", end: "2026-11-17T16:30:00")
        )
        #expect(event.end == local(2026, 11, 17, 16, 30))
    }

    @Test func secondsAreOptional() throws {
        let event = try resolver.resolve(ExtractedEvent(title: "Call", start: "2026-11-17T14:00"))
        #expect(event.start == local(2026, 11, 17, 14, 0))
    }

    @Test func endBeforeStartOnTheSameDateRunsPastMidnight() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Bileet", start: "2026-11-20T22:00:00", end: "2026-11-20T01:00:00")
        )
        #expect(event.end == local(2026, 11, 21, 1, 0))
    }

    @Test func nonsensicalEndFallsBackToOneHour() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Meeting", start: "2026-11-20T10:00:00", end: "2026-11-12T11:00:00")
        )
        #expect(event.end == local(2026, 11, 20, 11, 0))
    }

    @Test func unreadableEndFallsBackToOneHour() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Meeting", start: "2026-11-20T10:00:00", end: "later")
        )
        #expect(event.end == local(2026, 11, 20, 11, 0))
    }

    @Test func blankLocationAndDescriptionBecomeNil() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: " Lounas ", start: "2026-11-17T12:00:00", location: "  ", description: "")
        )
        #expect(event.title == "Lounas")
        #expect(event.location == nil)
        #expect(event.notes == nil)
    }

    // MARK: - All-day

    @Test func singleAllDayEventEndsAtTheNextMidnight() throws {
        let event = try resolver.resolve(ExtractedEvent(title: "Eräpäivä", start: "2026-11-30", allDay: true))
        #expect(event.isAllDay)
        #expect(event.start == local(2026, 11, 30))
        #expect(event.end == local(2026, 12, 1))
    }

    @Test func multiDayAllDayEventIncludesItsLastDay() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Messut", start: "2026-11-20", end: "2026-11-22", allDay: true)
        )
        #expect(event.start == local(2026, 11, 20))
        #expect(event.end == local(2026, 11, 23))
    }

    @Test func dateOnlyStartIsAllDayEvenWhenNotFlagged() throws {
        let event = try resolver.resolve(ExtractedEvent(title: "Deadline", start: "2026-12-01", allDay: false))
        #expect(event.isAllDay)
        #expect(event.end == local(2026, 12, 2))
    }

    @Test func allDayFlagIgnoresATimeOfDay() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Vappu", start: "2027-05-01T10:00:00", allDay: true)
        )
        #expect(event.start == local(2027, 5, 1))
        #expect(event.end == local(2027, 5, 2))
    }

    @Test func allDayEndBeforeStartCollapsesToOneDay() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Trip", start: "2026-11-20", end: "2026-11-18", allDay: true)
        )
        #expect(event.end == local(2026, 11, 21))
    }

    @Test func allDayEventAcrossTheAutumnClockChangeStillEndsAtMidnight() throws {
        // Helsinki goes back an hour on 25 October 2026, so that day has 25 hours.
        let october = EventDateResolver(now: local(2026, 10, 1, 12, 0), timeZone: Self.helsinki)
        let event = try october.resolve(ExtractedEvent(title: "Syysloma", start: "2026-10-25", allDay: true))
        #expect(event.end == local(2026, 10, 26))
    }

    // MARK: - Year rollover

    @Test func yearlessDateInThePastMovesToNextYear() throws {
        // "15.1. klo 14" seen in November: Claude answered with this year.
        let event = try resolver.resolve(
            ExtractedEvent(title: "Kokous", start: "2026-01-15T14:00:00", yearGiven: false)
        )
        #expect(event.start == local(2027, 1, 15, 14, 0))
        #expect(event.end == local(2027, 1, 15, 15, 0))
    }

    @Test func yearlessDateStillAheadIsLeftAlone() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Pikkujoulut", start: "2026-12-05T18:00:00", yearGiven: false)
        )
        #expect(event.start == local(2026, 12, 5, 18, 0))
    }

    @Test func writtenYearInThePastIsRespected() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Kokous", start: "2026-01-15T14:00:00", yearGiven: true)
        )
        #expect(event.start == local(2026, 1, 15, 14, 0))
    }

    @Test func earlierTodayCountsAsUpcoming() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Aamupala", start: "2026-11-10T08:00:00", yearGiven: false)
        )
        #expect(event.start == local(2026, 11, 10, 8, 0))
    }

    @Test func yesterdayWithoutAYearMovesToNextYear() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Synttärit", start: "2026-11-09", allDay: true, yearGiven: false)
        )
        #expect(event.start == local(2027, 11, 9))
        #expect(event.end == local(2027, 11, 10))
    }

    @Test func rolloverKeepsTheDuration() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Seminaari", start: "2026-03-02T09:00:00", end: "2026-03-02T16:00:00", yearGiven: false)
        )
        #expect(event.start == local(2027, 3, 2, 9, 0))
        #expect(event.end == local(2027, 3, 2, 16, 0))
    }

    @Test func rolloverKeepsAMultiDaySpan() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Hiihtoloma", start: "2026-02-22", end: "2026-02-28", allDay: true, yearGiven: false)
        )
        #expect(event.start == local(2027, 2, 22))
        #expect(event.end == local(2027, 3, 1))
    }

    @Test func leapDayMovesToTheNextLeapYear() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Karkauspäivä", start: "2024-02-29", allDay: true, yearGiven: false)
        )
        #expect(event.start == local(2028, 2, 29))
        #expect(event.end == local(2028, 3, 1))
    }

    @Test func oneHourDefaultCrossesIntoTheNewYear() throws {
        let event = try resolver.resolve(ExtractedEvent(title: "Uusivuosi", start: "2026-12-31T23:30:00"))
        #expect(event.end == local(2027, 1, 1, 0, 30))
    }

    @Test func allDayNewYearsEveEndsOnNewYearsDay() throws {
        let event = try resolver.resolve(ExtractedEvent(title: "Uudenvuodenaatto", start: "2026-12-31", allDay: true))
        #expect(event.end == local(2027, 1, 1))
    }

    @Test func rolloverAtTheTurnOfTheYear() throws {
        // On 2 January, "31.12." means the coming December, not two days ago.
        let january = EventDateResolver(now: local(2027, 1, 2, 9, 0), timeZone: Self.helsinki)
        let event = try january.resolve(
            ExtractedEvent(title: "Ilotulitus", start: "2026-12-31T23:00:00", yearGiven: false)
        )
        #expect(event.start == local(2027, 12, 31, 23, 0))
        #expect(event.end == local(2028, 1, 1, 0, 0))
    }

    // MARK: - Parsing

    @Test func utcOffsetIsConvertedToLocalTime() throws {
        let zulu = try resolver.resolve(ExtractedEvent(title: "Webinar", start: "2026-11-17T12:00:00Z"))
        #expect(zulu.start == local(2026, 11, 17, 14, 0))

        let offset = try resolver.resolve(ExtractedEvent(title: "Webinar", start: "2026-11-17T14:00:00+02:00"))
        #expect(offset.start == local(2026, 11, 17, 14, 0))
    }

    @Test func midnightWrittenAsTwentyFourIsTheNextDay() throws {
        let event = try resolver.resolve(
            ExtractedEvent(title: "Ilta", start: "2026-11-20T20:00:00", end: "2026-11-20T24:00:00")
        )
        #expect(event.end == local(2026, 11, 21, 0, 0))
    }

    @Test(arguments: ["", "next Tuesday", "17.11.2026", "2026-02-30", "2026-13-01", "2026-11-17T25:00:00"])
    func unreadableStartThrows(_ start: String) {
        #expect(throws: EventDateError.unreadableStart(title: "X", value: start)) {
            try resolver.resolve(ExtractedEvent(title: "X", start: start))
        }
    }
}
