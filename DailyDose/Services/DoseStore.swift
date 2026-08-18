import Foundation
import SwiftData
import Observation

/// The single owner of every write to the data store.
///
/// Previously, views mutated models directly and called `try? context.save()`
/// inline — six different files, each with its own idea of what had to happen
/// afterwards, and a `Task { rescheduleAll() }` sprinkled in wherever someone
/// remembered. Reminders went stale because a code path forgot.
///
/// Now views describe intent (`log`, `undo`, `save`, `delete`) and this type
/// guarantees the invariants: the write succeeds or surfaces, supply stays
/// consistent, and the notification plan is rebuilt exactly once afterwards.
@MainActor
@Observable
final class DoseStore {

    private let context: ModelContext
    private let notifications: NotificationScheduling

    /// Read on every reschedule so a settings change takes effect immediately.
    var preferences: NotificationPreferences = .load() {
        didSet {
            guard preferences != oldValue else { return }
            rescheduleNotifications()
        }
    }

    /// How the app interprets doses — currently just how long one stays
    /// actionable. Changing it re-runs the missed sweep, because the meaning of
    /// "missed" has just changed for every dose in the lookback window.
    var tracking: TrackingPreferences = .load() {
        didSet {
            guard tracking != oldValue else { return }
            recordMissedDoses()
        }
    }

    /// Shorthand for the value every calculator call needs.
    var doseWindow: DoseWindow { tracking.doseWindow }

    /// Set when a write fails. Views present it; nothing is swallowed.
    var lastError: StoreError?

    /// Bumped on every successful save. SwiftData's `@Query` compares model
    /// arrays by persistent identity, so editing a schedule produces an
    /// *equal* array and `onChange(of: medications)` never fires — the
    /// screen keeps showing a time the store no longer holds. Observing this
    /// counter instead makes every write a rebuild.
    private(set) var revision = 0

    /// Medications whose reminders exceeded the notification budget.
    /// Surfaced in Settings so an unschedulable setup is visible, not silent.
    private(set) var deferredMedicationIDs: Set<String> = []

    init(context: ModelContext, notifications: NotificationScheduling) {
        self.context = context
        self.notifications = notifications
    }

    // MARK: - Reading

    func medications() -> [Medication] {
        let descriptor = FetchDescriptor<Medication>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func snapshots() -> [MedicationSnapshot] {
        medications().map(\.snapshot)
    }

    /// Builds the O(1) dose-lookup index over a bounded window.
    ///
    /// Bounded on purpose. The old code held every event ever recorded in memory
    /// and scanned it linearly per dose; this fetches only what the caller will
    /// actually consult.
    ///
    /// Each event's stored wall-clock key travels with it, so a dose logged in
    /// one timezone still matches its schedule after the phone changes timezone.
    func loggedEvents(from: Date, to: Date) -> LoggedEventIndex {
        var descriptor = FetchDescriptor<DoseEvent>(
            predicate: #Predicate { $0.scheduledAt >= from && $0.scheduledAt <= to }
        )
        descriptor.propertiesToFetch = [\.medicationID, \.scheduledAt, \.statusRaw, \.scheduledWallKey]
        let events = (try? context.fetch(descriptor)) ?? []
        return LoggedEventIndex(keyedEvents: events.map {
            ($0.medicationID, $0.scheduledAt, $0.scheduledWallKey, $0.status)
        })
    }

    func adherenceRecords(since: Date) -> [AdherenceCalculator.Record] {
        let descriptor = FetchDescriptor<DoseEvent>(
            predicate: #Predicate { $0.scheduledAt >= since },
            sortBy: [SortDescriptor(\.scheduledAt, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map(\.record)
    }

    func recentEvents(limit: Int) -> [DoseEvent] {
        var descriptor = FetchDescriptor<DoseEvent>(
            sortBy: [SortDescriptor(\.scheduledAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func medication(id: String) -> Medication? {
        var descriptor = FetchDescriptor<Medication>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Logging a dose

    /// Records (or corrects) the outcome of a dose.
    ///
    /// Supply is adjusted by the *difference* between the old and new status.
    /// The previous implementation decremented on every write to `.taken`
    /// without reversing an earlier decrement, so correcting a mistake — taken,
    /// then skipped, then taken again — quietly consumed two pills from a
    /// count the user was trusting for refill alerts.
    func log(medicationID: String, scheduledAt: Date, status: DoseStatus, loggedAt: Date = .now) {
        guard let medication = medication(id: medicationID) else { return }

        let existing = existingEvent(medicationID: medicationID, scheduledAt: scheduledAt)
        let previousStatus = existing?.status

        if let existing {
            existing.status = status
            existing.loggedAt = loggedAt
        } else {
            context.insert(DoseEvent(medication: medication, scheduledAt: scheduledAt,
                                     status: status, loggedAt: loggedAt))
        }

        applySupplyDelta(to: medication, from: previousStatus, to: status)
        persist()
        rescheduleNotifications()
    }

    /// Removes a log entirely, returning the dose to its unlogged state.
    func undoLog(medicationID: String, scheduledAt: Date) {
        guard let event = existingEvent(medicationID: medicationID, scheduledAt: scheduledAt) else { return }
        if let medication = medication(id: medicationID) {
            applySupplyDelta(to: medication, from: event.status, to: nil)
        }
        context.delete(event)
        persist()
        rescheduleNotifications()
    }

    /// A taken dose consumes one unit; anything else consumes none. Expressing
    /// it as a transition makes every correction path self-balancing.
    private func applySupplyDelta(to medication: Medication, from old: DoseStatus?, to new: DoseStatus?) {
        guard medication.pillsRemaining != nil else { return }
        let consumedBefore = old == .taken ? 1 : 0
        let consumedAfter = new == .taken ? 1 : 0
        let delta = consumedAfter - consumedBefore
        guard delta != 0 else { return }
        medication.pillsRemaining = max(0, (medication.pillsRemaining ?? 0) - delta)
    }

    private func existingEvent(medicationID: String, scheduledAt: Date) -> DoseEvent? {
        // Fetch a generous window, then match on the same rounded-minute key
        // `LoggedEventIndex` reads with. The old ±60s *inclusive* range would
        // resolve an 08:01 log to the 08:00 dose — two scheduled times a
        // minute apart overwriting each other, read and write disagreeing
        // about which dose a log belonged to.
        let lower = scheduledAt.addingTimeInterval(-90)
        let upper = scheduledAt.addingTimeInterval(90)
        var descriptor = FetchDescriptor<DoseEvent>(
            predicate: #Predicate {
                $0.medicationID == medicationID && $0.scheduledAt >= lower && $0.scheduledAt < upper
            }
        )
        descriptor.fetchLimit = 4
        let key = LoggedEventIndex.minuteKey(scheduledAt)
        return (try? context.fetch(descriptor))?
            .first { LoggedEventIndex.minuteKey($0.scheduledAt) == key }
    }

    // MARK: - Missed-dose sweep

    /// Writes `.missed` for doses whose window closed unlogged, so history stays
    /// honest even when the app wasn't opened for days.
    ///
    /// The lookback must cover the longest report the app can produce — 30
    /// days. Anything shorter silently inflates adherence: adherence is
    /// counted from recorded events, so an unlogged dose older than the sweep
    /// never enters the denominator at all, and a month report would show
    /// 100% for three weeks that were simply never swept.
    ///
    /// Safe by construction now: `DoseSchedule` cannot produce an occurrence
    /// before its own `startDate`, so this can never invent misses for a
    /// medication that did not yet exist.
    func recordMissedDoses(now: Date = .now, lookbackDays: Int = 30) {
        let snapshots = self.snapshots()
        guard !snapshots.isEmpty,
              let from = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: now)
        else { return }

        let index = loggedEvents(from: from, to: now)
        let overdue = DoseCalculator.unloggedOverdueDoses(
            medications: snapshots, events: index, lookbackDays: lookbackDays,
            now: now, window: tracking.doseWindow
        )
        guard !overdue.isEmpty else { return }

        let byID = Dictionary(uniqueKeysWithValues: medications().map { ($0.id, $0) })
        for dose in overdue {
            guard let medication = byID[dose.medicationID] else { continue }
            context.insert(
                DoseEvent(medication: medication, scheduledAt: dose.scheduledAt, status: .missed, loggedAt: now)
            )
        }
        persist()
    }

    // MARK: - Medications

    @discardableResult
    func add(
        name: String,
        doseDetail: String,
        notes: String,
        colorName: String,
        schedule: DoseSchedule,
        pillsRemaining: Int?,
        refillThreshold: Int?,
        importance: MedicationImportance = .standard,
        form: MedicationForm? = nil
    ) -> Medication {
        let medication = Medication(
            name: name.singleLine,
            doseDetail: doseDetail.singleLine,
            notes: notes.singleLine,
            colorName: colorName,
            schedule: schedule,
            pillsRemaining: pillsRemaining,
            refillThreshold: refillThreshold,
            importance: importance,
            form: form
        )
        context.insert(medication)
        persist()
        rescheduleNotifications()
        return medication
    }

    func update(
        _ medication: Medication,
        name: String,
        doseDetail: String,
        notes: String,
        colorName: String,
        schedule: DoseSchedule,
        pillsRemaining: Int?,
        refillThreshold: Int?,
        importance: MedicationImportance = .standard,
        form: MedicationForm? = nil
    ) {
        medication.name = name.singleLine
        medication.doseDetail = doseDetail.singleLine
        medication.notes = notes.singleLine
        medication.colorName = colorName
        medication.form = form
        medication.schedule = schedule
        medication.pillsRemaining = pillsRemaining
        medication.refillThreshold = refillThreshold
        medication.importance = importance

        // Keep denormalised history readable after a rename.
        for event in medication.events {
            event.medicationName = medication.displayName
            event.medicationColorName = medication.colorName
        }
        persist()
        rescheduleNotifications()
    }

    func setActive(_ isActive: Bool, for medication: Medication) {
        medication.isActive = isActive
        persist()
        rescheduleNotifications()
    }

    func addSupply(_ amount: Int, to medication: Medication) {
        medication.pillsRemaining = (medication.pillsRemaining ?? 0) + amount
        persist()
        rescheduleNotifications()
    }

    /// Deletes the medication and keeps its history — the promise the delete
    /// confirmation has always made, now actually kept by the delete rule.
    func delete(_ medication: Medication) {
        context.delete(medication)
        persist()
        rescheduleNotifications()
    }

    /// Wipes every medication and every logged event.
    ///
    /// Per-instance deletes, deliberately. `context.delete(model:)` performs a
    /// batch delete that bypasses the context's registered objects — and the
    /// Settings screen that triggers this holds live `@Query` results on
    /// exactly those rows. The following save can then fail, which surfaced as
    /// "Delete All Data does nothing": the error landed in `lastError`, which
    /// nothing presented. A personal library is hundreds of rows at most, so
    /// the batch path bought no speed worth that risk.
    ///
    /// The relationship is severed by hand first. Deleting both ends of a
    /// relationship in one save makes SwiftData nullify a back-reference
    /// through an already-deleted object, which traps inside the framework.
    func deleteAllData() {
        do {
            for event in try context.fetch(FetchDescriptor<DoseEvent>()) {
                event.medication = nil
                context.delete(event)
            }
            for medication in try context.fetch(FetchDescriptor<Medication>()) {
                context.delete(medication)
            }
            try context.save()
        } catch {
            lastError = .saveFailed(error.localizedDescription)
        }
        rescheduleNotifications()
    }

    // MARK: - Notifications

    /// Rebuilds the entire notification plan from current data.
    ///
    /// Called after every mutation, on launch, on foreground, and from the
    /// background refresh task. Idempotent and cheap: the planner is pure, and
    /// the service reconciles add-first, so a rebuild can never leave the user
    /// with fewer reminders than before.
    ///
    /// The sync form is for UI call sites, where suspension cannot strand the
    /// work. The background refresh path must use `rescheduleNotifications()`
    /// in its awaited form — an un-awaited Task there lets iOS suspend the app
    /// with the reconcile half-done.
    func rescheduleNotifications() {
        Task { await rescheduleNotifications() }
    }

    /// The awaitable form, for the background refresh task.
    func rescheduleNotifications() async {
        let snapshots = self.snapshots()
        let now = Date.now
        let window = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        let horizon = Calendar.current.date(byAdding: .day, value: 3, to: now) ?? now
        let index = loggedEvents(from: window, to: horizon)

        let preferences = self.preferences
        let plan = NotificationPlanner.plan(
            medications: snapshots, events: index, now: now, preferences: preferences
        )
        let failedRequestIDs = Set(await notifications.apply(plan))
        // A request the system refused counts as deferred: the user must be
        // able to see which medications are currently unreminded.
        let failedMedicationIDs = plan.notifications
            .filter { failedRequestIDs.contains($0.id) }
            .flatMap(\.medicationIDs)
        self.deferredMedicationIDs = plan.deferredMedicationIDs
            .union(failedMedicationIDs)
    }

    // MARK: - Persistence

    private func persist() {
        guard context.hasChanges else { return }
        do {
            try context.save()
            revision += 1
        } catch {
            // Surfaced, never swallowed. A silent failure in a medication app
            // means someone believes they logged a dose that was never stored.
            lastError = .saveFailed(error.localizedDescription)
        }
    }
}

enum StoreError: LocalizedError, Identifiable, Equatable {
    case saveFailed(String)

    var id: String { errorDescription ?? "unknown" }

    var errorDescription: String? {
        switch self {
        case .saveFailed(let detail):
            String(localized: "Couldn't save your change: \(detail)")
        }
    }

    var recoverySuggestion: String? {
        String(localized: "Try again. If this keeps happening, export a backup from Settings.")
    }
}
