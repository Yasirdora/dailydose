import Foundation
import Testing
@testable import DailyDose

@Suite("Dose schedule")
struct DoseScheduleTests {

    let calendar = Fixture.calendar()

    // MARK: - The start floor
    //
    // This is the regression suite for the app's most damaging bug: a schedule
    // with no start date reported that it "occurred" on every past day, so the
    // missed-dose sweep wrote a week of fabricated failures for a medication
    // added five minutes ago.

    @Test("A daily schedule never occurs before its start date")
    func dailyRespectsStartFloor() {
        let start = Fixture.date(2026, 8, 12)
        let schedule = Fixture.schedule(kind: .daily, start: start)

        #expect(schedule.occurs(on: Fixture.date(2026, 8, 11), calendar: calendar) == false)
        #expect(schedule.occurs(on: start, calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 13), calendar: calendar))
    }

    @Test("A weekday schedule never occurs before its start date")
    func weekdaysRespectStartFloor() {
        // 12 Aug 2026 is a Wednesday (weekday 4).
        let start = Fixture.date(2026, 8, 12)
        let schedule = Fixture.schedule(kind: .weekdays, start: start, weekdays: [4])

        #expect(schedule.occurs(on: Fixture.date(2026, 8, 5), calendar: calendar) == false,
                "The previous Wednesday predates the course")
        #expect(schedule.occurs(on: start, calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 19), calendar: calendar))
    }

    @Test("A schedule with no times never occurs")
    func noTimesNeverOccurs() {
        // Imported Health medications land here until the user sets a schedule.
        let schedule = Fixture.schedule(times: [], start: Fixture.date(2026, 8, 1))
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 12), calendar: calendar) == false)
    }

    // MARK: - End dates

    @Test("An end date closes the course, inclusive of the final day")
    func endDateIsInclusive() {
        let schedule = Fixture.schedule(
            kind: .daily,
            start: Fixture.date(2026, 8, 10),
            end: Fixture.date(2026, 8, 12)
        )
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 12), calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 13), calendar: calendar) == false)
    }

    // MARK: - Interval schedules

    @Test("Every-N-days counts from the start date")
    func intervalCountsFromStart() {
        let start = Fixture.date(2026, 8, 1)
        let schedule = Fixture.schedule(kind: .everyXDays, start: start, intervalDays: 21)

        #expect(schedule.occurs(on: start, calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 22), calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 9, 12), calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 21), calendar: calendar) == false)
    }

    @Test("An interval schedule survives a daylight-saving transition")
    func intervalSurvivesDST() {
        // Central European Time falls back on 25 October 2026. Counting in
        // absolute seconds rather than calendar days drifts by an hour here and
        // eventually skips a dose.
        let start = Fixture.date(2026, 10, 20)
        let schedule = Fixture.schedule(kind: .everyXDays, start: start, intervalDays: 2)

        #expect(schedule.occurs(on: Fixture.date(2026, 10, 24), calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 10, 26), calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 10, 28), calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 10, 27), calendar: calendar) == false)
    }

    // MARK: - Monthly schedules

    @Test("The 31st falls on the last day of a short month")
    func monthlyClampsToShortMonths() {
        let schedule = Fixture.schedule(
            kind: .monthly, start: Fixture.date(2026, 1, 31), dayOfMonth: 31
        )
        #expect(schedule.occurs(on: Fixture.date(2026, 1, 31), calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 2, 28), calendar: calendar),
                "February has no 31st — the dose belongs on the last day, not skipped")
        #expect(schedule.occurs(on: Fixture.date(2026, 4, 30), calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 3, 30), calendar: calendar) == false)
    }

    @Test("The 29th appears in a leap February")
    func monthlyHandlesLeapYear() {
        let schedule = Fixture.schedule(
            kind: .monthly, start: Fixture.date(2028, 1, 29), dayOfMonth: 29
        )
        #expect(schedule.occurs(on: Fixture.date(2028, 2, 29), calendar: calendar))
    }

    // MARK: - Occurrences

    @Test("Occurrences are ascending, in range, and one per dose time")
    func occurrencesAreOrderedAndBounded() {
        let schedule = Fixture.schedule(
            kind: .daily,
            times: [Fixture.time(8), Fixture.time(20)],
            start: Fixture.date(2026, 8, 1)
        )
        let occurrences = schedule.occurrences(
            from: Fixture.date(2026, 8, 10),
            to: Fixture.date(2026, 8, 13),
            calendar: calendar
        )

        #expect(occurrences.count == 6, "Three days, twice a day")
        #expect(occurrences == occurrences.sorted())
        #expect(occurrences.first == Fixture.date(2026, 8, 10, 8))
        #expect(occurrences.last == Fixture.date(2026, 8, 12, 20))
    }

    @Test("The upper bound is exclusive")
    func occurrenceUpperBoundIsExclusive() {
        let schedule = Fixture.schedule(kind: .daily, start: Fixture.date(2026, 8, 1))
        let occurrences = schedule.occurrences(
            from: Fixture.date(2026, 8, 10),
            to: Fixture.date(2026, 8, 11, 8),
            calendar: calendar
        )
        #expect(occurrences.count == 1, "11 Aug 08:00 sits exactly on the bound and is excluded")
    }

    @Test("A dose in the spring-forward gap moves to the first real instant")
    func springForwardGapResolvesForward() {
        // CET jumps 02:00 → 03:00 on 29 March 2026: 02:30 does not exist.
        let schedule = Fixture.schedule(
            kind: .daily, times: [Fixture.time(2, 30)], start: Fixture.date(2026, 3, 20)
        )
        let occurrences = schedule.occurrences(
            from: Fixture.date(2026, 3, 29),
            to: Fixture.date(2026, 3, 30),
            calendar: calendar
        )

        #expect(occurrences.count == 1, "The dose must not vanish on the day the clocks change")
        let resolved = occurrences[0]
        #expect(calendar.isDate(resolved, inSameDayAs: Fixture.date(2026, 3, 29)),
                "It stays on the day it was prescribed for")
        #expect(calendar.component(.hour, from: resolved) == 3)
    }

    @Test("A dose in the fall-back overlap fires once, not twice")
    func fallBackDoesNotDuplicate() {
        // CET repeats 02:00–03:00 on 25 October 2026.
        let schedule = Fixture.schedule(
            kind: .daily, times: [Fixture.time(2, 30)], start: Fixture.date(2026, 10, 20)
        )
        let occurrences = schedule.occurrences(
            from: Fixture.date(2026, 10, 25),
            to: Fixture.date(2026, 10, 26),
            calendar: calendar
        )
        #expect(occurrences.count == 1, "A repeated wall-clock hour must not double the dose")
    }

    // MARK: - Next occurrence

    @Test("Next occurrence is strictly after the given moment")
    func nextOccurrenceIsStrictlyAfter() {
        let schedule = Fixture.schedule(
            kind: .daily,
            times: [Fixture.time(8), Fixture.time(20)],
            start: Fixture.date(2026, 8, 1)
        )
        let next = schedule.nextOccurrence(
            after: Fixture.date(2026, 8, 12, 8), calendar: calendar
        )
        #expect(next == Fixture.date(2026, 8, 12, 20))
    }

    @Test("A sparse schedule still resolves months ahead")
    func nextOccurrenceFindsSparseSchedules() {
        let schedule = Fixture.schedule(
            kind: .everyXDays, start: Fixture.date(2026, 1, 1), intervalDays: 90
        )
        let next = schedule.nextOccurrence(after: Fixture.date(2026, 8, 12), calendar: calendar)
        #expect(next != nil, "A 90-day interval must not report 'no upcoming dose'")
    }

    @Test("A finished course has no next occurrence")
    func endedScheduleHasNoNextOccurrence() {
        let schedule = Fixture.schedule(
            kind: .daily,
            start: Fixture.date(2026, 8, 1),
            end: Fixture.date(2026, 8, 5)
        )
        #expect(schedule.nextOccurrence(after: Fixture.date(2026, 8, 12), calendar: calendar) == nil)
    }
}

@Suite("Time of day")
struct TimeOfDayTests {

    @Test("Round-trips through its raw value")
    func roundTrip() {
        let time = Fixture.time(8, 5)
        #expect(time.rawValue == "08:05")
        #expect(TimeOfDay("08:05") == time)
        #expect(TimeOfDay("8:05") == time, "A missing leading zero still parses")
    }

    @Test("Out-of-range values are rejected rather than clamped")
    func rejectsInvalid() {
        #expect(TimeOfDay(hour: 24, minute: 0) == nil)
        #expect(TimeOfDay(hour: -1, minute: 0) == nil)
        #expect(TimeOfDay(hour: 12, minute: 60) == nil)
        #expect(TimeOfDay("nonsense") == nil)
        #expect(TimeOfDay("12") == nil)
    }

    @Test("Ordering is chronological, not lexical")
    func ordering() {
        // Sorting the old "HH:mm" strings worked only because they were
        // zero-padded — one missing zero and 9:00 sorted after 10:00.
        #expect(Fixture.time(9) < Fixture.time(10))
        #expect(Fixture.time(8, 5) < Fixture.time(8, 30))
        #expect([Fixture.time(20), Fixture.time(8)].sorted() == [Fixture.time(8), Fixture.time(20)])
    }

    @Test("Suggested times are unique and correctly sized")
    func suggestions() {
        for count in 1...4 {
            let times = TimeOfDay.suggested(forDosesPerDay: count)
            #expect(times.count == count)
            #expect(Set(times).count == count, "Suggestions must never collide")
        }
    }
}
