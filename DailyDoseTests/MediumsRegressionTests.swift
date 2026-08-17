import Foundation
import SwiftData
import Testing
@testable import DailyDose

/// Regression tests for the audit's medium findings that can be pinned in
/// code. View-only mediums (tap targets, contrast, layout) are verified by
/// review; what lives here is the record's integrity.
@Suite("Mediums: the record keeps its shape")
struct MediumsRegressionTests {

    private let calendar = Fixture.calendar()

    @MainActor
    private func makeStack() throws -> (ModelContainer, DoseStore) {
        let container = try ModelContainer(
            for: Schema([Medication.self, DoseEvent.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return (container, DoseStore(context: container.mainContext, notifications: NullScheduler()))
    }

    // MARK: - M20: two doses a minute apart never share a log

    @Test("Logging 08:01 must not overwrite the 08:00 dose")
    @MainActor
    func adjacentDosesLogSeparately() async throws {
        // The write path used to match within ±60s inclusive, so a schedule
        // with 08:00 and 08:01 — which the editor permits — had each log
        // overwrite the other while the read path kept them distinct.
        let (container, store) = try makeStack()
        let schedule = Fixture.schedule(
            kind: .daily, times: [Fixture.time(8), Fixture.time(8, 1)],
            start: Fixture.date(2026, 8, 1)
        )
        let medication = store.add(name: "Metformin", doseDetail: "500 mg", notes: "",
                                   colorName: "teal", schedule: schedule,
                                   pillsRemaining: nil, refillThreshold: nil)

        store.log(medicationID: medication.id,
                  scheduledAt: Fixture.date(2026, 8, 10, 8, 0), status: .taken)
        store.log(medicationID: medication.id,
                  scheduledAt: Fixture.date(2026, 8, 10, 8, 1), status: .skipped)

        let events = store.recentEvents(limit: 10)
            .filter { $0.medicationID == medication.id }
        #expect(events.count == 2, "Both doses keep their own record")
        #expect(events.contains { $0.status == .taken })
        #expect(events.contains { $0.status == .skipped })

        // And a correction still finds its own dose, not its neighbour.
        store.log(medicationID: medication.id,
                  scheduledAt: Fixture.date(2026, 8, 10, 8, 1), status: .taken)
        let corrected = store.recentEvents(limit: 10)
            .filter { $0.medicationID == medication.id }
        #expect(corrected.count == 2, "A correction must not create a third record")
        #expect(corrected.filter { $0.status == .taken }.count == 2)

        // Flush the reschedule tasks spawned by add()/log() while the
        // container is alive — SwiftData traps if they fire after teardown.
        await store.rescheduleNotifications()
        _ = container
    }
}
