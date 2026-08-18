import Foundation
import SwiftData

/// Export and import of the complete local dataset.
///
/// The app's entire data-safety story is "there is no cloud — export a backup."
/// The previous export made that story false: it silently dropped every
/// scheduling field added after v1 (kind, interval, start date, day of month,
/// end date), keyed events by medication *name* so two medications with the
/// same name merged, and there was no import at all. A backup you cannot
/// restore is not a backup.
///
/// This format is versioned, lossless, and round-trips through
/// `BackupServiceTests.testExportImportRoundTrip`.
enum BackupService {

    static let currentVersion = 3
    static let fileExtension = "dailydose"

    // MARK: - Wire format

    struct Archive: Codable, Equatable {
        var app = "Daily Dose"
        var version = BackupService.currentVersion
        var exportedAt: Date
        var medications: [MedicationRecord]
        var events: [EventRecord]
    }

    struct MedicationRecord: Codable, Equatable {
        var id: String
        var name: String
        var doseDetail: String
        var notes: String
        var colorName: String
        /// Physical form raw value. Optional so archives written before V5
        /// still decode; nil resolves to the default form.
        var formRaw: String? = nil
        var isActive: Bool
        var createdAt: Date

        // Schedule — every field, so a restored course is the same course.
        var scheduleKind: String
        var times: [String]
        var weekdays: [Int]
        var intervalDays: Int
        var dayOfMonth: Int?
        var startDate: Date
        var endDate: Date?
        /// Added in format v3. Optional, so v2 backups still decode; a missing
        /// value simply means the schedule kind that uses it wasn't around yet.
        var intervalHours: Int?
        var cycleOnDays: Int?
        var cycleOffDays: Int?

        var pillsRemaining: Int?
        var refillThreshold: Int?
    }

    struct EventRecord: Codable, Equatable {
        /// Keyed by the medication's stable id, never by its name.
        var medicationID: String
        var medicationName: String
        var medicationColorName: String
        var scheduledAt: Date
        /// The dose's wall-clock identity in the timezone it was logged in —
        /// without it, a backup restored after a move (or onto a phone in
        /// another timezone) would unmoor every dose from its schedule.
        /// Optional so archives written before V4 still decode.
        var scheduledWallKey: String?
        var status: String
        var loggedAt: Date
    }

    // MARK: - Export

    static func makeArchive(medications: [Medication], events: [DoseEvent], now: Date = .now) -> Archive {
        Archive(
            exportedAt: now,
            medications: medications.map { medication in
                let schedule = medication.schedule
                return MedicationRecord(
                    id: medication.id,
                    name: medication.name,
                    doseDetail: medication.doseDetail,
                    notes: medication.notes,
                    colorName: medication.colorName,
                    formRaw: medication.formRaw,
                    isActive: medication.isActive,
                    createdAt: medication.createdAt,
                    scheduleKind: schedule.kind.rawValue,
                    times: schedule.sortedTimes.map(\.rawValue),
                    weekdays: schedule.weekdays.sorted(),
                    intervalDays: schedule.intervalDays,
                    dayOfMonth: schedule.dayOfMonth,
                    startDate: schedule.startDate,
                    endDate: schedule.endDate,
                    intervalHours: schedule.intervalHours,
                    cycleOnDays: schedule.cycleOnDays,
                    cycleOffDays: schedule.cycleOffDays,
                    pillsRemaining: medication.pillsRemaining,
                    refillThreshold: medication.refillThreshold
                )
            },
            events: events.map { event in
                EventRecord(
                    medicationID: event.medicationID,
                    medicationName: event.medicationName,
                    medicationColorName: event.medicationColorName,
                    scheduledAt: event.scheduledAt,
                    scheduledWallKey: event.scheduledWallKey,
                    status: event.status.rawValue,
                    loggedAt: event.loggedAt
                )
            }
        )
    }

    static func encode(_ archive: Archive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> Archive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Archive.self, from: data)
        guard archive.version <= currentVersion else {
            throw BackupError.newerVersion(archive.version)
        }
        return archive
    }

    /// Writes to a uniquely-named file in the temporary directory, ready for
    /// `ShareLink`. The date is formatted with a fixed locale so the filename is
    /// sortable and identical on every device.
    static func writeArchive(_ archive: Archive) throws -> URL {
        let stamp = archive.exportedAt.formatted(
            .iso8601.year().month().day().dateSeparator(.dash)
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-dose-backup-\(stamp).\(fileExtension)")
        try encode(archive).write(to: url, options: .atomic)
        return url
    }

    // MARK: - Import

    struct ImportSummary: Equatable {
        var medicationsAdded = 0
        var medicationsUpdated = 0
        var eventsAdded = 0
        var eventsSkipped = 0
    }

    /// Merges an archive into the store.
    ///
    /// Idempotent: importing the same file twice produces the same result as
    /// importing it once. Medications match on stable id; events match on
    /// (medication id, scheduled minute). Nothing is deleted — a restore can
    /// only ever add back what was lost.
    @MainActor
    static func restore(_ archive: Archive, into context: ModelContext) throws -> ImportSummary {
        var summary = ImportSummary()

        let existingMedications = try context.fetch(FetchDescriptor<Medication>())
        var byID = Dictionary(uniqueKeysWithValues: existingMedications.map { ($0.id, $0) })

        for record in archive.medications {
            let schedule = DoseSchedule(
                kind: ScheduleKind(rawValue: record.scheduleKind) ?? .daily,
                times: Set(record.times.compactMap(TimeOfDay.init)),
                startDate: record.startDate,
                weekdays: Set(record.weekdays),
                intervalDays: record.intervalDays,
                dayOfMonth: record.dayOfMonth,
                intervalHours: record.intervalHours ?? 8,
                cycleOnDays: record.cycleOnDays ?? 21,
                cycleOffDays: record.cycleOffDays ?? 7,
                endDate: record.endDate
            )

            if let existing = byID[record.id] {
                existing.name = record.name
                existing.doseDetail = record.doseDetail
                existing.notes = record.notes
                existing.colorName = record.colorName
                if let formRaw = record.formRaw { existing.formRaw = formRaw }
                existing.isActive = record.isActive
                existing.schedule = schedule
                existing.pillsRemaining = record.pillsRemaining
                existing.refillThreshold = record.refillThreshold
                summary.medicationsUpdated += 1
            } else {
                let medication = Medication(
                    id: record.id,
                    name: record.name,
                    doseDetail: record.doseDetail,
                    notes: record.notes,
                    colorName: record.colorName,
                    schedule: schedule,
                    pillsRemaining: record.pillsRemaining,
                    refillThreshold: record.refillThreshold,
                    form: MedicationForm.named(record.formRaw ?? ""),
                    isActive: record.isActive,
                    createdAt: record.createdAt
                )
                context.insert(medication)
                byID[record.id] = medication
                summary.medicationsAdded += 1
            }
        }

        // Fingerprint existing events so a re-import can't duplicate history.
        let existingEvents = try context.fetch(FetchDescriptor<DoseEvent>())
        var seen = Set(existingEvents.map(Self.fingerprint))

        for record in archive.events {
            let key = Fingerprint(
                medicationID: record.medicationID,
                minute: Self.minuteKey(record.scheduledAt)
            )
            guard !seen.contains(key) else {
                summary.eventsSkipped += 1
                continue
            }
            let event = DoseEvent(
                medicationID: record.medicationID,
                medicationName: record.medicationName,
                medicationColorName: record.medicationColorName,
                scheduledAt: record.scheduledAt,
                status: DoseStatus(rawValue: record.status) ?? .taken,
                loggedAt: record.loggedAt,
                wallKey: record.scheduledWallKey ?? ""
            )
            // Re-link to a live medication when one exists, so the relationship
            // (and cascade-free delete semantics) behave normally afterwards.
            event.medication = byID[record.medicationID]
            context.insert(event)
            seen.insert(key)
            summary.eventsAdded += 1
        }

        try context.save()
        return summary
    }

    private struct Fingerprint: Hashable {
        let medicationID: String
        let minute: Int
    }

    private static func fingerprint(_ event: DoseEvent) -> Fingerprint {
        Fingerprint(medicationID: event.medicationID, minute: minuteKey(event.scheduledAt))
    }

    private static func minuteKey(_ date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate / 60).rounded())
    }
}

enum BackupError: LocalizedError {
    case newerVersion(Int)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .newerVersion(let version):
            String(localized: "This backup was made by a newer version of Daily Dose (format \(version)). Update the app and try again.")
        case .unreadable:
            String(localized: "That file isn't a Daily Dose backup.")
        }
    }
}
