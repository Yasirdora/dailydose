import Foundation
import SwiftData

enum DoseStatus: String, Codable {
    case taken, skipped, missed
}

enum ScheduleKind: String, Codable, CaseIterable {
    case daily                  // every day, 1–4 times
    case weekdays               // chosen days of the week
    case everyXDays             // every N days from a start date (e.g. every 21 days)
    case monthly                // same day each month
}

@Model
final class Medication {
    var uuid: String
    var name: String
    var doseDetail: String      // e.g. "500 mg · 1 tablet"
    var notes: String           // e.g. "Take with food"
    var colorName: String       // key into MedPalette
    var times: [String]         // "HH:mm", 24-hour, local time
    var weekdays: [Int]         // Calendar weekday: 1 = Sunday … 7 = Saturday
    var isActive: Bool
    var pillsRemaining: Int?
    var refillWarnAt: Int?
    var createdAt: Date

    // Richer scheduling (added later — optional so legacy stores migrate cleanly).
    // nil scheduleKind = legacy med: decide purely from `weekdays`, as before.
    var scheduleKindRaw: String?
    var intervalDays: Int?      // everyXDays: N
    var startDate: Date?        // everyXDays anchor (and monthly fallback)
    var dayOfMonth: Int?        // monthly: 1…31 (clamped to short months)
    var endDate: Date?          // nil = ongoing

    var scheduleKind: ScheduleKind {
        get { scheduleKindRaw.flatMap(ScheduleKind.init(rawValue:)) ?? .weekdays }
        set { scheduleKindRaw = newValue.rawValue }
    }

    /// The single source of truth for "does this med have doses on this day?"
    /// Used by DoseEngine, notifications, and the calendar.
    func isScheduledOn(_ day: Date, calendar: Calendar = .current) -> Bool {
        let cal = calendar
        let dayStart = cal.startOfDay(for: day)
        if let end = endDate, dayStart > cal.startOfDay(for: end) { return false }
        switch scheduleKind {
        case .daily:
            return true
        case .weekdays:
            // Covers legacy meds (scheduleKindRaw == nil) too.
            return weekdays.contains(cal.component(.weekday, from: day))
        case .everyXDays:
            guard let start = startDate, let n = intervalDays, n > 0 else { return false }
            let from = cal.startOfDay(for: start)
            guard let days = cal.dateComponents([.day], from: from, to: dayStart).day, days >= 0 else { return false }
            return days % n == 0
        case .monthly:
            let dom = dayOfMonth ?? cal.component(.day, from: startDate ?? createdAt)
            let d = cal.component(.day, from: day)
            let last = cal.range(of: .day, in: .month, for: day)?.count ?? 31
            return d == min(dom, last) // 31st → last day of short months
        }
    }

    @Relationship(deleteRule: .cascade, inverse: \DoseEvent.medication)
    var events: [DoseEvent]

    init(name: String,
         doseDetail: String = "",
         notes: String = "",
         colorName: String = "teal",
         times: [String],
         weekdays: [Int] = [1, 2, 3, 4, 5, 6, 7],
         pillsRemaining: Int? = nil,
         refillWarnAt: Int? = nil,
         scheduleKind: ScheduleKind? = nil,
         intervalDays: Int? = nil,
         startDate: Date? = nil,
         dayOfMonth: Int? = nil,
         endDate: Date? = nil) {
        self.uuid = UUID().uuidString
        self.name = name
        self.doseDetail = doseDetail
        self.notes = notes
        self.colorName = colorName
        self.times = times
        self.weekdays = weekdays
        self.isActive = true
        self.pillsRemaining = pillsRemaining
        self.refillWarnAt = refillWarnAt
        self.createdAt = .now
        self.scheduleKindRaw = scheduleKind?.rawValue
        self.intervalDays = intervalDays
        self.startDate = startDate
        self.dayOfMonth = dayOfMonth
        self.endDate = endDate
        self.events = []
    }
}

@Model
final class DoseEvent {    var scheduledAt: Date
    var statusRaw: String
    var loggedAt: Date
    var medication: Medication?

    var status: DoseStatus {
        get { DoseStatus(rawValue: statusRaw) ?? .taken }
        set { statusRaw = newValue.rawValue }
    }

    init(medication: Medication?, scheduledAt: Date, status: DoseStatus, loggedAt: Date = .now) {
        self.medication = medication
        self.scheduledAt = scheduledAt
        self.statusRaw = status.rawValue
        self.loggedAt = loggedAt
    }
}

// MARK: - Human-readable schedule summary

extension Medication {
    /// "Every day", "Every 21 days", "Mon · Wed · Fri", "Monthly on the 15th"…
    var scheduleSummary: String {
        let cal = Calendar.current
        let base: String
        switch scheduleKind {
        case .daily:
            base = "Every day"
        case .weekdays:
            let days = weekdays.sorted()
            if days.count == 7 {
                base = "Every day"
            } else if days.isEmpty {
                base = "No days set"
            } else {
                let symbols = cal.shortWeekdaySymbols // 0 = Sunday
                base = days.map { symbols[$0 - 1] }.joined(separator: " · ")
            }
        case .everyXDays:
            let n = intervalDays ?? 0
            base = n == 1 ? "Every day" : "Every \(n) days"
        case .monthly:
            let dom = dayOfMonth ?? cal.component(.day, from: startDate ?? createdAt)
            base = "Monthly on the \(Self.ordinal(dom))"
        }
        if let endDate {
            return base + " · until " + endDate.formatted(date: .abbreviated, time: .omitted)
        }
        return base
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch n {
        case 1, 21, 31: suffix = "st"
        case 2, 22: suffix = "nd"
        case 3, 23: suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// First unlogged scheduled dose from now on (searches up to 60 days ahead
    /// so sparse schedules like every-21-days and monthly still resolve).
    func nextDose(after now: Date = .now) -> Date? {
        guard isActive, !times.isEmpty else { return nil }
        for offset in 0...60 {
            guard let day = Calendar.current.date(byAdding: .day, value: offset, to: now),
                  isScheduledOn(day) else { continue }
            for time in times.sorted() {
                if let at = DoseEngine.scheduledAt(on: day, time: time),
                   at > now,
                   DoseEngine.loggedEvent(for: self, at: at) == nil {
                    return at
                }
            }
        }
        return nil
    }

    /// Display-safe name: scanned labels can stash multiline text in `name` —
    /// always render the flattened, single-line form.
    var displayName: String { LabelScanParser.flatten(name) }
}
