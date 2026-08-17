import Foundation
import Testing
@testable import DailyDose

@Suite("Dose calculator")
struct DoseCalculatorTests {

    let calendar = Fixture.calendar()

    private func index(_ entries: [(String, Date, DoseStatus)]) -> LoggedEventIndex {
        LoggedEventIndex(entries.map { (medicationID: $0.0, scheduledAt: $0.1, status: $0.2) })
    }

    // MARK: - States

    @Test("A dose becomes due 15 minutes before its time")
    func dueGrace() {
        let scheduled = Fixture.date(2026, 8, 12, 8)
        let justBefore = scheduled.addingTimeInterval(-DoseCalculator.dueGrace + 60)
        let wellBefore = scheduled.addingTimeInterval(-3600)

        #expect(DoseCalculator.state(for: "m", at: scheduled, events: .empty, now: justBefore) == .due)
        #expect(DoseCalculator.state(for: "m", at: scheduled, events: .empty, now: wellBefore) == .upcoming)
    }

    @Test("A dose stays actionable for two hours, then goes overdue")
    func missWindow() {
        let scheduled = Fixture.date(2026, 8, 12, 8)
        let stillDue = scheduled.addingTimeInterval(DoseCalculator.missWindow - 60)
        let tooLate = scheduled.addingTimeInterval(DoseCalculator.missWindow + 60)

        #expect(DoseCalculator.state(for: "m", at: scheduled, events: .empty, now: stillDue) == .due)
        #expect(DoseCalculator.state(for: "m", at: scheduled, events: .empty, now: tooLate) == .overdue)
    }

    @Test("A logged dose keeps its status regardless of the clock")
    func loggedWins() {
        let scheduled = Fixture.date(2026, 8, 12, 8)
        let events = index([("m", scheduled, .taken)])
        let muchLater = scheduled.addingTimeInterval(86_400)

        #expect(DoseCalculator.state(for: "m", at: scheduled, events: events, now: muchLater) == .logged(.taken))
    }

    @Test("A log within a minute of the scheduled instant still matches")
    func minuteTolerance() {
        let scheduled = Fixture.date(2026, 8, 12, 8)
        let events = index([("m", scheduled.addingTimeInterval(20), .taken)])
        #expect(events.status(medicationID: "m", scheduledAt: scheduled) == .taken)
    }

    // MARK: - The day's doses

    @Test("Doses come back sorted, one per time, across medications")
    func dosesForDay() {
        let start = Fixture.date(2026, 8, 1)
        let meds = [
            Fixture.medication(id: "a", schedule: Fixture.schedule(
                times: [Fixture.time(8), Fixture.time(20)], start: start
            )),
            Fixture.medication(id: "b", name: "Lisinopril", schedule: Fixture.schedule(
                times: [Fixture.time(12)], start: start
            )),
        ]
        let doses = DoseCalculator.doses(
            on: Fixture.date(2026, 8, 12), medications: meds,
            events: .empty, now: Fixture.date(2026, 8, 12, 9), calendar: calendar
        )

        #expect(doses.count == 3)
        #expect(doses.map(\.medicationID) == ["a", "b", "a"])
        #expect(doses.map(\.scheduledAt) == doses.map(\.scheduledAt).sorted())
    }

    @Test("Paused medications produce no doses")
    func inactiveMedicationsExcluded() {
        let meds = [Fixture.medication(
            schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1)), isActive: false
        )]
        let doses = DoseCalculator.doses(
            on: Fixture.date(2026, 8, 12), medications: meds,
            events: .empty, now: Fixture.date(2026, 8, 12, 9), calendar: calendar
        )
        #expect(doses.isEmpty)
    }

    @Test("Dose identifiers are stable and locale-independent")
    func doseIdentityIsStable() {
        let scheduled = Fixture.date(2026, 8, 12, 8)
        let first = Dose(medicationID: "m", scheduledAt: scheduled, state: .due)
        let second = Dose(medicationID: "m", scheduledAt: scheduled, state: .logged(.taken))

        #expect(first.id == second.id, "Identity must not shift when state changes")
        let isASCII = first.id.allSatisfy(\.isASCII)
        #expect(isASCII, "Identifiers end up in notification ids")
    }

    // MARK: - The missed-dose sweep
    //
    // The regression suite for the bug that greeted every new user with a week
    // of failures they never had.

    @Test("A medication added today is never retroactively marked missed")
    func newMedicationHasNoBackdatedMisses() {
        let now = Fixture.date(2026, 8, 12, 20)
        let addedToday = Fixture.medication(
            schedule: Fixture.schedule(
                kind: .daily, times: [Fixture.time(8)],
                start: calendar.startOfDay(for: now)
            )
        )

        let overdue = DoseCalculator.unloggedOverdueDoses(
            medications: [addedToday], events: .empty,
            lookbackDays: 7, now: now, calendar: calendar
        )

        #expect(overdue.count == 1, "Only today's 08:00 dose is genuinely missed")
        #expect(overdue[0].scheduledAt == Fixture.date(2026, 8, 12, 8))
    }

    @Test("Doses inside the grace window are not yet missed")
    func recentDosesAreNotMissedYet() {
        let now = Fixture.date(2026, 8, 12, 9)
        let medication = Fixture.medication(schedule: Fixture.schedule(
            times: [Fixture.time(8)], start: Fixture.date(2026, 8, 12)
        ))
        let overdue = DoseCalculator.unloggedOverdueDoses(
            medications: [medication], events: .empty,
            lookbackDays: 7, now: now, calendar: calendar
        )
        #expect(overdue.isEmpty, "08:00 is only an hour ago — still actionable")
    }

    @Test("Already-logged doses are never swept as missed")
    func loggedDosesAreSkipped() {
        let now = Fixture.date(2026, 8, 12, 20)
        let medication = Fixture.medication(schedule: Fixture.schedule(
            times: [Fixture.time(8)], start: Fixture.date(2026, 8, 10)
        ))
        let events = index([
            ("med-1", Fixture.date(2026, 8, 10, 8), .taken),
            ("med-1", Fixture.date(2026, 8, 11, 8), .skipped),
        ])

        let overdue = DoseCalculator.unloggedOverdueDoses(
            medications: [medication], events: events,
            lookbackDays: 7, now: now, calendar: calendar
        )
        #expect(overdue.count == 1)
        #expect(overdue[0].scheduledAt == Fixture.date(2026, 8, 12, 8))
    }

    @Test("The sweep is idempotent once its results are recorded")
    func sweepIsIdempotent() {
        let now = Fixture.date(2026, 8, 12, 20)
        let medication = Fixture.medication(schedule: Fixture.schedule(
            times: [Fixture.time(8)], start: Fixture.date(2026, 8, 11)
        ))

        let first = DoseCalculator.unloggedOverdueDoses(
            medications: [medication], events: .empty,
            lookbackDays: 7, now: now, calendar: calendar
        )
        let recorded = index(first.map { ("med-1", $0.scheduledAt, DoseStatus.missed) })
        let second = DoseCalculator.unloggedOverdueDoses(
            medications: [medication], events: recorded,
            lookbackDays: 7, now: now, calendar: calendar
        )

        #expect(first.count == 2)
        #expect(second.isEmpty, "Running the sweep twice must not duplicate history")
    }

    // MARK: - Progress

    @Test("Day progress counts taken against scheduled")
    func dayProgress() {
        let medication = Fixture.medication(schedule: Fixture.schedule(
            times: [Fixture.time(8), Fixture.time(20)], start: Fixture.date(2026, 8, 1)
        ))
        let events = index([("med-1", Fixture.date(2026, 8, 12, 8), .taken)])

        let progress = DoseCalculator.progress(
            on: Fixture.date(2026, 8, 12), medications: [medication],
            events: events, now: Fixture.date(2026, 8, 12, 12), calendar: calendar
        )

        #expect(progress.taken == 1)
        #expect(progress.total == 2)
        #expect(progress.isComplete == false)
        #expect(abs(progress.fraction - 0.5) < 0.0001)
    }

    @Test("A skipped dose counts as scheduled but not taken")
    func skippedIsNotTaken() {
        let medication = Fixture.medication(schedule: Fixture.schedule(
            times: [Fixture.time(8)], start: Fixture.date(2026, 8, 1)
        ))
        let events = index([("med-1", Fixture.date(2026, 8, 12, 8), .skipped)])

        let progress = DoseCalculator.progress(
            on: Fixture.date(2026, 8, 12), medications: [medication],
            events: events, now: Fixture.date(2026, 8, 12, 12), calendar: calendar
        )
        #expect(progress.taken == 0)
        #expect(progress.total == 1)
    }
}
