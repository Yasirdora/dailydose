import Foundation

/// The editable form state, and the only place that decides whether a
/// medication is valid.
///
/// A value type on purpose: it can be constructed in a test, poked at, and
/// asserted against without a view, a store or a simulator.
struct MedicationDraft: Equatable {
    var name = ""
    var doseDetail = ""
    var notes = ""
    var color = MedicationColor.default

    var kind: ScheduleKind = .daily
    /// A `Set`, so two doses can never occupy the same minute — the condition
    /// that used to render duplicate cards where logging one logged both.
    var times: Set<TimeOfDay> = [.morning]
    var weekdays: Set<Int> = Set(1...7)
    var intervalDays = 2
    var dayOfMonth = Calendar.current.component(.day, from: .now)
    var startDate = Calendar.current.startOfDay(for: .now)
    var endDate: Date?

    var tracksSupply = false
    var pillsRemaining: Int?
    var refillThreshold: Int?

    /// How much this medication may interrupt. Defaults to standard, so the
    /// common case needs no decision from the user.
    var importance: MedicationImportance = .standard

    /// Set when an edit collapsed two times into one, so the UI can explain
    /// why a picker appeared to snap.
    private(set) var hasCollidingTimes = false

    init() {}

    init(medication: Medication?, prefill: LabelScanParser.Result? = nil) {
        guard let medication else {
            if let prefill {
                name = prefill.name
                doseDetail = prefill.strength
            }
            return
        }
        let schedule = medication.schedule
        name = medication.displayName
        doseDetail = medication.doseDetail
        notes = medication.notes
        color = MedicationColor.named(medication.colorName)
        kind = schedule.kind
        times = schedule.times.isEmpty ? [.morning] : schedule.times
        weekdays = schedule.weekdays.isEmpty ? Set(1...7) : schedule.weekdays
        intervalDays = schedule.intervalDays
        dayOfMonth = schedule.dayOfMonth ?? Calendar.current.component(.day, from: schedule.startDate)
        startDate = schedule.startDate
        endDate = schedule.endDate
        tracksSupply = medication.pillsRemaining != nil
        pillsRemaining = medication.pillsRemaining
        refillThreshold = medication.refillThreshold
        importance = medication.importance
    }

    // MARK: - Validation

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isValid: Bool {
        !trimmedName.isEmpty
            && !times.isEmpty
            && (kind != .weekdays || !weekdays.isEmpty)
            && (endDate.map { $0 >= Calendar.current.startOfDay(for: startDate) } ?? true)
    }

    var refillThresholdExceedsSupply: Bool {
        guard tracksSupply, let threshold = refillThreshold, let remaining = pillsRemaining else { return false }
        return threshold > remaining
    }

    /// Supply values are only stored when tracking is on, and are clamped to a
    /// sane range so a typo can't put the counter into a state the UI can't
    /// represent.
    var resolvedPills: Int? {
        guard tracksSupply else { return nil }
        return max(0, min(pillsRemaining ?? 0, 9999))
    }

    var resolvedThreshold: Int? {
        guard tracksSupply else { return nil }
        return max(0, min(refillThreshold ?? 0, 9999))
    }

    // MARK: - Mutation

    mutating func setDaily(dosesPerDay count: Int) {
        kind = .daily
        weekdays = Set(1...7)
        adjustTimeCount(to: count)
    }

    mutating func setKind(_ newKind: ScheduleKind) {
        kind = newKind
        // Sparse schedules take a single time of day; carrying four over from a
        // "4× daily" selection produces a plan nobody asked for.
        if newKind != .daily { adjustTimeCount(to: 1) }
        if newKind == .weekdays, weekdays.isEmpty { weekdays = Set(1...7) }
    }

    /// Grows or shrinks the time list, keeping what the user already chose.
    private mutating func adjustTimeCount(to count: Int) {
        let target = max(1, min(count, 4))
        if times.count > target {
            times = Set(times.sorted().prefix(target))
        } else if times.count < target {
            // Merge in suggestions, skipping any that would collide with an
            // existing choice.
            for suggestion in TimeOfDay.suggested(forDosesPerDay: target) where times.count < target {
                times.insert(suggestion)
            }
            // If suggestions collided, fill forward from the latest time.
            var cursor = times.max() ?? .morning
            while times.count < target {
                guard let next = TimeOfDay(hour: (cursor.hour + 4) % 24, minute: cursor.minute) else { break }
                times.insert(next)
                cursor = next
            }
        }
    }

    mutating func replace(_ old: TimeOfDay, with new: TimeOfDay) {
        var updated = times
        updated.remove(old)
        hasCollidingTimes = updated.contains(new)
        updated.insert(new)
        times = updated
    }

    mutating func apply(_ result: LabelScanParser.Result) {
        if !result.name.isEmpty { name = result.name }
        if !result.strength.isEmpty { doseDetail = result.strength }
    }

    // MARK: - Output

    func buildSchedule() -> DoseSchedule? {
        guard isValid else { return nil }
        return DoseSchedule(
            kind: kind,
            times: times,
            startDate: Calendar.current.startOfDay(for: startDate),
            weekdays: kind == .weekdays ? weekdays : Set(1...7),
            intervalDays: kind == .everyXDays ? intervalDays : 1,
            dayOfMonth: kind == .monthly ? dayOfMonth : nil,
            endDate: endDate
        )
    }

    // MARK: - Copy

    var frequencySummary: String {
        switch kind {
        case .daily:
            switch times.count {
            case 1: String(localized: "Once a day")
            case 2: String(localized: "Twice a day")
            default: String(localized: "\(times.count) times a day")
            }
        case .everyXDays:
            intervalDays == 1
                ? String(localized: "Every day")
                : String(localized: "Every \(intervalDays) days")
        case .weekdays:
            weekdaySummary
        case .monthly:
            String(localized: "Monthly on the \(dayOfMonth.ordinalString())")
        }
    }

    private var weekdaySummary: String {
        let days = weekdays.sorted()
        if days.count == 7 { return String(localized: "Every day") }
        if days.isEmpty { return String(localized: "No days set") }
        let symbols = Calendar.current.shortWeekdaySymbols
        return days
            .compactMap { symbols.indices.contains($0 - 1) ? symbols[$0 - 1] : nil }
            .joined(separator: " · ")
    }

    var durationSummary: String {
        guard let endDate else { return String(localized: "Ongoing") }
        return String(localized: "Until \(endDate.formatted(.dateTime.day().month(.abbreviated)))")
    }

    var accessibilitySummary: String {
        let timeList = times.sorted().map { $0.formatted() }.joined(separator: ", ")
        return "\(trimmedName.isEmpty ? String(localized: "New medication") : trimmedName), \(frequencySummary), \(timeList)"
    }
}
