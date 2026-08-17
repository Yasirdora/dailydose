import Foundation
import SwiftData

/// The persisted schema as the very first builds wrote it, kept frozen forever.
///
/// SwiftData matches entities by name, so the types below keep their original
/// simple names (`Medication`, `DoseEvent`) and their original stored property
/// names — only nested inside this enum so they no longer collide with the
/// current models. Nothing in the app uses these except the migration plan.
enum DailyDoseSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Medication.self, DoseEvent.self]
    }

    @Model
    final class Medication {
        var uuid: String
        var name: String
        var doseDetail: String
        var notes: String
        var colorName: String
        var times: [String]
        var weekdays: [Int]
        var isActive: Bool
        var pillsRemaining: Int?
        var refillWarnAt: Int?
        var createdAt: Date
        var scheduleKindRaw: String?
        var intervalDays: Int?
        var startDate: Date?
        var dayOfMonth: Int?
        var endDate: Date?

        @Relationship(deleteRule: .cascade, inverse: \DoseEvent.medication)
        var events: [DoseEvent] = []

        init(name: String, times: [String]) {
            self.uuid = UUID().uuidString
            self.name = name
            self.doseDetail = ""
            self.notes = ""
            self.colorName = "teal"
            self.times = times
            self.weekdays = [1, 2, 3, 4, 5, 6, 7]
            self.isActive = true
            self.createdAt = .now
        }
    }

    @Model
    final class DoseEvent {
        var scheduledAt: Date
        var statusRaw: String
        var loggedAt: Date
        var medication: Medication?

        init(medication: Medication?, scheduledAt: Date, statusRaw: String, loggedAt: Date) {
            self.medication = medication
            self.scheduledAt = scheduledAt
            self.statusRaw = statusRaw
            self.loggedAt = loggedAt
        }
    }
}

/// The current schema. This is what the app boots with.
enum DailyDoseSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Medication.self, DoseEvent.self]
    }
}

/// V1 → V2, field by field, losing nothing.
///
/// A lightweight migration was never an option: V2 renames stored properties
/// (`times` → `timesRaw`, `refillWarnAt` → `refillThreshold`), makes several
/// optional fields required, and adds `startDate` with no default. So every V1
/// row is read and re-written as a fully-formed V2 row:
///
/// · `uuid` becomes the stable `id`, so notifications and history keep pointing
///   at the right medication.
/// · A missing `startDate` falls back to `createdAt` — the schedule floor is
///   what stops the missed-dose sweep from inventing history, and "the day the
///   medication was added" is the honest floor.
/// · Every dose event is recreated with the medication's name and colour
///   denormalised onto it, so history survives a later deletion intact.
///
/// ## Why the rows are carried as plain values
///
/// Both schemas name their entities `Medication`/`DoseEvent`, so inside
/// `didMigrate` the store's rows are already V2-shaped and fetching the V1
/// model crashes with a cast error. And because several attributes were
/// *renamed*, the structural migration can't carry their values across
/// itself. So `willMigrate` — whose context still speaks V1 — reads every row
/// into a value snapshot and empties the store; `didMigrate` — whose context
/// speaks V2 — inserts brand-new rows from those snapshots. No casts, no
/// mapping-model guesses, nothing lost.
enum DailyDoseMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [DailyDoseSchemaV1.self, DailyDoseSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// Everything a V1 row knew, as a Sendable value. The handoff between the
    /// two migration contexts happens through these, never through models.
    private struct LegacySnapshot: Sendable {
        struct Event: Sendable {
            let scheduledAt: Date
            let statusRaw: String
            let loggedAt: Date
        }
        let uuid: String
        let name: String
        let doseDetail: String
        let notes: String
        let colorName: String
        let times: [String]
        let weekdays: [Int]
        let isActive: Bool
        let pillsRemaining: Int?
        let refillWarnAt: Int?
        let createdAt: Date
        let scheduleKindRaw: String?
        let intervalDays: Int?
        let startDate: Date?
        let dayOfMonth: Int?
        let endDate: Date?
        let events: [Event]
    }

    /// The bridge between `willMigrate` and `didMigrate`. Migration runs on a
    /// background queue, hence the lock.
    private final class LegacyCarry: @unchecked Sendable {
        static let shared = LegacyCarry()
        private let lock = NSLock()
        private var snapshots: [LegacySnapshot] = []

        func replace(_ new: [LegacySnapshot]) {
            lock.lock(); defer { lock.unlock() }
            snapshots = new
        }

        func drain() -> [LegacySnapshot] {
            lock.lock(); defer { lock.unlock() }
            defer { snapshots = [] }
            return snapshots
        }
    }

    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: DailyDoseSchemaV1.self,
        toVersion: DailyDoseSchemaV2.self,
        willMigrate: { context in
            // This context still speaks V1 — the only safe place to read the
            // old rows.
            let legacyMedications = try context.fetch(FetchDescriptor<DailyDoseSchemaV1.Medication>())

            LegacyCarry.shared.replace(legacyMedications.map { legacy in
                LegacySnapshot(
                    uuid: legacy.uuid,
                    name: legacy.name,
                    doseDetail: legacy.doseDetail,
                    notes: legacy.notes,
                    colorName: legacy.colorName,
                    times: legacy.times,
                    weekdays: legacy.weekdays,
                    isActive: legacy.isActive,
                    pillsRemaining: legacy.pillsRemaining,
                    refillWarnAt: legacy.refillWarnAt,
                    createdAt: legacy.createdAt,
                    scheduleKindRaw: legacy.scheduleKindRaw,
                    intervalDays: legacy.intervalDays,
                    startDate: legacy.startDate,
                    dayOfMonth: legacy.dayOfMonth,
                    endDate: legacy.endDate,
                    events: legacy.events.map {
                        .init(scheduledAt: $0.scheduledAt, statusRaw: $0.statusRaw, loggedAt: $0.loggedAt)
                    }
                )
            })

            // Empty the store. The structural migration then maps zero rows,
            // so renamed attributes lose nothing to mapping-model inference.
            // (Events cascade away with their medication.)
            for legacy in legacyMedications { context.delete(legacy) }
            try context.save()
        },
        didMigrate: { context in
            // This context speaks V2. Rebuild every row from the snapshots.
            for legacy in LegacyCarry.shared.drain() {
                let kind = ScheduleKind(rawValue: legacy.scheduleKindRaw ?? "") ?? .weekdays
                let schedule = DoseSchedule(
                    kind: kind,
                    times: Set(legacy.times.compactMap(TimeOfDay.init)),
                    startDate: legacy.startDate ?? legacy.createdAt,
                    weekdays: Set(legacy.weekdays.filter { (1...7).contains($0) }),
                    intervalDays: legacy.intervalDays ?? 1,
                    dayOfMonth: legacy.dayOfMonth,
                    endDate: legacy.endDate
                )

                let medication = Medication(
                    id: legacy.uuid,
                    name: legacy.name,
                    doseDetail: legacy.doseDetail,
                    notes: legacy.notes,
                    colorName: legacy.colorName,
                    schedule: schedule,
                    pillsRemaining: legacy.pillsRemaining,
                    refillThreshold: legacy.refillWarnAt,
                    isActive: legacy.isActive,
                    createdAt: legacy.createdAt
                )
                context.insert(medication)

                for legacyEvent in legacy.events {
                    context.insert(DoseEvent(
                        medication: medication,
                        scheduledAt: legacyEvent.scheduledAt,
                        status: DoseStatus(rawValue: legacyEvent.statusRaw) ?? .taken,
                        loggedAt: legacyEvent.loggedAt
                    ))
                }
            }

            try context.save()
        }
    )
}
