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

/// The schema as shipped before hourly and cycle schedules existed, kept
/// frozen forever. The live `Medication` has since gained `intervalHours`,
/// `cycleOnDays` and `cycleOffDays`; those belong to V3, so V2 keeps its own
/// copies under the original entity names.
enum DailyDoseSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Medication.self, DoseEvent.self]
    }

    @Model
    final class Medication {
        @Attribute(.unique) var id: String = ""
        var name: String
        var doseDetail: String
        var notes: String
        var colorName: String
        var isActive: Bool
        var createdAt: Date
        var timesRaw: [String] = []
        var scheduleKindRaw: String = "daily"
        var weekdaysRaw: [Int] = [1, 2, 3, 4, 5, 6, 7]
        var intervalDays: Int = 1
        var dayOfMonth: Int?
        var startDate: Date = Date.distantPast
        var endDate: Date?
        var pillsRemaining: Int?
        var refillThreshold: Int?
        var importanceRaw: String = "standard"

        @Relationship(deleteRule: .nullify, inverse: \DoseEvent.medication)
        var events: [DoseEvent] = []

        init(
            id: String,
            name: String,
            doseDetail: String,
            notes: String,
            colorName: String,
            isActive: Bool,
            createdAt: Date,
            timesRaw: [String],
            scheduleKindRaw: String,
            weekdaysRaw: [Int],
            intervalDays: Int,
            dayOfMonth: Int?,
            startDate: Date,
            endDate: Date?,
            pillsRemaining: Int?,
            refillThreshold: Int?
        ) {
            self.id = id
            self.name = name
            self.doseDetail = doseDetail
            self.notes = notes
            self.colorName = colorName
            self.isActive = isActive
            self.createdAt = createdAt
            self.timesRaw = timesRaw
            self.scheduleKindRaw = scheduleKindRaw
            self.weekdaysRaw = weekdaysRaw
            self.intervalDays = intervalDays
            self.dayOfMonth = dayOfMonth
            self.startDate = startDate
            self.endDate = endDate
            self.pillsRemaining = pillsRemaining
            self.refillThreshold = refillThreshold
        }
    }

    @Model
    final class DoseEvent {
        var medicationID: String = ""
        var medicationName: String = ""
        var medicationColorName: String = ""
        var scheduledAt: Date
        var loggedAt: Date
        var statusRaw: String

        @Relationship var medication: Medication?

        init(medication: Medication?, scheduledAt: Date, statusRaw: String, loggedAt: Date) {
            self.medication = medication
            self.medicationID = medication?.id ?? ""
            self.medicationName = medication?.name.singleLine ?? ""
            self.medicationColorName = medication?.colorName ?? ""
            self.scheduledAt = scheduledAt
            self.statusRaw = statusRaw
            self.loggedAt = loggedAt
        }
    }
}

/// The schema as shipped before timezone-safe matching existed, kept frozen
/// forever. V4 adds `scheduledWallKey` to `DoseEvent`; V3 therefore keeps its
/// own copies under the original entity names — the standard from here on is
/// that only the *latest* schema may reference the live models.
enum DailyDoseSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Medication.self, DoseEvent.self]
    }

    @Model
    final class Medication {
        @Attribute(.unique) var id: String = ""
        var name: String
        var doseDetail: String
        var notes: String
        var colorName: String
        var isActive: Bool
        var createdAt: Date
        var timesRaw: [String] = []
        var scheduleKindRaw: String = "daily"
        var weekdaysRaw: [Int] = [1, 2, 3, 4, 5, 6, 7]
        var intervalDays: Int = 1
        var dayOfMonth: Int?
        var intervalHours: Int = 8
        var cycleOnDays: Int = 21
        var cycleOffDays: Int = 7
        var startDate: Date = Date.distantPast
        var endDate: Date?
        var pillsRemaining: Int?
        var refillThreshold: Int?
        var importanceRaw: String = "standard"

        @Relationship(deleteRule: .nullify, inverse: \DoseEvent.medication)
        var events: [DoseEvent] = []

        init(name: String) {
            self.name = name
            self.doseDetail = ""
            self.notes = ""
            self.colorName = "teal"
            self.isActive = true
            self.createdAt = .now
        }
    }

    @Model
    final class DoseEvent {
        var medicationID: String = ""
        var medicationName: String = ""
        var medicationColorName: String = ""
        var scheduledAt: Date
        var loggedAt: Date
        var statusRaw: String

        @Relationship var medication: Medication?

        init(medication: Medication?, scheduledAt: Date, statusRaw: String, loggedAt: Date) {
            self.medication = medication
            self.medicationID = medication?.id ?? ""
            self.medicationName = medication?.name.singleLine ?? ""
            self.medicationColorName = medication?.colorName ?? ""
            self.scheduledAt = scheduledAt
            self.statusRaw = statusRaw
            self.loggedAt = loggedAt
        }
    }
}

/// The schema as shipped before medication *form* existed, kept frozen
/// forever. V5 adds `formRaw` to `Medication`; V4 therefore keeps its own
/// copies under the original entity names.
enum DailyDoseSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Medication.self, DoseEvent.self]
    }

    @Model
    final class Medication {
        @Attribute(.unique) var id: String = ""
        var name: String
        var doseDetail: String
        var notes: String
        var colorName: String
        var isActive: Bool
        var createdAt: Date
        var timesRaw: [String] = []
        var scheduleKindRaw: String = "daily"
        var weekdaysRaw: [Int] = [1, 2, 3, 4, 5, 6, 7]
        var intervalDays: Int = 1
        var dayOfMonth: Int?
        var intervalHours: Int = 8
        var cycleOnDays: Int = 21
        var cycleOffDays: Int = 7
        var startDate: Date = Date.distantPast
        var endDate: Date?
        var pillsRemaining: Int?
        var refillThreshold: Int?
        var importanceRaw: String = "standard"

        @Relationship(deleteRule: .nullify, inverse: \DoseEvent.medication)
        var events: [DoseEvent] = []

        init(name: String) {
            self.name = name
            self.doseDetail = ""
            self.notes = ""
            self.colorName = "teal"
            self.isActive = true
            self.createdAt = .now
        }
    }

    @Model
    final class DoseEvent {
        var medicationID: String = ""
        var medicationName: String = ""
        var medicationColorName: String = ""
        var scheduledAt: Date
        var scheduledWallKey: String = ""
        var loggedAt: Date
        var statusRaw: String

        @Relationship var medication: Medication?

        init(medication: Medication?, scheduledAt: Date, statusRaw: String, loggedAt: Date) {
            self.medication = medication
            self.medicationID = medication?.id ?? ""
            self.medicationName = medication?.name.singleLine ?? ""
            self.medicationColorName = medication?.colorName ?? ""
            self.scheduledAt = scheduledAt
            self.statusRaw = statusRaw
            self.loggedAt = loggedAt
        }
    }
}

/// The schema as shipped before structured *strength* existed, kept frozen
/// forever. V6 adds `strengthAmount`, `strengthUnitRaw` and `intakeAmount`
/// to `Medication`; V5 therefore keeps its own copies under the original
/// entity names.
enum DailyDoseSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Medication.self, DoseEvent.self]
    }

    @Model
    final class Medication {
        @Attribute(.unique) var id: String = ""
        var name: String
        var doseDetail: String
        var notes: String
        var colorName: String
        var formRaw: String = ""
        var isActive: Bool
        var createdAt: Date
        var timesRaw: [String] = []
        var scheduleKindRaw: String = "daily"
        var weekdaysRaw: [Int] = [1, 2, 3, 4, 5, 6, 7]
        var intervalDays: Int = 1
        var dayOfMonth: Int?
        var intervalHours: Int = 8
        var cycleOnDays: Int = 21
        var cycleOffDays: Int = 7
        var startDate: Date = Date.distantPast
        var endDate: Date?
        var pillsRemaining: Int?
        var refillThreshold: Int?
        var importanceRaw: String = "standard"

        @Relationship(deleteRule: .nullify, inverse: \DoseEvent.medication)
        var events: [DoseEvent] = []

        init(name: String) {
            self.name = name
            self.doseDetail = ""
            self.notes = ""
            self.colorName = "teal"
            self.isActive = true
            self.createdAt = .now
        }
    }

    @Model
    final class DoseEvent {
        var medicationID: String = ""
        var medicationName: String = ""
        var medicationColorName: String = ""
        var scheduledAt: Date
        var scheduledWallKey: String = ""
        var loggedAt: Date
        var statusRaw: String

        @Relationship var medication: Medication?

        init(medication: Medication?, scheduledAt: Date, statusRaw: String, loggedAt: Date) {
            self.medication = medication
            self.medicationID = medication?.id ?? ""
            self.medicationName = medication?.name.singleLine ?? ""
            self.medicationColorName = medication?.colorName ?? ""
            self.scheduledAt = scheduledAt
            self.statusRaw = statusRaw
            self.loggedAt = loggedAt
        }
    }
}

/// The current schema. This is what the app boots with.
///
/// V6 adds three optional/defaulted columns to `Medication` —
/// `strengthAmount`, `strengthUnitRaw`, `intakeAmount`: strength and
/// per-dose amount as structure rather than free text. All defaulted or
/// optional, so the V5→V6 stage is lightweight and no row is read or
/// rewritten. `doseDetail` stays: it is the composed display line every
/// surface already renders.
enum DailyDoseSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

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
        [DailyDoseSchemaV1.self, DailyDoseSchemaV2.self, DailyDoseSchemaV3.self,
         DailyDoseSchemaV4.self, DailyDoseSchemaV5.self, DailyDoseSchemaV6.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6]
    }

    /// V2 → V3 only adds defaulted columns (`intervalHours`, `cycleOnDays`,
    /// `cycleOffDays`), so the structural migration is sufficient on its own.
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: DailyDoseSchemaV2.self,
        toVersion: DailyDoseSchemaV3.self
    )

    /// V3 → V4 only adds one defaulted column (`scheduledWallKey`), same
    /// reasoning: lightweight, no row is read or rewritten.
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: DailyDoseSchemaV3.self,
        toVersion: DailyDoseSchemaV4.self
    )

    /// V4 → V5 only adds one defaulted column (`formRaw` on Medication).
    static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: DailyDoseSchemaV4.self,
        toVersion: DailyDoseSchemaV5.self
    )

    /// V5 → V6 only adds optional/defaulted columns (`strengthAmount`,
    /// `strengthUnitRaw`, `intakeAmount` on Medication).
    static let migrateV5toV6 = MigrationStage.lightweight(
        fromVersion: DailyDoseSchemaV5.self,
        toVersion: DailyDoseSchemaV6.self
    )

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
            // This context speaks V2 — so it is written with the frozen V2
            // models, never the live ones. The live `Medication` is V3-shaped;
            // inserting it here would either drop the new columns or crash on
            // attributes this context doesn't know. The lightweight V2→V3
            // stage that follows fills the new columns with their defaults.
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

                let medication = DailyDoseSchemaV2.Medication(
                    id: legacy.uuid,
                    name: legacy.name,
                    doseDetail: legacy.doseDetail,
                    notes: legacy.notes,
                    colorName: legacy.colorName,
                    isActive: legacy.isActive,
                    createdAt: legacy.createdAt,
                    timesRaw: schedule.sortedTimes.map(\.rawValue),
                    scheduleKindRaw: schedule.kind.rawValue,
                    weekdaysRaw: schedule.weekdays.sorted(),
                    intervalDays: schedule.intervalDays,
                    dayOfMonth: schedule.dayOfMonth,
                    startDate: schedule.startDate,
                    endDate: schedule.endDate,
                    pillsRemaining: legacy.pillsRemaining,
                    refillThreshold: legacy.refillWarnAt
                )
                context.insert(medication)

                for legacyEvent in legacy.events {
                    context.insert(DailyDoseSchemaV2.DoseEvent(
                        medication: medication,
                        scheduledAt: legacyEvent.scheduledAt,
                        statusRaw: legacyEvent.statusRaw,
                        loggedAt: legacyEvent.loggedAt
                    ))
                }
            }

            try context.save()
        }
    )
}
