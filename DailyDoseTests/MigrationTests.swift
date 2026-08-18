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
        // The plan chains V1→V2 (custom), V2→V3 and V3→V4 (both lightweight);
        // the app boots with the latest schema, so that is what the store is
        // opened with here.
        let currentSchema = Schema(versionedSchema: DailyDoseSchemaV6.self)
        let container = try ModelContainer(
            for: currentSchema,
            migrationPlan: DailyDoseMigrationPlan.self,
            configurations: [ModelConfiguration(schema: currentSchema, url: url)]
        )
        let medications = try ModelContext(container).fetch(FetchDescriptor<Medication>())

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
        // Written before wall-clock keys existed: empty, so the read path
        // derives one in the current calendar — the legacy behaviour.
        #expect(event.scheduledWallKey == "")
    }

    /// Writes a store with the frozen V2 models — the shape on every phone
    /// that ran the app before hourly and cycle schedules — then opens it
    /// through the plan. This is the exact update path for existing users.
    @Test("A V2 store lightweight-migrates to V3 with defaults intact")
    func v2StoreMigrates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("DailyDose.store")

        // --- Write the store the way the previous build did. ---
        let v2Schema = Schema(versionedSchema: DailyDoseSchemaV2.self)
        let v2Container = try ModelContainer(
            for: v2Schema,
            configurations: [ModelConfiguration(schema: v2Schema, url: url)]
        )
        let v2Context = ModelContext(v2Container)

        let scheduled = Fixture.date(2026, 8, 10, 8)
        let legacy = DailyDoseSchemaV2.Medication(
            id: "v2-id-1",
            name: "Metformin",
            doseDetail: "500 mg",
            notes: "",
            colorName: "teal",
            isActive: true,
            createdAt: Fixture.date(2026, 8, 1),
            timesRaw: ["08:00"],
            scheduleKindRaw: ScheduleKind.everyXDays.rawValue,
            weekdaysRaw: [1, 2, 3, 4, 5, 6, 7],
            intervalDays: 21,
            dayOfMonth: nil,
            startDate: Fixture.date(2026, 8, 1),
            endDate: nil,
            pillsRemaining: 60,
            refillThreshold: 10
        )
        v2Context.insert(legacy)
        v2Context.insert(DailyDoseSchemaV2.DoseEvent(
            medication: legacy, scheduledAt: scheduled, statusRaw: "taken", loggedAt: scheduled
        ))
        try v2Context.save()

        // --- Reopen through the migration plan, as the updated app does. ---
        let currentSchema = Schema(versionedSchema: DailyDoseSchemaV6.self)
        let container = try ModelContainer(
            for: currentSchema,
            migrationPlan: DailyDoseMigrationPlan.self,
            configurations: [ModelConfiguration(schema: currentSchema, url: url)]
        )
        let medications = try ModelContext(container).fetch(FetchDescriptor<Medication>())

        #expect(medications.count == 1)
        let medication = try #require(medications.first)
        #expect(medication.id == "v2-id-1")
        #expect(medication.schedule.kind == .everyXDays)
        #expect(medication.schedule.intervalDays == 21)
        #expect(medication.schedule.sortedTimes.map(\.rawValue) == ["08:00"])
        #expect(medication.pillsRemaining == 60)
        // The new columns arrive with their defaults — harmless for a kind
        // that never reads them, present for one that does.
        #expect(medication.intervalHours == 8)
        #expect(medication.cycleOnDays == 21)
        #expect(medication.cycleOffDays == 7)

        #expect(medication.events.count == 1)
        #expect(medication.events.first?.medicationName == "Metformin")
        #expect(medication.events.first?.scheduledWallKey == "")
    }

    /// Every launch after the update reopens an already-migrated store. The
    /// plan must be a no-op for it: same counts, no duplicated rows.
    @Test("Re-opening a migrated store changes nothing")
    func reopeningIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("DailyDose.store")

        let v2Schema = Schema(versionedSchema: DailyDoseSchemaV2.self)
        let v2Container = try ModelContainer(
            for: v2Schema,
            configurations: [ModelConfiguration(schema: v2Schema, url: url)]
        )
        let v2Context = ModelContext(v2Container)
        let legacy = DailyDoseSchemaV2.Medication(
            id: "v2-id-1", name: "Metformin", doseDetail: "500 mg", notes: "",
            colorName: "teal", isActive: true, createdAt: Fixture.date(2026, 8, 1),
            timesRaw: ["08:00"], scheduleKindRaw: ScheduleKind.daily.rawValue,
            weekdaysRaw: [1, 2, 3, 4, 5, 6, 7], intervalDays: 1, dayOfMonth: nil,
            startDate: Fixture.date(2026, 8, 1), endDate: nil,
            pillsRemaining: 60, refillThreshold: 10
        )
        v2Context.insert(legacy)
        v2Context.insert(DailyDoseSchemaV2.DoseEvent(
            medication: legacy, scheduledAt: Fixture.date(2026, 8, 10, 8),
            statusRaw: "taken", loggedAt: Fixture.date(2026, 8, 10, 8)
        ))
        try v2Context.save()

        let currentSchema = Schema(versionedSchema: DailyDoseSchemaV6.self)
        for pass in 1...2 {
            let container = try ModelContainer(
                for: currentSchema,
                migrationPlan: DailyDoseMigrationPlan.self,
                configurations: [ModelConfiguration(schema: currentSchema, url: url)]
            )
            let context = ModelContext(container)
            let medications = try context.fetch(FetchDescriptor<Medication>())
            let events = try context.fetch(FetchDescriptor<DoseEvent>())
            #expect(medications.count == 1, "Pass \(pass): the medication must survive")
            #expect(events.count == 1, "Pass \(pass): no event duplicated, none lost")
        }
    }

    /// The shape on every phone running the previous build, opened by the new
    /// one: the wall-key column arrives empty and everything else is untouched.
    @Test("A V3 store lightweight-migrates to V4")
    func v3StoreMigrates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("DailyDose.store")

        let v3Schema = Schema(versionedSchema: DailyDoseSchemaV3.self)
        let v3Container = try ModelContainer(
            for: v3Schema,
            configurations: [ModelConfiguration(schema: v3Schema, url: url)]
        )
        let v3Context = ModelContext(v3Container)
        let medication = DailyDoseSchemaV3.Medication(name: "Metformin")
        medication.id = "v3-id-1"
        let scheduled = Fixture.date(2026, 8, 10, 8)
        v3Context.insert(medication)
        v3Context.insert(DailyDoseSchemaV3.DoseEvent(
            medication: medication, scheduledAt: scheduled, statusRaw: "taken", loggedAt: scheduled
        ))
        try v3Context.save()

        let currentSchema = Schema(versionedSchema: DailyDoseSchemaV6.self)
        let container = try ModelContainer(
            for: currentSchema,
            migrationPlan: DailyDoseMigrationPlan.self,
            configurations: [ModelConfiguration(schema: currentSchema, url: url)]
        )
        let context = ModelContext(container)
        let events = try context.fetch(FetchDescriptor<DoseEvent>())

        #expect(events.count == 1)
        #expect(events.first?.scheduledWallKey == "")
        #expect(events.first?.scheduledAt == scheduled)
        #expect(events.first?.medicationName == "Metformin")
    }

    /// The shape on every phone running the previous build, opened by the new
    /// one: the form column arrives empty, resolves to the default `.pill`,
    /// and everything else is untouched.
    @Test("A V4 store lightweight-migrates to V5")
    func v4StoreMigrates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("DailyDose.store")

        let v4Schema = Schema(versionedSchema: DailyDoseSchemaV4.self)
        let v4Container = try ModelContainer(
            for: v4Schema,
            configurations: [ModelConfiguration(schema: v4Schema, url: url)]
        )
        let v4Context = ModelContext(v4Container)
        let medication = DailyDoseSchemaV4.Medication(name: "Metformin")
        medication.id = "v4-id-1"
        medication.pillsRemaining = 60
        medication.refillThreshold = 10
        let scheduled = Fixture.date(2026, 8, 10, 8)
        v4Context.insert(medication)
        v4Context.insert(DailyDoseSchemaV4.DoseEvent(
            medication: medication, scheduledAt: scheduled, statusRaw: "taken", loggedAt: scheduled
        ))
        try v4Context.save()

        let currentSchema = Schema(versionedSchema: DailyDoseSchemaV6.self)
        let container = try ModelContainer(
            for: currentSchema,
            migrationPlan: DailyDoseMigrationPlan.self,
            configurations: [ModelConfiguration(schema: currentSchema, url: url)]
        )
        let context = ModelContext(container)
        let medications = try context.fetch(FetchDescriptor<Medication>())
        let events = try context.fetch(FetchDescriptor<DoseEvent>())

        #expect(medications.count == 1)
        let migrated = try #require(medications.first)
        #expect(migrated.id == "v4-id-1")
        #expect(migrated.pillsRemaining == 60)
        // Pre-form rows read as unspecified, never as a crash, a blank
        // tile — or an assumed pill.
        #expect(migrated.formRaw == "")
        #expect(migrated.form == nil)

        #expect(events.count == 1)
        #expect(events.first?.medicationName == "Metformin")
        #expect(events.first?.scheduledAt == scheduled)
    }

    /// The shape on every phone running the previous build, opened by the new
    /// one: the structured-strength columns arrive empty and everything else
    /// is untouched.
    @Test("A V5 store lightweight-migrates to V6")
    func v5StoreMigrates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("DailyDose.store")

        let v5Schema = Schema(versionedSchema: DailyDoseSchemaV5.self)
        let v5Container = try ModelContainer(
            for: v5Schema,
            configurations: [ModelConfiguration(schema: v5Schema, url: url)]
        )
        let v5Context = ModelContext(v5Container)
        let medication = DailyDoseSchemaV5.Medication(name: "Metformin")
        medication.id = "v5-id-1"
        medication.doseDetail = "500 mg"
        medication.formRaw = "pill"
        let scheduled = Fixture.date(2026, 8, 10, 8)
        v5Context.insert(medication)
        v5Context.insert(DailyDoseSchemaV5.DoseEvent(
            medication: medication, scheduledAt: scheduled, statusRaw: "taken", loggedAt: scheduled
        ))
        try v5Context.save()

        let currentSchema = Schema(versionedSchema: DailyDoseSchemaV6.self)
        let container = try ModelContainer(
            for: currentSchema,
            migrationPlan: DailyDoseMigrationPlan.self,
            configurations: [ModelConfiguration(schema: currentSchema, url: url)]
        )
        let context = ModelContext(container)
        let medications = try context.fetch(FetchDescriptor<Medication>())
        let events = try context.fetch(FetchDescriptor<DoseEvent>())

        #expect(medications.count == 1)
        let migrated = try #require(medications.first)
        #expect(migrated.id == "v5-id-1")
        #expect(migrated.doseDetail == "500 mg")
        #expect(migrated.form == .pill)
        // Pre-structure rows arrive unspecified — no invented numbers.
        #expect(migrated.strengthAmount == nil)
        #expect(migrated.strengthUnit == nil)
        #expect(migrated.intakeAmount == nil)

        #expect(events.count == 1)
        #expect(events.first?.medicationName == "Metformin")
        #expect(events.first?.scheduledAt == scheduled)
    }
}
