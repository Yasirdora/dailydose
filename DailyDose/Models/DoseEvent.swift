import Foundation
import SwiftData

/// One logged dose: taken, skipped, or missed.
///
/// Events are the permanent record. They outlive the medication they belong to
/// — deleting a medication nullifies the relationship rather than cascading —
/// which is why the medication's name and colour are denormalised onto every
/// row. An orphaned event still renders as "Metformin, teal" a year later
/// instead of collapsing into "(deleted)".
@Model
final class DoseEvent {
    /// The medication's stable id, kept even after the medication is gone.
    /// This is what history groups and filters on, not the relationship.
    ///
    /// The empty-string defaults are not conveniences — they are what let the
    /// V1→V2 store migration pass validation. CoreData fills new mandatory
    /// attributes with their defaults during the schema upgrade, then the
    /// custom stage rewrites every row with real values (see
    /// `DailyDoseMigrationPlan`). Without them the store refuses to open.
    var medicationID: String = ""
    /// Denormalised at write time so history survives deletion intact.
    var medicationName: String = ""
    var medicationColorName: String = ""

    /// When the dose was *due*. Every adherence figure in the app is measured
    /// against this, never against `loggedAt` — see `AdherenceCalculator`.
    var scheduledAt: Date
    /// The dose's wall-clock identity — "2026-10-25|08:00" — captured in the
    /// timezone the user was in when this was logged. Absolute instants drift
    /// under timezone travel; this key is what lets a dose taken in Berlin
    /// still match its schedule after the phone lands in Los Angeles.
    /// Empty on rows written before V4; the read path derives a key for them
    /// in the current calendar, preserving the old behaviour for old data.
    var scheduledWallKey: String = ""
    /// When the user (or the missed-dose sweep) actually recorded it. Kept for
    /// provenance and for "logged 3 hours late" style detail, never for stats.
    var loggedAt: Date
    var statusRaw: String

    @Relationship var medication: Medication?

    var status: DoseStatus {
        get { DoseStatus(rawValue: statusRaw) ?? .taken }
        set { statusRaw = newValue.rawValue }
    }

    init(
        medication: Medication,
        scheduledAt: Date,
        status: DoseStatus,
        loggedAt: Date = .now,
        wallKey: String = ""
    ) {
        self.medication = medication
        self.medicationID = medication.id
        self.medicationName = medication.displayName
        self.medicationColorName = medication.colorName
        self.scheduledAt = scheduledAt
        self.scheduledWallKey = wallKey.isEmpty
            ? WallClock.key(for: scheduledAt, calendar: .current)
            : wallKey
        self.statusRaw = status.rawValue
        self.loggedAt = loggedAt
    }

    /// Used by backup import, where no live `Medication` may exist yet.
    init(
        medicationID: String,
        medicationName: String,
        medicationColorName: String,
        scheduledAt: Date,
        status: DoseStatus,
        loggedAt: Date,
        wallKey: String = ""
    ) {
        self.medication = nil
        self.medicationID = medicationID
        self.medicationName = medicationName
        self.medicationColorName = medicationColorName
        self.scheduledAt = scheduledAt
        self.scheduledWallKey = wallKey
        self.statusRaw = status.rawValue
        self.loggedAt = loggedAt
    }

    var record: AdherenceCalculator.Record {
        .init(medicationID: medicationID, scheduledAt: scheduledAt, status: status)
    }

    /// How late the dose was logged, when that's worth showing.
    var loggedLate: TimeInterval? {
        let delta = loggedAt.timeIntervalSince(scheduledAt)
        return delta > DoseCalculator.dueGrace ? delta : nil
    }
}
