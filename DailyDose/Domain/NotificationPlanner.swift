import Foundation

/// Decides *which* notifications should exist. Scheduling them is someone
/// else's job (`NotificationService`), and this file deliberately cannot do it —
/// it imports Foundation and nothing more.
///
/// ## Two constraints shape everything here
///
/// **The system ceiling.** iOS keeps at most 64 pending notification requests
/// per app and silently discards the rest. The original implementation
/// scheduled one repeating request per weekday per dose time, so a single
/// medication taken four times daily cost 28 slots and three such medications
/// overflowed — after which iOS dropped requests with no error and no pattern
/// the user could perceive.
///
/// **The attention ceiling.** The harder limit. The REMIND trial found reminder
/// devices alone produced no adherence improvement at all; what worked in later
/// app trials was reminder *plus* one-tap logging *plus* visible feedback. Every
/// notification that doesn't carry an action spends attention without buying
/// adherence — and spends it from the same budget the useful ones draw on.
///
/// So the planner is stingy on purpose:
///
/// 1. **A daily schedule is one repeating trigger per dose time, not seven.**
///    `UNCalendarNotificationTrigger` with only `hour` and `minute` repeats
///    daily — a straight 7× reduction on the commonest schedule.
/// 2. **Medications sharing a dose time collapse into one notification.**
///    Three pills at 08:00 is one alert, not three arriving in the same second.
/// 3. **Escalation is bounded and never nocturnal.** Follow-ups are optional,
///    capped, and suppressed during quiet hours unless the medication is marked
///    important.
enum NotificationPlanner {

    // MARK: - Budget

    /// iOS's hard ceiling. Not ours to change; ours to respect.
    static let systemLimit = 64

    struct Budget: Equatable, Sendable {
        var doses: Int
        var followUps: Int
        var refills: Int

        static let `default` = Budget(doses: 52, followUps: 8, refills: 4)

        var total: Int { doses + followUps + refills }
    }

    // MARK: - Output

    struct PlannedNotification: Identifiable, Equatable, Sendable {
        enum Trigger: Equatable, Sendable {
            /// Repeats every day at this wall-clock time. One slot, forever.
            case daily(TimeOfDay)
            /// Repeats every week. One slot per weekday, forever.
            case weekly(weekday: Int, time: TimeOfDay)
            /// Fires once. Costs a slot until it fires, then frees it.
            case once(Date)
        }

        enum Category: Equatable, Sendable {
            /// One medication, one time — carries Taken / Snooze / Skip actions.
            case dose(medicationID: String, time: TimeOfDay)
            /// Several medications at the same time. Opens the app rather than
            /// carrying actions, because "Taken" is ambiguous across a bundle.
            case doseBundle(medicationIDs: [String], time: TimeOfDay)
            case followUp(medicationID: String, scheduledAt: Date)
            case refill(medicationID: String)
        }

        let id: String
        let category: Category
        let trigger: Trigger
        let title: String
        let body: String
        /// How much this is allowed to interrupt. Drives whether the
        /// notification breaks through Focus.
        let importance: MedicationImportance
        /// The tone to play. Already resolved against importance — a `.gentle`
        /// medication is silent here regardless of what the user picked, so the
        /// service never has to re-derive the rule.
        let sound: NotificationSound
        /// When this will next fire, used for ordering and for tests. For
        /// repeating triggers it is the next matching instant.
        let nextFireDate: Date?

        /// Bundles open the app; single doses log in place.
        var carriesActions: Bool {
            if case .doseBundle = category { return false }
            if case .refill = category { return false }
            return true
        }

        /// Every medication this notification speaks for, whatever its shape —
        /// so a failed add can mark the right medications as deferred.
        var medicationIDs: [String] {
            switch category {
            case .dose(let id, _): [id]
            case .doseBundle(let ids, _): ids
            case .followUp(let id, _): [id]
            case .refill(let id): [id]
            }
        }
    }

    struct Plan: Equatable, Sendable {
        var notifications: [PlannedNotification] = []
        /// Medications whose reminders could not all fit. Surfaced in Settings
        /// so an overflowing schedule is something the user can see and act on,
        /// rather than a silent failure.
        var deferredMedicationIDs: Set<String> = []
    }

    // MARK: - Planning

    static func plan(
        medications: [MedicationSnapshot],
        events: LoggedEventIndex,
        now: Date,
        preferences: NotificationPreferences = .default,
        budget: Budget = .default,
        horizonDays: Int = 90,
        calendar: Calendar = .current
    ) -> Plan {
        var plan = Plan()
        let active = medications.filter { $0.isActive && !$0.schedule.times.isEmpty }

        if preferences.doseRemindersEnabled {
            plan.notifications += planDoseReminders(
                for: active, now: now, preferences: preferences, budget: budget.doses,
                horizonDays: horizonDays, calendar: calendar,
                deferred: &plan.deferredMedicationIDs
            )
        }
        if preferences.doseRemindersEnabled, preferences.followUpEnabled {
            plan.notifications += planFollowUps(
                for: active, events: events, now: now, preferences: preferences,
                limit: budget.followUps, calendar: calendar
            )
        }
        if preferences.refillAlertsEnabled {
            plan.notifications += planRefillAlerts(
                for: active, now: now, preferences: preferences,
                limit: budget.refills, calendar: calendar
            )
        }
        return plan
    }

    // MARK: - Dose reminders

    private static func planDoseReminders(
        for medications: [MedicationSnapshot],
        now: Date,
        preferences: NotificationPreferences,
        budget: Int,
        horizonDays: Int,
        calendar: Calendar,
        deferred: inout Set<String>
    ) -> [PlannedNotification] {

        /// A schedule qualifies for repeating triggers only if it runs forever.
        /// A finite course expressed as "every Tuesday, repeating" would keep
        /// firing months after the prescription ended — worse than no reminder,
        /// because the user would stop trusting the ones that are real.
        func repeatingCost(_ medication: MedicationSnapshot) -> Int? {
            let schedule = medication.schedule
            guard schedule.endDate == nil else { return nil }
            switch schedule.kind {
            case .daily:
                return schedule.times.count
            case .weekdays:
                if schedule.weekdays.count == 7 { return schedule.times.count }
                guard !schedule.weekdays.isEmpty else { return nil }
                return schedule.weekdays.count * schedule.times.count
            case .everyXDays, .monthly:
                // Calendar triggers cannot express "every 21 days".
                return nil
            case .everyXHours, .cycle:
                // Calendar triggers cannot express "every 8 hours" across
                // midnight or "21 on / 7 off". These go through the projected
                // one-shot path, which asks `occurrences(from:to:)` — and that
                // speaks both fluently.
                return nil
            }
        }

        let repeatable = medications.filter { repeatingCost($0) != nil }
        let projected = medications.filter { repeatingCost($0) == nil }

        var notifications: [PlannedNotification] = []
        var spent = 0

        // --- Repeating: grouped so simultaneous doses share one alert. ---
        let groups = repeatingGroups(
            repeatable, bundle: preferences.bundleSimultaneousDoses, sound: preferences.doseSound
        )
        // Cheapest first, so one heavy schedule can never crowd out several
        // light ones. Ties break on key to keep planning deterministic.
        for group in groups.sorted(by: { ($0.cost, $0.sortKey) < ($1.cost, $1.sortKey) }) {
            // Reserve a quarter of the budget for one-shots, so a finite
            // antibiotic course is never starved by ongoing medications.
            let ceiling = projected.isEmpty ? budget : budget - budget / 4
            guard spent + group.cost <= max(ceiling, 1) else {
                deferred.formUnion(group.medications.map(\.id))
                continue
            }
            notifications += group.notifications(now: now, calendar: calendar)
            spent += group.cost
        }

        // --- One-shots: merged across medications, nearest first. ---
        let remaining = max(budget - spent, 0)
        if remaining > 0, !projected.isEmpty,
           let horizonEnd = calendar.date(byAdding: .day, value: horizonDays, to: now) {

            var occurrences: [(medication: MedicationSnapshot, date: Date)] = []
            for medication in projected {
                for date in medication.schedule.occurrences(from: now, to: horizonEnd, calendar: calendar) {
                    occurrences.append((medication, date))
                }
            }

            let slots = bundledOccurrences(
                occurrences, bundle: preferences.bundleSimultaneousDoses, sound: preferences.doseSound
            )
            var scheduledIDs = Set<String>()
            for slot in slots.prefix(remaining) {
                notifications.append(slot.notification(calendar: calendar))
                scheduledIDs.formUnion(slot.medications.map(\.id))
            }
            for medication in projected where !scheduledIDs.contains(medication.id) {
                if medication.schedule.nextOccurrence(after: now, calendar: calendar) != nil {
                    deferred.insert(medication.id)
                }
            }
        } else if !projected.isEmpty {
            deferred.formUnion(projected.map(\.id))
        }

        return notifications
    }

    // MARK: Repeating groups

    /// One entry per (time, weekday-set) that needs a repeating trigger.
    ///
    /// When bundling is on, medications sharing a dose time and importance are
    /// one group — and therefore one notification. When it's off, every
    /// medication is its own group, preserving one-tap logging at the cost of
    /// more alerts.
    private struct RepeatingGroup {
        let medications: [MedicationSnapshot]
        let time: TimeOfDay
        /// `nil` means daily; otherwise the weekdays to repeat on.
        let weekdays: [Int]?
        let importance: MedicationImportance
        let sound: NotificationSound

        var cost: Int { weekdays?.count ?? 1 }

        var sortKey: String {
            "\(time.rawValue)-\(medications.map(\.id).sorted().joined(separator: ","))"
        }

        func notifications(now: Date, calendar: Calendar) -> [PlannedNotification] {
            let ids = medications.map(\.id).sorted()
            let category: PlannedNotification.Category = medications.count == 1
                ? .dose(medicationID: ids[0], time: time)
                : .doseBundle(medicationIDs: ids, time: time)
            let (title, body) = copy(for: medications, time: time)
            let next = medications
                .compactMap { $0.schedule.nextOccurrence(after: now, calendar: calendar) }
                .min()
            let key = medications.count == 1 ? ids[0] : "bundle-\(ids.joined(separator: "_").hashed)"

            guard let weekdays else {
                return [PlannedNotification(
                    id: "dose-\(key)-daily-\(time.rawValue)",
                    category: category, trigger: .daily(time),
                    title: title, body: body, importance: importance,
                    sound: importance.resolvedSound(preferred: sound), nextFireDate: next
                )]
            }
            return weekdays.sorted().map { weekday in
                PlannedNotification(
                    id: "dose-\(key)-w\(weekday)-\(time.rawValue)",
                    category: category, trigger: .weekly(weekday: weekday, time: time),
                    title: title, body: body, importance: importance,
                    sound: importance.resolvedSound(preferred: sound), nextFireDate: next
                )
            }
        }
    }

    private static func repeatingGroups(
        _ medications: [MedicationSnapshot],
        bundle: Bool,
        sound: NotificationSound
    ) -> [RepeatingGroup] {
        // Key on the exact repeat pattern *and* importance: a gentle vitamin
        // must not be folded into an important medication's alert, or it would
        // inherit an urgency it doesn't have (and vice versa).
        struct Key: Hashable {
            let time: TimeOfDay
            let weekdays: [Int]?
            let importance: MedicationImportance
            let isolated: String?   // non-nil when bundling is off
        }

        var grouped: [Key: [MedicationSnapshot]] = [:]
        var order: [Key] = []

        for medication in medications {
            let schedule = medication.schedule
            let isEveryDay = schedule.kind == .daily
                || (schedule.kind == .weekdays && schedule.weekdays.count == 7)
            let weekdays: [Int]? = isEveryDay ? nil : schedule.weekdays.sorted()

            for time in schedule.sortedTimes {
                let key = Key(
                    time: time, weekdays: weekdays, importance: medication.importance,
                    isolated: bundle ? nil : medication.id
                )
                if grouped[key] == nil { order.append(key) }
                grouped[key, default: []].append(medication)
            }
        }

        return order.compactMap { key in
            guard let list = grouped[key] else { return nil }
            return RepeatingGroup(
                medications: list, time: key.time,
                weekdays: key.weekdays, importance: key.importance, sound: sound
            )
        }
    }

    // MARK: One-shot slots

    private struct OccurrenceSlot {
        let medications: [MedicationSnapshot]
        let date: Date
        let importance: MedicationImportance
        let sound: NotificationSound

        func notification(calendar: Calendar) -> PlannedNotification {
            let ids = medications.map(\.id).sorted()
            let time = TimeOfDay(from: date, calendar: calendar)
            let category: PlannedNotification.Category = medications.count == 1
                ? .dose(medicationID: ids[0], time: time)
                : .doseBundle(medicationIDs: ids, time: time)
            let (title, body) = copy(for: medications, time: time)
            let key = medications.count == 1 ? ids[0] : "bundle-\(ids.joined(separator: "_").hashed)"
            return PlannedNotification(
                id: "dose-\(key)-\(Dose.key(for: date))",
                category: category, trigger: .once(date),
                title: title, body: body, importance: importance,
                sound: importance.resolvedSound(preferred: sound), nextFireDate: date
            )
        }
    }

    private static func bundledOccurrences(
        _ occurrences: [(medication: MedicationSnapshot, date: Date)],
        bundle: Bool,
        sound: NotificationSound
    ) -> [OccurrenceSlot] {
        struct Key: Hashable {
            let instant: TimeInterval
            let importance: MedicationImportance
            let isolated: String?
        }

        var grouped: [Key: [MedicationSnapshot]] = [:]
        var dates: [Key: Date] = [:]

        for occurrence in occurrences {
            let key = Key(
                instant: occurrence.date.timeIntervalSinceReferenceDate,
                importance: occurrence.medication.importance,
                isolated: bundle ? nil : occurrence.medication.id
            )
            grouped[key, default: []].append(occurrence.medication)
            dates[key] = occurrence.date
        }

        return grouped.compactMap { key, medications -> OccurrenceSlot? in
            guard let date = dates[key] else { return nil }
            return OccurrenceSlot(
                medications: medications, date: date, importance: key.importance, sound: sound
            )
        }
        .sorted {
            $0.date == $1.date
                ? $0.medications.map(\.id).sorted().joined() < $1.medications.map(\.id).sorted().joined()
                : $0.date < $1.date
        }
    }

    // MARK: - Follow-ups

    /// A single second nudge for a dose that is still unlogged.
    ///
    /// The only escalation the app performs, and the one with a defensible
    /// case: it fires only when the user demonstrably did not act. It is capped,
    /// it never chains, and during quiet hours it is suppressed for everything
    /// except medications the user marked important — a 3 a.m. "you didn't log
    /// your 2:30 dose" is the notification that gets an entire app muted.
    private static func planFollowUps(
        for medications: [MedicationSnapshot],
        events: LoggedEventIndex,
        now: Date,
        preferences: NotificationPreferences,
        limit: Int,
        calendar: Calendar
    ) -> [PlannedNotification] {
        guard limit > 0, let horizon = calendar.date(byAdding: .day, value: 2, to: now) else { return [] }
        let delay = preferences.followUpDelay.interval

        var candidates: [(medication: MedicationSnapshot, scheduledAt: Date, fireAt: Date)] = []
        for medication in medications where medication.importance != .gentle {
            for scheduledAt in medication.schedule.occurrences(from: now - delay, to: horizon, calendar: calendar) {
                guard events.status(medicationID: medication.id, scheduledAt: scheduledAt) == nil else { continue }
                let fireAt = scheduledAt + delay
                guard fireAt > now else { continue }
                // Quiet hours silence the app's own escalations. Scheduled dose
                // reminders are unaffected — the user chose those times.
                if preferences.isQuiet(fireAt, calendar: calendar), medication.importance != .important {
                    continue
                }
                candidates.append((medication, scheduledAt, fireAt))
            }
        }
        candidates.sort {
            $0.fireAt == $1.fireAt ? $0.medication.id < $1.medication.id : $0.fireAt < $1.fireAt
        }

        return candidates.prefix(limit).map { candidate in
            PlannedNotification(
                id: followUpIdentifier(medicationID: candidate.medication.id, scheduledAt: candidate.scheduledAt),
                category: .followUp(medicationID: candidate.medication.id, scheduledAt: candidate.scheduledAt),
                trigger: .once(candidate.fireAt),
                title: String(localized: "Still not logged: \(candidate.medication.name)"),
                body: String(localized: "Scheduled for \(TimeOfDay(from: candidate.scheduledAt, calendar: calendar).formatted()). Tap to log it."),
                importance: candidate.medication.importance,
                sound: candidate.medication.importance.resolvedSound(preferred: preferences.doseSound),
                nextFireDate: candidate.fireAt
            )
        }
    }

    // MARK: - Refill alerts

    private static func planRefillAlerts(
        for medications: [MedicationSnapshot],
        now: Date,
        preferences: NotificationPreferences,
        limit: Int,
        calendar: Calendar
    ) -> [PlannedNotification] {
        guard limit > 0 else { return [] }

        // Lowest supply first: the one about to run out matters most.
        let low = medications
            .filter(\.isLowOnSupply)
            .sorted { ($0.pillsRemaining ?? 0, $0.id) < ($1.pillsRemaining ?? 0, $1.id) }

        var notifications: [PlannedNotification] = []
        for medication in low {
            guard notifications.count < limit else { break }
            // A single daytime nudge, not a daily drumbeat. Supply doesn't
            // change overnight and a repeated alert just teaches dismissal.
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                  let fireAt = preferences.refillAlertTime.date(on: tomorrow, calendar: calendar)
            else { continue }

            let remaining = medication.pillsRemaining ?? 0
            notifications.append(
                PlannedNotification(
                    id: "refill-\(medication.id)",
                    category: .refill(medicationID: medication.id),
                    trigger: .once(fireAt),
                    title: String(localized: "\(medication.name) is running low"),
                    body: remaining <= 0
                        ? String(localized: "No doses left — time for a refill.")
                        : String(localized: "\(remaining) left — plan a refill soon."),
                    // Supply is never urgent enough to break through Focus.
                    importance: .gentle,
                    sound: preferences.refillSound,
                    nextFireDate: fireAt
                )
            )
        }
        return notifications
    }

    // MARK: - Copy

    /// One medication reads as itself; several read as a count plus names, so
    /// the Lock Screen still says what the alert is actually about.
    private static func copy(
        for medications: [MedicationSnapshot],
        time: TimeOfDay
    ) -> (title: String, body: String) {
        guard medications.count > 1 else {
            let medication = medications[0]
            var parts: [String] = []
            if !medication.doseDetail.isEmpty { parts.append(medication.doseDetail) }
            parts.append(time.formatted())
            if !medication.notes.isEmpty { parts.append(medication.notes) }
            return (String(localized: "Time for \(medication.name)"), parts.joined(separator: " · "))
        }
        let names = medications.map(\.name).sorted()
        return (
            String(localized: "\(names.count) medications at \(time.formatted())"),
            names.joined(separator: " · ")
        )
    }

    // MARK: - Identifiers

    /// Identifiers are ASCII and locale-independent by construction, so
    /// cancelling a notification always finds the one it meant to.
    static func doseIdentifier(medicationID: String, date: Date) -> String {
        "dose-\(medicationID)-\(Dose.key(for: date))"
    }

    static func followUpIdentifier(medicationID: String, scheduledAt: Date) -> String {
        "follow-\(medicationID)-\(Dose.key(for: scheduledAt))"
    }
}

private extension String {
    /// Short, stable, ASCII digest for bundle identifiers. Not cryptographic —
    /// it only has to be collision-resistant across one user's medication list
    /// and identical across launches, which `hashValue` is not.
    var hashed: String {
        var hash: UInt64 = 5381
        for byte in utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(hash, radix: 36)
    }
}
