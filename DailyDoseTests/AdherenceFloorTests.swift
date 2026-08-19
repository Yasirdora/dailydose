import Foundation
import SwiftData
import Testing
@testable import DailyDose

/// The floor under the missed-dose sweep.
///
/// "Starts" is a free date picker, and back-dating it is the natural thing to
/// do — the prescription really did begin three weeks ago, and the schedule
/// needs that date to land "every 2 days" on the right days. But Daily Dose
/// was not installed then, sent no reminders then, and cannot honestly call
/// those doses missed. Without a floor the sweep wrote weeks of fabricated
/// failures into History and into the doctor report the user hands a
/// clinician — the same class of invented history that a non-optional
/// `startDate` was introduced to end.
@Suite("Adherence floor")
struct AdherenceFloorTests {

    let calendar = Fixture.calendar()

    /// 12:00 so that every dose earlier in the day is unambiguously past.
    var now: Date { Fixture.date(2026, 8, 19, 12) }

    // MARK: - Domain

    @Test("A back-dated start date does not invent misses from before the app knew about it")
    func backdatedStartIsFloored() {
        let start = Fixture.date(2026, 7, 20)      // 30 days before `now`
        let added = Fixture.date(2026, 8, 17, 9)   // installed two days ago

        let medication = Fixture.medication(
            schedule: Fixture.schedule(times: [Fixture.time(8)], start: start),
            createdAt: added
        )

        let missed = DoseCalculator.unloggedOverdueDoses(
            medications: [medication], events: LoggedEventIndex([], calendar: calendar),
            lookbackDays: 30, now: now, calendar: calendar
        )

        // The 17th's 08:00 dose is before `createdAt` (09:00 that day), so the
        // first dose the app could have reminded about is the 18th's.
        #expect(missed.count == 2, "Only the doses since the medication was added")
        #expect(missed.map(\.scheduledAt).sorted() == [
            Fixture.date(2026, 8, 18, 8),
            Fixture.date(2026, 8, 19, 8),
        ])
    }

    @Test("The floor is the later of the two — a recent start still wins")
    func startDateStillFloors() {
        // Added a month ago, but the course only began yesterday: the start
        // date is the tighter bound and must keep applying.
        let medication = Fixture.medication(
            schedule: Fixture.schedule(times: [Fixture.time(8)], start: Fixture.date(2026, 8, 18)),
            createdAt: Fixture.date(2026, 7, 19)
        )

        let missed = DoseCalculator.unloggedOverdueDoses(
            medications: [medication], events: LoggedEventIndex([], calendar: calendar),
            lookbackDays: 30, now: now, calendar: calendar
        )

        #expect(missed.count == 2)
        #expect(missed.map(\.scheduledAt).min() == Fixture.date(2026, 8, 18, 8))
    }

    @Test("A medication added after its last due dose produces nothing at all")
    func addedAfterEverything() {
        let medication = Fixture.medication(
            schedule: Fixture.schedule(times: [Fixture.time(8)], start: Fixture.date(2026, 6, 1)),
            createdAt: Fixture.date(2026, 8, 19, 11)   // added an hour ago
        )

        let missed = DoseCalculator.unloggedOverdueDoses(
            medications: [medication], events: LoggedEventIndex([], calendar: calendar),
            lookbackDays: 30, now: now, calendar: calendar
        )

        #expect(missed.isEmpty, "Adding a medication must never be an accusation")
    }

    @Test("Doses after the floor are still swept — the floor is not an off switch")
    func floorDoesNotDisableTheSweep() {
        let medication = Fixture.medication(
            schedule: Fixture.schedule(times: [Fixture.time(8), Fixture.time(20)],
                                       start: Fixture.date(2026, 8, 1)),
            createdAt: Fixture.date(2026, 8, 1)
        )

        let missed = DoseCalculator.unloggedOverdueDoses(
            medications: [medication], events: LoggedEventIndex([], calendar: calendar),
            lookbackDays: 30, now: now, calendar: calendar
        )

        // 1–18 Aug inclusive at 08:00 and 20:00, plus the 19th's 08:00.
        #expect(missed.count == 37)
    }

    // MARK: - Store

    /// Timezone-robust on purpose: every date here is derived with
    /// `Calendar.current`, because `recordMissedDoses` resolves the schedule
    /// in the device's own calendar and a fixture pinned to Berlin would
    /// assert against instants the production code never produces.
    @Test("The store writes no missed events for days before the medication existed")
    @MainActor
    func storeSweepRespectsTheFloor() async throws {
        let container = try ModelContainer(
            for: Schema([Medication.self, DoseEvent.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let store = DoseStore(context: context, notifications: NullScheduler())

        let device = Calendar.current
        let today = device.startOfDay(for: Fixture.date(2026, 8, 19))
        let sweepNow = device.date(byAdding: .hour, value: 18, to: today)!
        let courseBegan = device.date(byAdding: .day, value: -30, to: today)!
        // Added yesterday at midday: yesterday's 08:00 dose is already behind
        // the app's own arrival, today's 08:00 is the first it could have
        // reminded about.
        let installed = device.date(byAdding: .hour, value: 12,
                                    to: device.date(byAdding: .day, value: -1, to: today)!)!

        let medication = store.add(
            name: "Amoxicillin", doseDetail: "500 mg", notes: "",
            colorName: MedicationColor.coral.rawValue,
            schedule: Fixture.schedule(times: [Fixture.time(8)], start: courseBegan),
            pillsRemaining: nil, refillThreshold: nil
        )
        medication.createdAt = installed

        store.recordMissedDoses(now: sweepNow)

        let events = try context.fetch(FetchDescriptor<DoseEvent>())
        #expect(events.count == 1,
                "One missed dose — not the thirty days the back-dated start date spans")
        #expect(events.first?.status == .missed)
        #expect(events.first.map { $0.scheduledAt > installed } == true,
                "Nothing may be recorded from before the medication existed")

        await store.rescheduleNotifications()
        _ = container
    }
}

/// A wall-clock time that does not exist must not become "now".
@Suite("Time resolution")
struct TimeOfDayResolutionTests {

    /// Berlin springs forward on 29 March 2026: 02:00 becomes 03:00, so 02:30
    /// has no instant that day.
    @Test("A time inside the spring-forward gap resolves to the next real day")
    func gapResolvesForward() {
        let calendar = Fixture.calendar()
        let gapDay = Fixture.date(2026, 3, 29)

        let resolved = Fixture.time(2, 30).nextValidDate(onOrAfter: gapDay, calendar: calendar)

        #expect(TimeOfDay(from: resolved, calendar: calendar) == Fixture.time(2, 30),
                "The wheel must open on the time it was given, not the time it is now")
        #expect(resolved == Fixture.date(2026, 3, 30, 2, 30))
    }

    @Test("An ordinary time resolves on the day it was asked for")
    func ordinaryTimeIsUnchanged() {
        let calendar = Fixture.calendar()
        let day = Fixture.date(2026, 8, 19)
        #expect(Fixture.time(8).nextValidDate(onOrAfter: day, calendar: calendar)
                == Fixture.date(2026, 8, 19, 8))
    }
}
