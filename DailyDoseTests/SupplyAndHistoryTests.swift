import Foundation
import SwiftData
import Testing
@testable import DailyDose

/// Supply arithmetic and the delete-keeps-history promise — two
/// previously-shipped bug classes the audit found with zero regression
/// coverage. Both are DoseStore-level guarantees the app's own copy makes:
/// the refill count the user trusts, and "its history stays in your records".
@Suite("Supply and history promises")
struct SupplyAndHistoryTests {

    /// The container is retained for the whole test, matching how the app
    /// actually uses DoseStore — see DeleteAllDataTests for the trap this avoids.
    @MainActor
    private func makeStack() throws -> (ModelContainer, DoseStore, ModelContext) {
        let container = try ModelContainer(
            for: Schema([Medication.self, DoseEvent.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        return (container, DoseStore(context: context, notifications: NullScheduler()), context)
    }

    @Test("taken → skipped → taken consumes exactly one pill; undo returns it")
    @MainActor
    func supplyFollowsTheFinalState() async throws {
        let (container, store, context) = try makeStack()
        defer { _ = container }

        let medication = store.add(
            name: "Metformin", doseDetail: "500 mg", notes: "",
            colorName: MedicationColor.navy.rawValue,
            schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1)),
            pillsRemaining: 10, refillThreshold: 3
        )
        let at = Fixture.date(2026, 8, 12, 8)

        store.log(medicationID: medication.id, scheduledAt: at, status: .taken)
        #expect(medication.pillsRemaining == 9, "One taken dose consumes one pill")

        // Correcting the log must reverse the consumption — the shipped bug
        // decremented on every write to .taken, so this path used to end at 8.
        store.log(medicationID: medication.id, scheduledAt: at, status: .skipped)
        #expect(medication.pillsRemaining == 10, "Un-taking returns the pill")

        store.log(medicationID: medication.id, scheduledAt: at, status: .taken)
        #expect(medication.pillsRemaining == 9, "Re-taking consumes it again — once")

        store.undoLog(medicationID: medication.id, scheduledAt: at)
        #expect(medication.pillsRemaining == 10, "Undo returns the pill to the count")

        await store.rescheduleNotifications()
        _ = context
    }

    @Test("Deleting a medication keeps its history, as the app promises")
    @MainActor
    func deleteKeepsHistory() async throws {
        let (container, store, context) = try makeStack()
        defer { _ = container }

        let medication = store.add(
            name: "Metformin", doseDetail: "500 mg", notes: "",
            colorName: MedicationColor.navy.rawValue,
            schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1)),
            pillsRemaining: nil, refillThreshold: nil
        )
        let at = Fixture.date(2026, 8, 12, 8)
        store.log(medicationID: medication.id, scheduledAt: at, status: .taken)

        store.delete(medication)

        #expect(try context.fetchCount(FetchDescriptor<Medication>()) == 0)
        let events = try context.fetch(FetchDescriptor<DoseEvent>())
        #expect(events.count == 1, "The record of a taken dose must survive the delete")
        #expect(events.first?.medicationName == "Metformin",
                "An orphaned event still reads as a real medication, not '(deleted)'")
        #expect(events.first?.medication == nil)

        await store.rescheduleNotifications()
    }
}
