import Foundation
import SwiftData

enum DoseState: Equatable {
    case upcoming               // not yet near due time
    case due                    // within the actionable window, not logged
    case overdue                // window passed, not yet recorded as missed
    case logged(DoseStatus)
}

struct Dose: Identifiable {
    let medication: Medication
    let scheduledAt: Date
    let state: DoseState

    var id: String {
        "\(medication.uuid)|\(Self.keyFormatter.string(from: scheduledAt))"
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH-mm"
        return f
    }()
}

/// Pure scheduling logic — the source of truth is the SwiftData store;
/// notifications and UI are only projections of this.
enum DoseEngine {
    static let dueGrace: TimeInterval = 15 * 60        // "due" starts 15 min early
    static let missWindow: TimeInterval = 2 * 3600     // auto-missed after 2 h

    static func scheduledAt(on day: Date, time: String) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        comps.hour = parts[0]
        comps.minute = parts[1]
        return Calendar.current.date(from: comps)
    }

    static func doses(on day: Date, meds: [Medication], now: Date = .now) -> [Dose] {
        var result: [Dose] = []
        for med in meds where med.isActive {
            guard med.isScheduledOn(day) else { continue }
            for time in med.times.sorted() {
                guard let at = scheduledAt(on: day, time: time) else { continue }
                let state: DoseState
                if let event = loggedEvent(for: med, at: at) {
                    state = .logged(event.status)
                } else if now < at - dueGrace {
                    state = .upcoming
                } else if now <= at + missWindow {
                    state = .due
                } else {
                    state = .overdue
                }
                result.append(Dose(medication: med, scheduledAt: at, state: state))
            }
        }
        return result.sorted { $0.scheduledAt < $1.scheduledAt }
    }

    /// Progress of one calendar day: doses taken out of doses scheduled.
    /// Powers the per-day rings in the week strip and the calendar sheet.
    static func dayProgress(on day: Date, meds: [Medication], now: Date = .now) -> (taken: Int, total: Int) {
        let dayDoses = doses(on: day, meds: meds, now: now)
        let taken = dayDoses.filter { if case .logged(.taken) = $0.state { return true }; return false }.count
        return (taken, dayDoses.count)
    }

    static func loggedEvent(for med: Medication, at: Date) -> DoseEvent? {
        med.events.first { abs($0.scheduledAt.timeIntervalSince(at)) < 60 }
    }

    /// Records "missed" for every unlogged dose whose 2-hour window has passed,
    /// across the last 7 days, so history stays honest even if the app wasn't opened.
    static func recordMissedDoses(meds: [Medication], context: ModelContext, now: Date = .now) {
        guard let startDay = Calendar.current.date(byAdding: .day, value: -7, to: now) else { return }
        for offset in 0...7 {
            guard let day = Calendar.current.date(byAdding: .day, value: offset, to: startDay) else { continue }
            for dose in doses(on: day, meds: meds, now: now) where dose.state == .overdue {
                context.insert(DoseEvent(medication: dose.medication, scheduledAt: dose.scheduledAt, status: .missed))
            }
        }
        try? context.save()
    }

    static func log(med: Medication, at: Date, status: DoseStatus, context: ModelContext) {
        if let existing = loggedEvent(for: med, at: at) {
            existing.status = status
            existing.loggedAt = .now
        } else {
            context.insert(DoseEvent(medication: med, scheduledAt: at, status: status))
        }
        if status == .taken, let remaining = med.pillsRemaining, remaining > 0 {
            med.pillsRemaining = remaining - 1
        }
        try? context.save()
    }

    /// Removes a logged event (Undo), restoring the pill count if it was a "taken".
    static func unlog(med: Medication, at: Date, context: ModelContext) {
        guard let existing = loggedEvent(for: med, at: at) else { return }
        if existing.status == .taken, let remaining = med.pillsRemaining {
            med.pillsRemaining = remaining + 1
        }
        context.delete(existing)
        try? context.save()
    }

    /// Most recent actual occurrence of a given med+time at or before `now`
    /// (used when answering a notification action, where the day is implicit).
    static func mostRecentScheduledAt(med: Medication, time: String, now: Date = .now) -> Date? {
        // 40 days back covers sparse schedules too (e.g. every 21 days, monthly).
        for offset in 0...40 {
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { continue }
            guard med.isScheduledOn(day) else { continue }
            if let at = scheduledAt(on: day, time: time), at <= now { return at }
        }
        return nil
    }

    static func adherence(events: [DoseEvent], days: Int, now: Date = .now)
        -> (taken: Int, skipped: Int, missed: Int, percent: Int?) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
            return (0, 0, 0, nil)
        }
        let recent = events.filter { $0.loggedAt >= cutoff }
        let taken = recent.filter { $0.status == .taken }.count
        let skipped = recent.filter { $0.status == .skipped }.count
        let missed = recent.filter { $0.status == .missed }.count
        let total = taken + skipped + missed
        let percent = total > 0 ? Int(round(100.0 * Double(taken) / Double(total))) : nil
        return (taken, skipped, missed, percent)
    }
}
