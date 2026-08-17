import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import DailyDose

/// Regression tests for the audit's three blockers.
///
/// B1 (stuck Taken/Skip buttons) lives in view @State and is verified by
/// review and on-device use; what can be locked down in code — the clock
/// rollover and the awaitable, failure-reporting reminder pipeline — is
/// locked down here.
@Suite("Blockers: midnight rollover and reminder pipeline")
struct BlockerRegressionTests {

    private let calendar = Fixture.calendar()

    @MainActor
    private func makeStack(
        notifications: NotificationScheduling = NullScheduler()
    ) throws -> (ModelContainer, DoseStore) {
        let container = try ModelContainer(
            for: Schema([Medication.self, DoseEvent.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return (container, DoseStore(context: container.mainContext, notifications: notifications))
    }

    // MARK: - B3: the selected day follows the clock

    @Test("A screen showing today turns with midnight")
    @MainActor
    func todayFollowsTheClock() throws {
        // The container is retained for the whole test — dropping it while the
        // store is in use traps inside SwiftData on the next fetch.
        let (container, store) = try makeStack()
        let model = TodayModel(store: store, calendar: calendar)

        // 23:55 — the user is looking at today.
        model.selectedDay = Fixture.date(2026, 8, 10, 23, 55)
        model.rebuild(now: Fixture.date(2026, 8, 10, 23, 55))
        #expect(calendar.isDate(model.selectedDay, inSameDayAs: Fixture.date(2026, 8, 10)))

        // The phone sleeps; the next tick is 00:10. The screen must turn.
        model.rebuild(now: Fixture.date(2026, 8, 11, 0, 10))
        #expect(calendar.isDate(model.selectedDay, inSameDayAs: Fixture.date(2026, 8, 11)),
                "Still showing yesterday after midnight — a tap would log the wrong day")
        _ = container
    }

    @Test("A deliberately chosen past day is never yanked away")
    @MainActor
    func chosenDayStaysPut() throws {
        let (container, store) = try makeStack()
        let model = TodayModel(store: store, calendar: calendar)

        // Today is 10 August; the user deliberately walks back to the 5th.
        model.rebuild(now: Fixture.date(2026, 8, 10, 22, 0))
        model.selectedDay = Fixture.date(2026, 8, 5)

        // Midnight passes while they read history. The view must not move:
        // only a day that was *current* at the last tick follows the clock.
        model.rebuild(now: Fixture.date(2026, 8, 11, 0, 10))
        #expect(calendar.isDate(model.selectedDay, inSameDayAs: Fixture.date(2026, 8, 5)),
                "Reviewing history must not be interrupted by the clock")
        _ = container
    }

    @Test("A future day being reviewed does not jump at midnight")
    @MainActor
    func futureDayStaysPut() throws {
        let (container, store) = try makeStack()
        let model = TodayModel(store: store, calendar: calendar)

        model.selectedDay = Fixture.date(2026, 8, 12)
        model.rebuild(now: Fixture.date(2026, 8, 10, 23, 55))
        model.rebuild(now: Fixture.date(2026, 8, 11, 0, 10))
        #expect(calendar.isDate(model.selectedDay, inSameDayAs: Fixture.date(2026, 8, 12)))
        _ = container
    }

    // MARK: - B2: failed adds surface as deferred, never as silence

    @Test("A notification the system refuses lands in deferredMedicationIDs")
    @MainActor
    func failedAddsAreDeferred() async throws {
        let failAll = RefusingScheduler()
        let (container, store) = try makeStack(notifications: failAll)

        let schedule = DoseSchedule(
            kind: .daily, times: [Fixture.time(8)], startDate: Fixture.date(2026, 8, 1)
        )
        _ = store.add(name: "Metformin", doseDetail: "500 mg", notes: "",
                      colorName: "teal", schedule: schedule,
                      pillsRemaining: nil, refillThreshold: nil)

        await store.rescheduleNotifications()

        let meds = store.medications()
        #expect(meds.count == 1)
        #expect(store.deferredMedicationIDs.contains(meds[0].id),
                "A refused reminder must be visible as deferred, not swallowed")
        _ = container
    }
}

/// A scheduler whose every add fails — the budget-exhausted case.
private struct RefusingScheduler: NotificationScheduling {
    func apply(_ plan: NotificationPlanner.Plan) async -> [String] {
        plan.notifications.map(\.id)
    }
    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization() async -> Bool { true }
}
