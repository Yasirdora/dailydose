import Foundation
import SwiftData
import Testing
@testable import DailyDose

@Suite("Schema migration")
struct MigrationTests {

    /// Writes a store with the original V1 models, then opens it through the
    /// migration plan — the exact path a user's phone takes when it updates.
    @Test("A V1 store migrates with medications, schedules and history intact")
    func v1StoreMigrates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("DailyDose.store")

        // --- Write the store the way the first build did. ---
        let v1Schema = Schema(versionedSchema: DailyDoseSchemaV1.self)
        let v1Container = try ModelContainer(
            for: v1Schema,
            configurations: [ModelConfiguration(schema: v1Schema, url: url)]
        )
        let v1Context = ModelContext(v1Container)

        let scheduled = Fixture.date(2026, 8, 10, 8)
        let legacy = DailyDoseSchemaV1.Medication(name: "Metformin HCL", times: ["08:00", "20:00"])
        legacy.uuid = "stable-id-123"
        legacy.doseDetail = "850 mg"
        legacy.notes = "With food"
        legacy.colorName = "teal"
        legacy.weekdays = [2, 4, 6]
        legacy.pillsRemaining = 42
        legacy.refillWarnAt = 10
        legacy.scheduleKindRaw = ScheduleKind.weekdays.rawValue
        v1Context.insert(legacy)
        v1Context.insert(DailyDoseSchemaV1.DoseEvent(
            medication: legacy, scheduledAt: scheduled, statusRaw: "taken", loggedAt: scheduled
        ))
        try v1Context.save()

        // --- Reopen through the migration plan, as the updated app does. ---
        let v2Schema = Schema(versionedSchema: DailyDoseSchemaV2.self)
        let v2Container = try ModelContainer(
            for: v2Schema,
            migrationPlan: DailyDoseMigrationPlan.self,
            configurations: [ModelConfiguration(schema: v2Schema, url: url)]
        )
        let medications = try ModelContext(v2Container).fetch(FetchDescriptor<Medication>())

        #expect(medications.count == 1)
        let medication = try #require(medications.first)
        #expect(medication.id == "stable-id-123")
        #expect(medication.displayName == "Metformin HCL")
        #expect(medication.doseDetail == "850 mg")
        #expect(medication.refillThreshold == 10)
        #expect(medication.pillsRemaining == 42)
        #expect(medication.schedule.kind == .weekdays)
        #expect(medication.schedule.weekdays == [2, 4, 6])
        #expect(medication.schedule.sortedTimes.map(\.rawValue) == ["08:00", "20:00"])
        // A missing startDate falls back to createdAt — the floor that stops
        // the missed-dose sweep from inventing history.
        #expect(medication.schedule.startDate == medication.createdAt)

        #expect(medication.events.count == 1)
        let event = try #require(medication.events.first)
        #expect(event.status == .taken)
        #expect(event.scheduledAt == scheduled)
        // Denormalised at migration time, so history survives a later delete.
        #expect(event.medicationName == "Metformin HCL")
        #expect(event.medicationColorName == "teal")
    }
}
