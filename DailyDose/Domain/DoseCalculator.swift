import Foundation

enum DoseStatus: String, Codable, CaseIterable, Sendable {
    case taken, skipped, missed
}

/// Where a dose sits in its lifecycle.
enum DoseState: Equatable, Sendable {
    /// Not yet in the actionable window.
    case upcoming
    /// Actionable now: within `dueGrace` before, through `missWindow` after.
    case due
    /// The window has closed and nothing was logged. Still correctable.
    case overdue
    case logged(DoseStatus)

    var isLogged: Bool { if case .logged = self { return true }; return false }
    var isActionable: Bool { self == .due || self == .overdue }
}

/// How the interface names an unlogged dose's timing.
///
/// The vocabulary is deliberately the one patients already hear from
/// pharmacists: a dose is *due*, then *late* (still safe to take — NHS
/// guidance and the adherence literature both treat lateness as recoverable),
/// then *missed*. A fourth tag ("overdue") was considered and rejected:
/// users can't feel the difference between overdue and late, and clinically
/// there is only one question — can I still take it safely?
enum DoseTimingTag: Equatable, Sendable {
    case scheduled
    case dueNow
    case late
    case missed
}

/// A single scheduled dose, resolved against what the user actually logged.
struct Dose: Identifiable, Equatable, Sendable {
    let medicationID: String
    let scheduledAt: Date
    let state: DoseState

    /// Stable across recomputation and safe in notification identifiers:
    /// built from the medication's UUID and an ISO-8601 timestamp, never from
    /// a locale-dependent `DateFormatter`.
    var id: String { "\(medicationID)|\(Dose.key(for: scheduledAt))" }

    static func key(for date: Date) -> String {
        date.ISO8601Format(.iso8601(timeZone: .gmt))
    }
}

/// Turns schedules plus logged events into the doses the UI renders.
///
/// Pure and synchronous: give it snapshots, get answers. Nothing here reads a
/// database or touches the clock except through the `now` you pass in, which is
/// what makes "what happens at 2am on the DST boundary" a test rather than a
/// bug report.
enum DoseCalculator {
    /// A dose becomes actionable 15 minutes before its time — early enough to
    /// be useful when the reminder arrives, not so early it invites double-dosing.
    static let dueGrace: TimeInterval = 15 * 60
    /// "Due now" lasts until 30 minutes after the scheduled time. Beyond that
    /// the dose is *late* — still takeable, no longer on time.
    static let dueAfterGrace: TimeInterval = 30 * 60
    /// A dose may be logged up to two hours *early* — real life has
    /// appointments and travel, and 1–2 hours early is the commonly cited
    /// acceptable window for most oral medication. The actual time is always
    /// recorded, so "took the 08:00 dose at 06:45" stays an honest record.
    static let earlyGrace: TimeInterval = 2 * 3600
    /// The fallback window, used only where no preference is available (tests,
    /// previews). Real call sites pass the user's `DoseWindow` — see
    /// `TrackingPreferences`, where the reasoning lives.
    static let missWindow: TimeInterval = 2 * 3600

    /// Everything scheduled on `day`, ascending, with each dose's current state.
    static func doses(
        on day: Date,
        medications: [MedicationSnapshot],
        events: LoggedEventIndex,
        now: Date,
        window: DoseWindow = .default,
        calendar: Calendar = .current
    ) -> [Dose] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        var result: [Dose] = []
        for medication in medications where medication.isActive {
            for at in medication.schedule.occurrences(from: dayStart, to: dayEnd, calendar: calendar) {
                result.append(
                    Dose(medicationID: medication.id,
                         scheduledAt: at,
                         state: state(for: medication.id, at: at, events: events,
                                      now: now, window: window, calendar: calendar))
                )
            }
        }
        return result.sorted { $0.scheduledAt < $1.scheduledAt }
    }

    /// Faster path used by the calendar and week strip, which need counts and
    /// not the doses themselves. Avoids building `Dose` values for 400 days.
    static func progress(
        on day: Date,
        medications: [MedicationSnapshot],
        events: LoggedEventIndex,
        now: Date,
        window: DoseWindow = .default,
        calendar: Calendar = .current
    ) -> DayProgress {
        var taken = 0
        var total = 0
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return DayProgress(taken: 0, total: 0)
        }
        for medication in medications where medication.isActive {
            guard medication.schedule.occurs(on: dayStart, calendar: calendar) else { continue }
            for at in medication.schedule.occurrences(from: dayStart, to: dayEnd, calendar: calendar) {
                total += 1
                if case .logged(.taken) = state(for: medication.id, at: at, events: events,
                                                now: now, window: window, calendar: calendar) {
                    taken += 1
                }
            }
        }
        return DayProgress(taken: taken, total: total)
    }

    static func state(
        for medicationID: String,
        at scheduledAt: Date,
        events: LoggedEventIndex,
        now: Date,
        window: DoseWindow = .default,
        calendar: Calendar = .current
    ) -> DoseState {
        if let status = events.status(medicationID: medicationID, scheduledAt: scheduledAt) {
            return .logged(status)
        }
        if now < scheduledAt - dueGrace { return .upcoming }
        if now <= window.deadline(for: scheduledAt, calendar: calendar) { return .due }
        return .overdue
    }

    /// The timing tag an unlogged dose wears right now: scheduled → due now →
    /// late → missed. The late→missed boundary is the user's `DoseWindow`
    /// preference, so a strict regimen and a relaxed vitamin never share one
    /// silent constant.
    static func timingTag(
        for scheduledAt: Date,
        now: Date,
        window: DoseWindow = .default,
        calendar: Calendar = .current
    ) -> DoseTimingTag {
        if now < scheduledAt - dueGrace { return .scheduled }
        if now <= scheduledAt + dueAfterGrace { return .dueNow }
        if now <= window.deadline(for: scheduledAt, calendar: calendar) { return .late }
        return .missed
    }

    /// Doses whose window closed without a log, so they can be written to
    /// history as `.missed`.
    ///
    /// The schedule's own `startDate` floor guarantees this can never reach
    /// back before a medication existed — the bug that used to greet every new
    /// user with a week of failures they never had.
    static func unloggedOverdueDoses(
        medications: [MedicationSnapshot],
        events: LoggedEventIndex,
        lookbackDays: Int,
        now: Date,
        window: DoseWindow = .default,
        calendar: Calendar = .current
    ) -> [Dose] {
        guard let from = calendar.date(byAdding: .day, value: -lookbackDays, to: now) else { return [] }
        var result: [Dose] = []

        for medication in medications where medication.isActive {
            // Scan to `now` and test each occurrence against its own deadline.
            // A single global cutoff can't express `.untilEndOfDay`, where the
            // deadline depends on which day the dose belongs to.
            for at in medication.schedule.occurrences(from: from, to: now, calendar: calendar) {
                guard window.deadline(for: at, calendar: calendar) < now else { continue }
                guard events.status(medicationID: medication.id, scheduledAt: at) == nil else { continue }
                result.append(Dose(medicationID: medication.id, scheduledAt: at, state: .overdue))
            }
        }
        return result
    }
}

struct DayProgress: Equatable, Sendable {
    var taken: Int
    var total: Int

    var fraction: Double { total > 0 ? Double(taken) / Double(total) : 0 }
    var isComplete: Bool { total > 0 && taken == total }
}

/// O(1) lookup of "did the user log this dose?".
///
/// The previous implementation scanned a medication's entire event array for
/// every dose on every render — quadratic in history size, and the reason the
/// calendar sheet stalled after a few months of use. Building this index once
/// per pass makes the same question constant-time.
struct LoggedEventIndex: Sendable {
    /// Doses are matched to logs on a 60-second key, so a log recorded a few
    /// milliseconds off the scheduled instant still matches. `TimeOfDay` being
    /// a set guarantees two doses can never collide inside that window.
    private var storage: [Key: DoseStatus]

    private struct Key: Hashable, Sendable {
        let medicationID: String
        let minute: Int
    }

    init(_ events: [(medicationID: String, scheduledAt: Date, status: DoseStatus)]) {
        storage = [:]
        storage.reserveCapacity(events.count)
        for event in events {
            storage[Key(medicationID: event.medicationID, minute: Self.minuteKey(event.scheduledAt))] = event.status
        }
    }

    static let empty = LoggedEventIndex([])

    func status(medicationID: String, scheduledAt: Date) -> DoseStatus? {
        storage[Key(medicationID: medicationID, minute: Self.minuteKey(scheduledAt))]
    }

    /// Minutes since the reference date, rounded — the one key both the read
    /// path (this index) and the write path (`DoseStore.existingEvent`) match
    /// on, so they can never disagree about which dose a log belongs to.
    static func minuteKey(_ date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate / 60).rounded())
    }
}

/// A read-only projection of a `Medication` for the pure layer.
///
/// The domain never imports SwiftData. Passing snapshots instead of models is
/// what lets the scheduler, calculator and planner be tested with plain structs
/// and no in-memory store.
struct MedicationSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let doseDetail: String
    let notes: String
    let colorName: String
    let isActive: Bool
    let schedule: DoseSchedule
    let pillsRemaining: Int?
    let refillThreshold: Int?
    /// How much this medication is allowed to interrupt. A vitamin and a heart
    /// medication should not arrive with the same urgency.
    var importance: MedicationImportance = .standard

    var isLowOnSupply: Bool {
        guard let pillsRemaining, let refillThreshold else { return false }
        return pillsRemaining <= refillThreshold
    }

    /// A medication with no dose times can never remind. The UI badges these so
    /// they don't sit in the list looking scheduled while doing nothing — the
    /// state every Apple Health import used to land in.
    var needsSchedule: Bool { schedule.times.isEmpty }
}
