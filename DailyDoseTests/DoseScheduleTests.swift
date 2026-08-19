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

        // Whichever of the two absolute instants the resolver picks, a log at
        // either one must match: wall-clock matching keys both to the same
        // "2026-10-25|02:30", so the read path never loses the user's record
        // to the ambiguity.
        let chosen = occurrences[0]
        #expect(calendar.component(.hour, from: chosen) == 2)
        #expect(calendar.component(.minute, from: chosen) == 30)
        let otherInstant = chosen.addingTimeInterval(3600)
        let index = LoggedEventIndex([("m", otherInstant, .taken)], calendar: calendar)
        #expect(index.status(medicationID: "m", scheduledAt: chosen) == .taken)
    }

    @Test("An interval schedule survives the spring-forward transition")
    func intervalSurvivesSpringForward() {
        // The autumn test alone survives even a seconds-based day count — the
        // 25-hour day errs in the direction it tolerates. March is the
        // direction that catches a drift: CET jumps on 29 March 2026.
        let start = Fixture.date(2026, 3, 25)
        let schedule = Fixture.schedule(kind: .everyXDays, start: start, intervalDays: 2)

        #expect(schedule.occurs(on: Fixture.date(2026, 3, 27), calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 3, 29), calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 3, 31), calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 3, 30), calendar: calendar) == false)
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

@Suite("Every X hours")
struct HourlyScheduleTests {

    let calendar = Fixture.calendar()

    @Test("Doses cross midnight instead of resetting each day")
    func crossesMidnight() {
        // First dose 22:00, every 8 hours → 22:00, 06:00, 14:00, 22:00…
        let schedule = Fixture.schedule(
            kind: .everyXHours,
            times: [Fixture.time(22)],
            start: Fixture.date(2026, 8, 10),
            intervalHours: 8
        )
        let day10 = schedule.occurrences(
            from: Fixture.date(2026, 8, 10), to: Fixture.date(2026, 8, 11), calendar: calendar
        )
        let day11 = schedule.occurrences(
            from: Fixture.date(2026, 8, 11), to: Fixture.date(2026, 8, 12), calendar: calendar
        )
        #expect(day10 == [Fixture.date(2026, 8, 10, 22)])
        #expect(day11 == [
            Fixture.date(2026, 8, 11, 6),
            Fixture.date(2026, 8, 11, 14),
            Fixture.date(2026, 8, 11, 22),
        ])
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 10), calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 11), calendar: calendar))
    }

    @Test("Nothing is scheduled before the anchor")
    func respectsAnchor() {
        let schedule = Fixture.schedule(
            kind: .everyXHours,
            times: [Fixture.time(22)],
            start: Fixture.date(2026, 8, 10),
            intervalHours: 8
        )
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 9), calendar: calendar) == false)
        // The window covers the whole start day; only the 22:00 anchor is in it.
        let before = schedule.occurrences(
            from: Fixture.date(2026, 8, 10), to: Fixture.date(2026, 8, 10, 21), calendar: calendar
        )
        #expect(before.isEmpty)
    }

    @Test("Eight hours means eight real hours across a DST jump")
    func absoluteIntervalAcrossDST() {
        // Europe/Berlin springs forward on 29 March 2026: 02:00–02:59 vanish.
        // A wall-clock schedule would drift by an hour; a prescription that
        // says "every 8 hours" must not.
        let schedule = Fixture.schedule(
            kind: .everyXHours,
            times: [Fixture.time(20)],
            start: Fixture.date(2026, 3, 28),
            intervalHours: 8
        )
        let around = schedule.occurrences(
            from: Fixture.date(2026, 3, 28, 20), to: Fixture.date(2026, 3, 31), calendar: calendar
        )
        for pair in zip(around, around.dropFirst()) {
            #expect(pair.1.timeIntervalSince(pair.0) == 8 * 3600,
                    "Every gap stays exactly 8 real hours, DST or not")
        }
        #expect(around.count >= 6)
    }

    @Test("The upper bound is exclusive and the lower inclusive")
    func boundsAreHalfOpen() {
        let schedule = Fixture.schedule(
            kind: .everyXHours,
            times: [Fixture.time(8)],
            start: Fixture.date(2026, 8, 10),
            intervalHours: 6
        )
        let doses = schedule.occurrences(
            from: Fixture.date(2026, 8, 11, 8), to: Fixture.date(2026, 8, 11, 20), calendar: calendar
        )
        #expect(doses == [Fixture.date(2026, 8, 11, 8), Fixture.date(2026, 8, 11, 14)])
    }

    @Test("An end date stops the sequence, inclusive of the final day")
    func endDateStopsSequence() {
        let schedule = Fixture.schedule(
            kind: .everyXHours,
            times: [Fixture.time(8)],
            start: Fixture.date(2026, 8, 10),
            intervalHours: 12,
            end: Fixture.date(2026, 8, 11)
        )
        let all = schedule.occurrences(
            from: Fixture.date(2026, 8, 10), to: Fixture.date(2026, 8, 14), calendar: calendar
        )
        #expect(all == [
            Fixture.date(2026, 8, 10, 8), Fixture.date(2026, 8, 10, 20),
            Fixture.date(2026, 8, 11, 8), Fixture.date(2026, 8, 11, 20),
        ])
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 12), calendar: calendar) == false)
    }

    @Test("Next occurrence is the first multiple strictly after now")
    func nextOccurrenceStrictlyAfter() {
        let schedule = Fixture.schedule(
            kind: .everyXHours,
            times: [Fixture.time(8)],
            start: Fixture.date(2026, 8, 10),
            intervalHours: 8
        )
        // Anchor 08:00. Just before it, the anchor itself is next; at it, the next one is.
        #expect(schedule.nextOccurrence(after: Fixture.date(2026, 8, 10, 7, 59), calendar: calendar)
            == Fixture.date(2026, 8, 10, 8))
        #expect(schedule.nextOccurrence(after: Fixture.date(2026, 8, 10, 8), calendar: calendar)
            == Fixture.date(2026, 8, 10, 16))
    }

    @Test("An hourly course that ended has no next occurrence")
    func endedHourlyCourse() {
        let schedule = Fixture.schedule(
            kind: .everyXHours,
            times: [Fixture.time(8)],
            start: Fixture.date(2026, 8, 1),
            intervalHours: 8,
            end: Fixture.date(2026, 8, 5)
        )
        #expect(schedule.nextOccurrence(after: Fixture.date(2026, 8, 12), calendar: calendar) == nil)
    }

    @Test("The summary names the interval in words")
    func summaryInWords() {
        let schedule = Fixture.schedule(
            kind: .everyXHours, start: Fixture.date(2026, 8, 10), intervalHours: 8
        )
        #expect(schedule.summary(calendar: calendar) == "Every 8 hours")
        #expect(schedule.frequencySummary(calendar: calendar) == "Every 8 hours",
                "An hourly course must never be described as 'once a day'")
    }
}

@Suite("Recurring cycle")
struct CycleScheduleTests {

    let calendar = Fixture.calendar()

    // A 3-on / 2-off cycle starting Monday 10 Aug 2026:
    // on 10 11 12, off 13 14, on 15 16 17, off 18 19, on 20…

    @Test("Active and rest days alternate from the start date")
    func alternatesFromStart() {
        let schedule = Fixture.schedule(
            kind: .cycle,
            start: Fixture.date(2026, 8, 10),
            cycleOnDays: 3, cycleOffDays: 2
        )
        let expected: [(Int, Bool)] = [
            (9, false),   // before the course
            (10, true), (11, true), (12, true),
            (13, false), (14, false),
            (15, true), (16, true), (17, true),
            (18, false), (19, false),
            (20, true),
        ]
        for (day, active) in expected {
            #expect(schedule.occurs(on: Fixture.date(2026, 8, day), calendar: calendar) == active,
                    "August \(day) should be \(active ? "on" : "off")")
        }
    }

    @Test("The cycle spans months without realigning")
    func spansMonths() {
        // 21 on / 7 off from 10 Aug: first rest starts 31 Aug, second
        // active block starts 7 Sep. The rhythm counts days, not calendar pages.
        let schedule = Fixture.schedule(
            kind: .cycle,
            start: Fixture.date(2026, 8, 10),
            cycleOnDays: 21, cycleOffDays: 7
        )
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 30), calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 31), calendar: calendar) == false)
        #expect(schedule.occurs(on: Fixture.date(2026, 9, 6), calendar: calendar) == false)
        #expect(schedule.occurs(on: Fixture.date(2026, 9, 7), calendar: calendar))
    }

    @Test("An end date closes the course even mid-cycle")
    func endDateClosesMidCycle() {
        let schedule = Fixture.schedule(
            kind: .cycle,
            start: Fixture.date(2026, 8, 10),
            cycleOnDays: 21, cycleOffDays: 7,
            end: Fixture.date(2026, 8, 15)
        )
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 15), calendar: calendar))
        #expect(schedule.occurs(on: Fixture.date(2026, 8, 16), calendar: calendar) == false)
    }

    @Test("Occurrences on an active day carry the day's dose times")
    func occurrencesCarryTimes() {
        let schedule = Fixture.schedule(
            kind: .cycle,
            times: [Fixture.time(8), Fixture.time(20)],
            start: Fixture.date(2026, 8, 10),
            cycleOnDays: 3, cycleOffDays: 2
        )
        let on = schedule.occurrences(
            from: Fixture.date(2026, 8, 11), to: Fixture.date(2026, 8, 12), calendar: calendar
        )
        #expect(on == [Fixture.date(2026, 8, 11, 8), Fixture.date(2026, 8, 11, 20)])
        let off = schedule.occurrences(
            from: Fixture.date(2026, 8, 13), to: Fixture.date(2026, 8, 14), calendar: calendar
        )
        #expect(off.isEmpty)
    }

    @Test("The summary describes the rhythm, not a daily count")
    func summaryDescribesRhythm() {
        let schedule = Fixture.schedule(
            kind: .cycle,
            times: [Fixture.time(8), Fixture.time(20)],
            start: Fixture.date(2026, 8, 10),
            cycleOnDays: 21, cycleOffDays: 7
        )
        #expect(schedule.summary(calendar: calendar) == "21 days on · 7 days off")
        #expect(schedule.frequencySummary(calendar: calendar) == "21 days on · 7 days off",
                "A cycle taken twice a day must never read as just 'twice a day'")
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

/// What the Save button is doing when it greys out.
///
/// Device testing reported "failing to select … supply" with no more detail,
/// and there were two candidate explanations: the toggle not responding to
/// taps, or the toggle working perfectly and disabling Save. These pin the
/// second, so the diagnosis is a fact rather than a reading of the view code.
@Suite("Supply validation")
struct SupplyValidationTests {

    private func draft() -> MedicationDraft {
        var draft = MedicationDraft()
        draft.name = "Metformin"
        draft.times = [Fixture.time(8)]
        return draft
    }

    /// The toggle is not broken. Turning it on with the count still blank is
    /// what disables Save — and that rule is deliberate: a blank count used to
    /// persist as 0, and `0 <= 0` fired a refill alert on a box the user had
    /// just filled.
    @Test("Turning supply tracking on with no count disables Save")
    func trackingWithoutACountBlocksSave() {
        var draft = draft()
        #expect(draft.isValid, "a plain medication saves")

        draft.tracksSupply = true
        #expect(draft.isMissingSupplyCount)
        #expect(!draft.isValid, "this is what the user saw as a dead Save button")

        draft.pillsRemaining = 30
        #expect(!draft.isMissingSupplyCount)
        #expect(draft.isValid, "and typing a count releases it")
    }

    /// The warning level may stay blank — it means "don't warn me". Only the
    /// count is required, because tracking supply without one is meaningless.
    @Test("The warning level is optional; only the count is required")
    func thresholdStaysOptional() {
        var draft = draft()
        draft.tracksSupply = true
        draft.pillsRemaining = 30
        #expect(draft.refillThreshold == nil)
        #expect(draft.isValid)
    }

    /// Turning tracking back off must clear the block rather than strand the
    /// user with a button they cannot explain.
    @Test("Turning tracking off again releases Save")
    func togglingOffReleasesSave() {
        var draft = draft()
        draft.tracksSupply = true
        #expect(!draft.isValid)
        draft.tracksSupply = false
        #expect(draft.isValid)
    }

    /// Every blocked state names itself. The Save button and this string read
    /// the same properties, so a dimmed button can never appear with nothing on
    /// screen saying why.
    @Test("Each reason Save is blocked has a message, and a valid draft has none")
    func blockingReasonNamesEveryCase() {
        #expect(draft().blockingReason == nil)

        var noName = draft()
        noName.name = "   "
        #expect(noName.blockingReason != nil)

        var noTimes = draft()
        noTimes.times = []
        #expect(noTimes.blockingReason != nil)

        var badNumber = draft()
        badNumber.strengthText = "thirty"
        #expect(badNumber.blockingReason != nil)

        var noDays = draft()
        noDays.kind = .weekdays
        noDays.weekdays = []
        #expect(noDays.blockingReason != nil)

        var backwards = draft()
        backwards.startDate = Fixture.date(2026, 8, 10)
        backwards.endDate = Fixture.date(2026, 8, 1)
        #expect(backwards.blockingReason != nil)

        var supply = draft()
        supply.tracksSupply = true
        #expect(supply.blockingReason != nil)
    }
}
