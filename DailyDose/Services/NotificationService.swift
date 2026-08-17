import Foundation
import UserNotifications

/// Abstracts the notification centre so `DoseStore` can be tested without one.
protocol NotificationScheduling: Sendable {
    func apply(_ plan: NotificationPlanner.Plan) async
    func authorizationStatus() async -> UNAuthorizationStatus
    @discardableResult func requestAuthorization() async -> Bool
}

/// Turns a `NotificationPlanner.Plan` into pending system requests.
///
/// This type contains no policy. It does not decide what should be scheduled,
/// how many slots exist, or which medication wins when they compete — all of
/// that is in the planner, where it can be tested. Here we only translate and
/// reconcile.
actor NotificationService: NotificationScheduling {

    static let categoryIdentifier = "DOSE_REMINDER"

    enum Action: String {
        case taken = "DOSE_TAKEN"
        case snooze = "DOSE_SNOOZE"
        case skip = "DOSE_SKIP"
    }

    /// Snooze notifications are owned by the user, not the planner, so they are
    /// excluded from reconciliation. The old implementation swept every id
    /// beginning `snooze-` on each refresh, which meant opening the app for any
    /// reason silently cancelled a snooze the user had just set.
    private static let snoozePrefix = "snooze-"

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    // MARK: - Authorization

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func registerCategories() {
        let taken = UNNotificationAction(
            identifier: Action.taken.rawValue,
            title: String(localized: "Taken"),
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: Action.snooze.rawValue,
            title: String(localized: "Snooze 10 min"),
            options: []
        )
        let skip = UNNotificationAction(
            identifier: Action.skip.rawValue,
            title: String(localized: "Skip"),
            options: [.destructive]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [taken, snooze, skip],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    // MARK: - Applying a plan

    /// Rebuilds pending requests from the plan.
    ///
    /// Removes and re-adds rather than diffing by identifier. A diff keeps any
    /// request whose id is already pending — and repeating triggers keep the
    /// same id forever, so a changed tone, a changed importance or a fixed
    /// interruption level would *never* reach an already-scheduled reminder.
    /// That is exactly how every standard reminder stayed silent: scheduled
    /// once with `.passive`, then preserved by the diff on every rebuild.
    ///
    /// Re-adding costs nothing the user can perceive: a calendar trigger
    /// rebuilt from the same components fires at the same instants, and the
    /// plan is at most 64 requests. Snooze requests are the user's own and are
    /// left untouched.
    func apply(_ plan: NotificationPlanner.Plan) async {
        guard await authorizationStatus() != .denied else { return }

        let pending = await center.pendingNotificationRequests()
        let removable = pending
            .map(\.identifier)
            .filter { !$0.hasPrefix(Self.snoozePrefix) }
        if !removable.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: removable)
        }

        for planned in plan.notifications {
            guard let request = makeRequest(planned) else { continue }
            try? await center.add(request)
        }
    }

    private func makeRequest(_ planned: NotificationPlanner.PlannedNotification) -> UNNotificationRequest? {
        let content = UNMutableNotificationContent()
        content.title = planned.title
        content.body = planned.body
        content.userInfo = userInfo(for: planned.category)

        // Importance drives delivery, not a blanket "everything is urgent".
        //
        // `.timeSensitive` is the ceiling we can honestly reach: it breaks
        // through Focus modes but still respects the ringer switch, and needs
        // no entitlement. Apple's *Critical Alerts* — which also override mute
        // — are granted only where a missed alert is clinically dangerous, and
        // a general medication reminder does not qualify. Nothing in this app
        // claims otherwise.
        // The tone is already resolved against importance by the planner, so a
        // `.gentle` medication is silent here without this file re-deriving the
        // rule. `UNNotificationSound(named:)` resolves against the app bundle;
        // iOS falls back to the default tone if the file is ever missing, which
        // is the right failure — a reminder that arrives silently is worse than
        // one that arrives with the wrong chime.
        content.sound = planned.sound.fileName.map {
            UNNotificationSound(named: UNNotificationSoundName($0))
        }
        // `.active`, not `.passive`: passive notifications are delivered
        // *silently* by the system — no sound, ever — which quietly muted
        // every standard reminder. `.active` is the normal audible alert;
        // `.timeSensitive` is reserved for medication marked critical.
        // Silence belongs to the sound setting (planner resolves `.gentle`
        // to no tone), never to the delivery level.
        content.interruptionLevel = planned.importance.breaksThroughFocus ? .timeSensitive : .active

        // Only single-medication reminders carry Taken / Snooze / Skip. A
        // bundle can't: "Taken" is ambiguous across three medications, and a
        // wrong one-tap log is worse than opening the app.
        if planned.carriesActions {
            content.categoryIdentifier = Self.categoryIdentifier
        }

        // Bundled alerts collapse in Notification Centre instead of stacking.
        if case .doseBundle(_, let time) = planned.category {
            content.threadIdentifier = "doses-\(time.rawValue)"
        }

        let trigger: UNNotificationTrigger
        switch planned.trigger {
        case .daily(let time):
            var components = DateComponents()
            components.hour = time.hour
            components.minute = time.minute
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

        case .weekly(let weekday, let time):
            var components = DateComponents()
            components.weekday = weekday
            components.hour = time.hour
            components.minute = time.minute
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

        case .once(let date):
            guard date > .now else { return nil }
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }

        return UNNotificationRequest(identifier: planned.id, content: content, trigger: trigger)
    }

    private func userInfo(for category: NotificationPlanner.PlannedNotification.Category) -> [String: Any] {
        switch category {
        case .dose(let medicationID, let time):
            return [
                NotificationPayload.medicationID: medicationID,
                NotificationPayload.time: time.rawValue,
            ]
        case .doseBundle(let medicationIDs, let time):
            // No single medication to act on — tapping opens Today, where every
            // due dose already has a one-tap Taken button.
            return [
                NotificationPayload.bundledMedicationIDs: medicationIDs,
                NotificationPayload.time: time.rawValue,
            ]
        case .followUp(let medicationID, let scheduledAt):
            return [
                NotificationPayload.medicationID: medicationID,
                NotificationPayload.scheduledAt: scheduledAt.timeIntervalSinceReferenceDate,
            ]
        case .refill(let medicationID):
            return [
                NotificationPayload.medicationID: medicationID,
                NotificationPayload.isRefill: true,
            ]
        }
    }

    // MARK: - Snooze

    /// Re-presents a dose reminder after a delay. Owned by the user and never
    /// reconciled away by `apply(_:)`.
    func scheduleSnooze(
        medicationID: String, scheduledAt: Date, title: String, body: String,
        sound: NotificationSound = .default, minutes: Int = 10
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound.fileName.map { UNNotificationSound(named: UNNotificationSoundName($0)) }
        content.categoryIdentifier = Self.categoryIdentifier
        content.interruptionLevel = .timeSensitive
        content.userInfo = [
            NotificationPayload.medicationID: medicationID,
            NotificationPayload.scheduledAt: scheduledAt.timeIntervalSinceReferenceDate,
        ]

        let request = UNNotificationRequest(
            identifier: "\(Self.snoozePrefix)\(medicationID)-\(Dose.key(for: scheduledAt))",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)
        )
        try? await center.add(request)
    }

    /// Cancels the snooze and follow-up for one specific dose once it's logged.
    /// Scoped to the dose, not the medication, so logging today's morning dose
    /// doesn't silence tonight's.
    func cancelReminders(medicationID: String, scheduledAt: Date) {
        center.removePendingNotificationRequests(withIdentifiers: [
            "\(Self.snoozePrefix)\(medicationID)-\(Dose.key(for: scheduledAt))",
            NotificationPlanner.followUpIdentifier(medicationID: medicationID, scheduledAt: scheduledAt),
        ])
    }
}

enum NotificationPayload {
    static let bundledMedicationIDs = "bundledMedicationIDs"
    static let medicationID = "medicationID"
    static let time = "time"
    static let scheduledAt = "scheduledAt"
    static let isRefill = "isRefill"
}
