import Foundation
import Testing
@testable import DailyDose

/// H4: a tapped banner must log the dose it was *delivered* for, not the dose
/// nearest the moment it was tapped.
///
/// Repeating triggers carry only a time of day. Before the fix, resolution
/// ran against `.now`, so a Monday 08:00 banner tapped on Tuesday morning
/// logged Tuesday's dose — and Monday's was later swept to missed. The record
/// said the opposite of what happened.
@Suite("H4: reminder banners resolve by delivery date")
struct ReminderResolutionTests {

    private let calendar = Fixture.calendar()

    @Test("A stale banner tapped the next day still logs its own day")
    func staleBannerResolvesToDeliveryDay() throws {
        let schedule = Fixture.schedule(
            kind: .daily, times: [Fixture.time(8)],
            start: Fixture.date(2026, 8, 1)
        )
        // Banner for Monday 08:00, delivered five seconds late. The user
        // ignores it and taps it on Tuesday — resolution must still land on
        // Monday's dose.
        let delivered = try #require(
            calendar.date(byAdding: .second, value: 5, to: Fixture.date(2026, 8, 10, 8, 0))
        )
        let resolved = ReminderResolution.resolve(
            schedule: schedule, time: Fixture.time(8),
            deliveredAt: delivered, calendar: calendar
        )
        #expect(resolved == Fixture.date(2026, 8, 10, 8, 0),
                "Resolution must follow the delivery date, not the tap date")
    }

    @Test("System clock skew just before the scheduled instant is tolerated")
    func deliveryLagTolerance() {
        let schedule = Fixture.schedule(
            kind: .daily, times: [Fixture.time(8)],
            start: Fixture.date(2026, 8, 1)
        )
        // The trigger fired at 08:00:00 but the system stamped delivery at
        // 07:59:58. Without the tolerance window the exclusive upper bound
        // would resolve to *yesterday's* dose.
        let resolved = ReminderResolution.resolve(
            schedule: schedule, time: Fixture.time(8),
            deliveredAt: Fixture.date(2026, 8, 10, 7, 59).addingTimeInterval(58),
            calendar: calendar
        )
        #expect(resolved == Fixture.date(2026, 8, 10, 8, 0))
    }

    @Test("A banner for the evening dose never resolves to the morning dose")
    func matchesOwnTimeOfDay() {
        let schedule = Fixture.schedule(
            kind: .daily, times: [Fixture.time(8), Fixture.time(20)],
            start: Fixture.date(2026, 8, 1)
        )
        let delivered = Fixture.date(2026, 8, 10, 20, 0).addingTimeInterval(5)
        let resolved = ReminderResolution.resolve(
            schedule: schedule, time: Fixture.time(20),
            deliveredAt: delivered, calendar: calendar
        )
        #expect(resolved == Fixture.date(2026, 8, 10, 20, 0),
                "The 20:00 banner must match the 20:00 occurrence, not the most recent one")
    }

    @Test("Sparse schedules resolve within the lookback window")
    func sparseScheduleResolves() {
        // Monthly on the 1st at 08:00. The August banner is delivered on
        // 1 August; the lookback must reach past July's occurrence without
        // being fooled by it.
        let schedule = Fixture.schedule(
            kind: .monthly, times: [Fixture.time(8)],
            start: Fixture.date(2026, 6, 1), dayOfMonth: 1
        )
        let delivered = Fixture.date(2026, 8, 1, 8, 0).addingTimeInterval(5)
        let resolved = ReminderResolution.resolve(
            schedule: schedule, time: Fixture.time(8),
            deliveredAt: delivered, calendar: calendar
        )
        #expect(resolved == Fixture.date(2026, 8, 1, 8, 0))
    }

    @Test("A payload whose time is not in the schedule resolves to nil")
    func unknownTimeResolvesToNil() {
        let schedule = Fixture.schedule(
            kind: .daily, times: [Fixture.time(8)],
            start: Fixture.date(2026, 8, 1)
        )
        let resolved = ReminderResolution.resolve(
            schedule: schedule, time: Fixture.time(9),
            deliveredAt: Fixture.date(2026, 8, 10, 9, 0),
            calendar: calendar
        )
        #expect(resolved == nil,
                "A 09:00 payload for an 08:00 medicine must not guess")
    }
}
