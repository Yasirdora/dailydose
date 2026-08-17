import Foundation
import Testing
@testable import DailyDose

/// The audit's #1 unverified claim, proven real: schedules resolve in
/// `Calendar.current` while logs used to match by absolute minute, so a
/// timezone change fabricated `.missed` rows over doses the user actually
/// took — a doctor report printed after a holiday showed a week of failures
/// that never happened. In an app whose entire promise is an honest record,
/// that was a data-integrity bug, not an edge case.
///
/// The fix: every event written since V4 stores its wall-clock identity
/// ("the 8am dose of October 25th") in the timezone it was logged in, and
/// matching runs on that key. These tests pin both directions.
@Suite("Timezone travel")
struct TimezoneTravelTests {

    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private var losAngeles: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func day(_ calendar: Calendar, _ day: Int, _ hour: Int = 8) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func medication() -> MedicationSnapshot {
        Fixture.medication(
            id: "m", name: "Metformin",
            schedule: Fixture.schedule(
                kind: .daily, times: [Fixture.time(8)], start: day(berlin, 20)
            )
        )
    }

    @Test("Doses taken in Berlin are not fabricated as missed after flying to LA")
    func berlinToLADoesNotFabricateMisses() {
        // A daily 08:00 medication, taken as scheduled on three consecutive
        // Berlin mornings. Each event carries the wall-clock key the store
        // now writes at log time — "2026-10-23|08:00" and so on, in Berlin.
        let takenEvents: [(String, Date, String, DoseStatus)] = (23...25).map { d in
            let instant = day(berlin, d, 8)
            return ("m", instant, WallClock.key(for: instant, calendar: berlin), .taken)
        }

        // The flight: same life, new calendar. It is now midday in Berlin on
        // the 26th — early morning in LA — and the app re-resolves everything
        // against Los Angeles.
        let now = day(berlin, 26, 12)
        let fabricated = DoseCalculator.unloggedOverdueDoses(
            medications: [medication()],
            events: LoggedEventIndex(keyedEvents: takenEvents, calendar: losAngeles),
            lookbackDays: 3,
            now: now,
            calendar: losAngeles
        )

        #expect(fabricated.isEmpty,
                "Three taken doses re-appear as \(fabricated.count) missed under a new timezone")
    }

    @Test("A dose logged after the move matches the new timezone's schedule")
    func loggingContinuesAfterTheMove() throws {
        // Under LA the 27th's 08:00 dose is a new wall-clock identity; the
        // Berlin keys must not swallow it — it starts unlogged and due.
        let occurrence = try #require(
            medication().schedule.occurrences(
                from: day(losAngeles, 27), to: day(losAngeles, 28), calendar: losAngeles
            ).first
        )
        let index = LoggedEventIndex(
            keyedEvents: [("m", day(berlin, 25, 8), "2026-10-25|08:00", .taken)],
            calendar: losAngeles
        )
        #expect(index.status(medicationID: "m", scheduledAt: occurrence) == nil,
                "Tomorrow's LA dose is not yesterday's Berlin dose")
    }

    @Test("Legacy events without a stored key behave exactly as before")
    func legacyEventsDeriveTheirKeyInTheCurrentCalendar() {
        // Pre-V4 rows carry no key; the read path derives one in the current
        // calendar — identical to the old absolute matching as long as the
        // timezone has not changed since the event was written.
        let index = LoggedEventIndex(
            keyedEvents: [("m", day(berlin, 25, 8), "", .taken)],
            calendar: berlin
        )
        #expect(index.status(medicationID: "m", scheduledAt: day(berlin, 25, 8)) == .taken)
        #expect(index.status(medicationID: "m", scheduledAt: day(berlin, 26, 8)) == nil)
    }
}
