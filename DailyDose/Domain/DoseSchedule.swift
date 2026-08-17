import Foundation

enum ScheduleKind: String, Codable, CaseIterable, Sendable {
    case daily          // every day
    case weekdays       // chosen days of the week
    case everyXDays     // every N days from a start date
    case monthly        // same day each month
    case everyXHours    // every N hours from a first-dose anchor — crosses midnight
    case cycle          // N days on, M days off, repeating (e.g. 21 on / 7 off)
}

/// When a medication is due — the single source of truth for the whole app.
///
/// This is a pure value type. It knows nothing about SwiftData, SwiftUI or
/// notifications, which is exactly why it can be tested exhaustively. The
/// `Medication` model projects into one of these; `DoseCalculator`,
/// `NotificationPlanner` and the calendar all consume it. There is no second
/// implementation of "is this med due today?" anywhere in the codebase.
struct DoseSchedule: Equatable, Sendable {
    var kind: ScheduleKind
    /// A set, not an array: two doses at the same clock time is not a thing
    /// that can be expressed. The old model stored `[String]` and allowed
    /// duplicates, which produced two identical cards where logging one
    /// silently logged both.
    var times: Set<TimeOfDay>
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday. Only read for `.weekdays`.
    var weekdays: Set<Int>
    var intervalDays: Int
    var dayOfMonth: Int?
    /// Only read for `.everyXHours`. The anchor is the first dose's clock time
    /// on `startDate`; every later dose is a whole multiple of this interval
    /// after it — 8 hours means 8 real hours, even across a DST jump, because
    /// that's what the prescription means.
    var intervalHours: Int
    /// Only read for `.cycle`. `cycleOnDays` active days alternate with
    /// `cycleOffDays` rest days; a rest length of 0 degenerates to daily.
    var cycleOnDays: Int
    var cycleOffDays: Int
    /// The day the course begins. **Never optional.**
    ///
    /// This is the fix for the app's worst bug: without a floor, a medication
    /// added today reported that it had been "scheduled" for the past week, and
    /// the missed-dose sweep then wrote seven days of fabricated failures into
    /// the user's history. A schedule now cannot exist without a start.
    var startDate: Date
    /// `nil` means ongoing. Set for finite courses (antibiotics, tapers).
    var endDate: Date?

    init(
        kind: ScheduleKind,
        times: Set<TimeOfDay>,
        startDate: Date,
        weekdays: Set<Int> = Set(1...7),
        intervalDays: Int = 1,
        dayOfMonth: Int? = nil,
        intervalHours: Int = 8,
        cycleOnDays: Int = 21,
        cycleOffDays: Int = 7,
        endDate: Date? = nil
    ) {
        self.kind = kind
        self.times = times
        self.startDate = startDate
        self.weekdays = weekdays
        self.intervalDays = max(1, intervalDays)
        self.dayOfMonth = dayOfMonth
        self.intervalHours = max(1, min(intervalHours, 24))
        self.cycleOnDays = max(1, cycleOnDays)
        self.cycleOffDays = max(0, cycleOffDays)
        self.endDate = endDate
    }

    /// Times in the order a person reads them: earliest first.
    var sortedTimes: [TimeOfDay] { times.sorted() }

    // MARK: - Occurrence

    /// Whether any dose falls on this calendar day.
    func occurs(on day: Date, calendar: Calendar = .current) -> Bool {
        let dayStart = calendar.startOfDay(for: day)

        // Bounds first — they apply to every kind.
        guard dayStart >= calendar.startOfDay(for: startDate) else { return false }
        if let endDate, dayStart > calendar.startOfDay(for: endDate) { return false }
        guard !times.isEmpty else { return false }

        switch kind {
        case .daily:
            return true

        case .weekdays:
            return weekdays.contains(calendar.component(.weekday, from: dayStart))

        case .everyXDays:
            let from = calendar.startOfDay(for: startDate)
            guard let elapsed = calendar.dateComponents([.day], from: from, to: dayStart).day else {
                return false
            }
            return elapsed >= 0 && elapsed % intervalDays == 0

        case .monthly:
            let target = dayOfMonth ?? calendar.component(.day, from: startDate)
            let lastDayOfMonth = calendar.range(of: .day, in: .month, for: dayStart)?.count ?? 31
            // "The 31st" in a 30-day month means the last day, not "skip this month".
            return calendar.component(.day, from: dayStart) == min(target, lastDayOfMonth)

        case .everyXHours:
            // Not day-anchored: ask whether the arithmetic sequence lands
            // inside this day at all.
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }
            return !hourlyOccurrences(from: dayStart, to: dayEnd, calendar: calendar).isEmpty

        case .cycle:
            let from = calendar.startOfDay(for: startDate)
            guard let elapsed = calendar.dateComponents([.day], from: from, to: dayStart).day else {
                return false
            }
            let length = cycleOnDays + cycleOffDays
            guard elapsed >= 0, length > 0 else { return false }
            return elapsed % length < cycleOnDays
        }
    }

    /// Every dose instant in `[start, end)`, ascending.
    ///
    /// Walks day by day rather than jumping, because `.monthly` and DST both
    /// make arithmetic shortcuts wrong. The window is bounded by callers, so
    /// the cost is proportional to the range they actually asked for.
    func occurrences(from start: Date, to end: Date, calendar: Calendar = .current) -> [Date] {
        guard start < end, !times.isEmpty else { return [] }

        // Hourly schedules are a pure arithmetic sequence; walking day by day
        // would still work, but the direct form can't drift and is O(doses).
        if kind == .everyXHours {
            return hourlyOccurrences(from: start, to: end, calendar: calendar)
        }

        var result: [Date] = []
        var day = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)

        while day <= lastDay {
            if occurs(on: day, calendar: calendar) {
                for time in sortedTimes {
                    guard let instant = resolve(time, on: day, calendar: calendar) else { continue }
                    if instant >= start && instant < end { result.append(instant) }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result.sorted()
    }

    /// The first dose instant strictly after `date`, or `nil` within the horizon.
    ///
    /// The horizon defaults to 400 days so sparse schedules — every 90 days,
    /// monthly-on-the-31st — still resolve instead of silently reporting
    /// "no upcoming dose".
    func nextOccurrence(
        after date: Date,
        horizonDays: Int = 400,
        calendar: Calendar = .current
    ) -> Date? {
        guard let end = calendar.date(byAdding: .day, value: horizonDays, to: date) else { return nil }

        if kind == .everyXHours {
            // First multiple of the interval strictly after `date`.
            guard let anchor = anchorInstant(calendar: calendar) else { return nil }
            let interval = TimeInterval(intervalHours * 3600)
            var k = 0
            if date >= anchor {
                k = Int(date.timeIntervalSince(anchor) / interval) + 1
            }
            let next = anchor.addingTimeInterval(TimeInterval(k) * interval)
            guard next <= end else { return nil }
            if let endDate, calendar.startOfDay(for: next) > calendar.startOfDay(for: endDate) {
                return nil
            }
            return next
        }

        var day = calendar.startOfDay(for: date)

        while day <= end {
            if occurs(on: day, calendar: calendar) {
                for time in sortedTimes {
                    if let instant = resolve(time, on: day, calendar: calendar), instant > date {
                        return instant
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    // MARK: - Hourly schedules

    /// The instant the hourly sequence counts from: the first dose's clock
    /// time on the start day. `times` holds exactly one entry for this kind —
    /// the editor enforces it — and this is where it becomes an anchor.
    private func anchorInstant(calendar: Calendar) -> Date? {
        guard let first = sortedTimes.first else { return nil }
        return resolve(first, on: calendar.startOfDay(for: startDate), calendar: calendar)
    }

    /// Every dose instant of an `.everyXHours` schedule in `[start, end)`.
    ///
    /// Computed as `anchor + k · interval` rather than by stepping a clock, so
    /// a daylight-saving jump shifts the wall-clock time but never the number
    /// of real hours between doses — the behaviour a prescriber means when
    /// they write "every 8 hours". Bounded by `endDate` like every other kind.
    private func hourlyOccurrences(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        guard let anchor = anchorInstant(calendar: calendar) else { return [] }
        let interval = TimeInterval(intervalHours * 3600)

        // First index k whose instant is >= start. Division gets us close;
        // the two nudge loops make the boundary exact despite float rounding.
        var k = 0
        if start > anchor {
            k = max(0, Int((start.timeIntervalSince(anchor) / interval).rounded(.up)))
            while anchor.addingTimeInterval(TimeInterval(k) * interval) < start { k += 1 }
            while k > 0, anchor.addingTimeInterval(TimeInterval(k - 1) * interval) >= start { k -= 1 }
        }

        var result: [Date] = []
        var instant = anchor.addingTimeInterval(TimeInterval(k) * interval)
        while instant < end {
            if let endDate,
               calendar.startOfDay(for: instant) > calendar.startOfDay(for: endDate) { break }
            result.append(instant)
            k += 1
            instant = anchor.addingTimeInterval(TimeInterval(k) * interval)
        }
        return result
    }

    /// Resolves a wall-clock time on a day, handling the DST spring-forward gap.
    ///
    /// On the morning the clocks jump, a 02:30 dose has no corresponding
    /// instant. Rather than dropping the dose — which would make it silently
    /// vanish from the day it was prescribed for — we take the first instant
    /// that exists after the gap. That matches what a person does: they take
    /// the pill when they get up, and the hour that was skipped never happens.
    private func resolve(_ time: TimeOfDay, on day: Date, calendar: Calendar) -> Date? {
        if let exact = time.date(on: day, calendar: calendar) {
            // Guard against Foundation rolling a nonexistent time into the next
            // day, which would file the dose under the wrong date.
            if calendar.isDate(exact, inSameDayAs: day) { return exact }
        }
        // Walk forward minute by minute out of the gap (at most one hour).
        for offset in 1...60 {
            let candidate = TimeOfDay(
                hour: (time.hour + (time.minute + offset) / 60) % 24,
                minute: (time.minute + offset) % 60
            )
            if let candidate,
               let resolved = candidate.date(on: day, calendar: calendar),
               calendar.isDate(resolved, inSameDayAs: day) {
                return resolved
            }
        }
        return nil
    }

    // MARK: - Description

    /// "Every day", "Mon · Wed · Fri", "Every 21 days", "Monthly on the 15th",
    /// with " · until 3 Sep" appended for finite courses.
    func summary(calendar: Calendar = .current, locale: Locale = .current) -> String {
        let base: String
        switch kind {
        case .daily:
            base = String(localized: "Every day")

        case .weekdays:
            let days = weekdays.sorted()
            if days.count == 7 {
                base = String(localized: "Every day")
            } else if days.isEmpty {
                base = String(localized: "No days set")
            } else {
                let symbols = calendar.shortWeekdaySymbols   // index 0 == Sunday
                base = days
                    .compactMap { symbols.indices.contains($0 - 1) ? symbols[$0 - 1] : nil }
                    .joined(separator: " · ")
            }

        case .everyXDays:
            base = intervalDays == 1
                ? String(localized: "Every day")
                : String(localized: "Every \(intervalDays) days")

        case .monthly:
            let day = dayOfMonth ?? calendar.component(.day, from: startDate)
            base = String(localized: "Monthly on the \(day.ordinalString(locale: locale))")

        case .everyXHours:
            base = intervalHours == 1
                ? String(localized: "Every hour")
                : String(localized: "Every \(intervalHours) hours")

        case .cycle:
            if cycleOffDays == 0 {
                base = String(localized: "Every day")
            } else {
                base = String(localized: "\(cycleOnDays) days on · \(cycleOffDays) days off")
            }
        }

        guard let endDate else { return base }
        let until = endDate.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        return "\(base) · \(String(localized: "until \(until)"))"
    }

    /// Doses per day, used by the editor's frequency labels.
    var dosesPerDay: Int { times.count }

    /// "Once a day", "Twice a day", "4 times a day" for daily courses; the
    /// cadence in words otherwise. Only `.daily` may use the "times a day"
    /// phrasing — calling a 21/7 cycle "twice a day" would hide the very
    /// thing the user needs to remember.
    /// Plain words, not pharmacy shorthand — understood at 18 and at 80.
    /// One definition shared by the Doses and Meds tabs, so the two can
    /// never describe the same medication differently.
    func frequencySummary(calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard kind == .daily else {
            return summary(calendar: calendar, locale: locale)
        }
        switch dosesPerDay {
        case 1: return String(localized: "Once a day")
        case 2: return String(localized: "Twice a day")
        default: return String(localized: "\(dosesPerDay) times a day")
        }
    }
}

extension Int {
    /// "1st", "2nd", "3rd"… Falls back to the plain number in locales where
    /// `NumberFormatter` has no ordinal style, rather than printing English
    /// suffixes into a German sentence.
    func ordinalString(locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
