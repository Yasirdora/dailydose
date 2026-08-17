import Foundation
import SwiftData
import Testing
@testable import DailyDose

@Suite("Delete all data")
struct DeleteAllDataTests {

    /// The container is retained for the whole test, matching how the app
    /// actually uses DoseStore: AppEnvironment holds both for the process's
    /// lifetime. Returning just `mainContext` lets the container die while the
    /// store is still in use, and the reschedule task that fires on the next
    /// main-actor hop then runs against a dead store — which traps inside
    /// SwiftData.
    @MainActor
    private func makeStack() throws -> (ModelContainer, DoseStore, ModelContext) {
        let container = try ModelContainer(
            for: Schema([Medication.self, DoseEvent.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        return (container, DoseStore(context: context, notifications: NullScheduler()), context)
    }

    @Test("Every medication and every event is removed")
    @MainActor
    func storeIsEmptied() async throws {
        let (container, store, context) = try makeStack()

        let schedule = DoseSchedule(
            kind: .daily,
            times: [Fixture.time(8)],
            startDate: Fixture.date(2026, 8, 1)
        )
        let medication = Medication(name: "Metformin", schedule: schedule)
        context.insert(medication)
        context.insert(DoseEvent(
            medication: medication,
            scheduledAt: Fixture.date(2026, 8, 12, 8),
            status: .taken
        ))
        try context.save()

        store.deleteAllData()
        // Give the reschedule task a chance to run while everything is alive.
        try? await Task.sleep(for: .milliseconds(100))

        #expect(try context.fetchCount(FetchDescriptor<Medication>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<DoseEvent>()) == 0)
        #expect(store.lastError == nil)
        _ = container
    }
}
