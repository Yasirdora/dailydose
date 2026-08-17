import Foundation
import SwiftData

/// A medication and its schedule, as stored.
///
/// The persisted shape is deliberately dull — strings, ints, optionals — so
/// SwiftData migrations stay boring. All meaning lives in the `schedule`
/// projection, which hands the domain layer a fully-formed `DoseSchedule`.
/// Nothing outside this file interprets `timesRaw` or `scheduleKindRaw`.
@Model
final class Medication {
    /// A stable identifier that outlives the object. Notification payloads and
    /// history rows reference this, so it must never change and must survive
    /// deletion of the medication itself.
    ///
    /// The default is not a convenience — like `DoseEvent`'s denormalised
    /// fields, it lets the V1→V2 store migration pass validation. CoreData
    /// fills the attribute with the default during the schema upgrade, then
    /// the custom stage writes each row's real `uuid` (see
    /// `DailyDoseMigrationPlan`). Without it the store refuses to open.
    @Attribute(.unique) var id: String = ""

    var name: String
    var doseDetail: String
    var notes: String
    var colorName: String
    var isActive: Bool
    var createdAt: Date

    // MARK: Schedule (persisted form)

    // The defaults below exist for the V1→V2 store migration, not for app
    // code: CoreData fills new or renamed mandatory attributes with their
    // defaults during the schema upgrade, then the custom stage writes every
    // row's real values (see `DailyDoseMigrationPlan`). Without them the
    // store refuses to open — validation fails before the stage ever runs.

    /// `"HH:mm"` strings. Read through `schedule`, never directly.
    var timesRaw: [String] = []
    var scheduleKindRaw: String = ScheduleKind.daily.rawValue
    var weekdaysRaw: [Int] = [1, 2, 3, 4, 5, 6, 7]
    var intervalDays: Int = 1
    var dayOfMonth: Int?
    /// The day the course begins. Non-optional by design — see `DoseSchedule`.
    var startDate: Date = Date.distantPast
    var endDate: Date?

    // MARK: Supply

    var pillsRemaining: Int?
    var refillThreshold: Int?

    // MARK: Notification behaviour

    /// How much this medication may interrupt. Stored raw so a future case can
    /// be added without a migration. Defaulted, so it lightweight-migrates.
    var importanceRaw: String = MedicationImportance.standard.rawValue

    /// `.nullify`, not `.cascade`.
    ///
    /// Deleting a medication must not erase the record of doses already taken.
    /// The app tells the user "its history stays in your records" — with a
    /// cascade rule that sentence was false and the history was destroyed.
    /// Events keep a denormalised name and colour so an orphaned row still
    /// reads as a real medication rather than "(deleted)".
    @Relationship(deleteRule: .nullify, inverse: \DoseEvent.medication)
    var events: [DoseEvent] = []

    init(
        id: String = UUID().uuidString,
        name: String,
        doseDetail: String = "",
        notes: String = "",
        colorName: String = MedicationColor.default.rawValue,
        schedule: DoseSchedule,
        pillsRemaining: Int? = nil,
        refillThreshold: Int? = nil,
        importance: MedicationImportance = .standard,
        isActive: Bool = true,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.doseDetail = doseDetail
        self.notes = notes
        self.colorName = colorName
        self.isActive = isActive
        self.createdAt = createdAt
        self.pillsRemaining = pillsRemaining
        self.refillThreshold = refillThreshold
        self.importanceRaw = importance.rawValue

        self.timesRaw = schedule.sortedTimes.map(\.rawValue)
        self.scheduleKindRaw = schedule.kind.rawValue
        self.weekdaysRaw = schedule.weekdays.sorted()
        self.intervalDays = schedule.intervalDays
        self.dayOfMonth = schedule.dayOfMonth
        self.startDate = schedule.startDate
        self.endDate = schedule.endDate
    }
}

// MARK: - Schedule projection

extension Medication {
    /// The medication's schedule as a value type.
    ///
    /// Setting this writes every persisted schedule field at once, so the stored
    /// representation can never drift out of sync with itself — the class of bug
    /// where a medication was switched to "monthly" but kept stale weekday data.
    var schedule: DoseSchedule {
        get {
            DoseSchedule(
                kind: ScheduleKind(rawValue: scheduleKindRaw) ?? .daily,
                times: Set(timesRaw.compactMap(TimeOfDay.init)),
                startDate: startDate,
                weekdays: Set(weekdaysRaw.filter { (1...7).contains($0) }),
                intervalDays: intervalDays,
                dayOfMonth: dayOfMonth,
                endDate: endDate
            )
        }
        set {
            timesRaw = newValue.sortedTimes.map(\.rawValue)
            scheduleKindRaw = newValue.kind.rawValue
            weekdaysRaw = newValue.weekdays.sorted()
            intervalDays = newValue.intervalDays
            dayOfMonth = newValue.dayOfMonth
            startDate = newValue.startDate
            endDate = newValue.endDate
        }
    }

    var importance: MedicationImportance {
        get { MedicationImportance(rawValue: importanceRaw) ?? .standard }
        set { importanceRaw = newValue.rawValue }
    }

    /// The read-only value passed into the domain layer.
    var snapshot: MedicationSnapshot {
        MedicationSnapshot(
            id: id,
            name: displayName,
            doseDetail: doseDetail,
            notes: notes,
            colorName: colorName,
            isActive: isActive,
            schedule: schedule,
            pillsRemaining: pillsRemaining,
            refillThreshold: refillThreshold,
            importance: importance
        )
    }

    /// Scanned labels can carry multi-line OCR text. Every surface renders this,
    /// never the raw `name`, so a scan can't break a navigation bar or a dialog.
    var displayName: String { name.singleLine }

    var isLowOnSupply: Bool {
        guard let pillsRemaining, let refillThreshold else { return false }
        return pillsRemaining <= refillThreshold
    }

    var needsSchedule: Bool { timesRaw.isEmpty }
}

extension String {
    /// Collapses any newline flavour into single spaces and trims the result.
    var singleLine: String {
        components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
