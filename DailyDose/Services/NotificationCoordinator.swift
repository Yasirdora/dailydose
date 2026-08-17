import Foundation
import UserNotifications
import SwiftData

/// Handles what happens when a notification is delivered or acted upon.
///
/// Split out from `NotificationService` on purpose: scheduling is a pure
/// translation job with no access to data, while responding to an action needs
/// the store. Keeping them apart is what lets the scheduler be an actor with no
/// SwiftData dependency at all.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {

    private let store: DoseStore
    private let service: NotificationService

    /// Set when the user taps a notification body, so the app can open on the
    /// right day and highlight the right dose instead of dumping them on Today
    /// with no context.
    var pendingDeepLink: DeepLink?

    struct DeepLink: Equatable {
        let medicationID: String
        let scheduledAt: Date?
    }

    init(store: DoseStore, service: NotificationService) {
        self.store = store
        self.service = service
        super.init()
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        Task { await service.registerCategories() }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even in the foreground: a dose reminder that appears
    /// only when the app is closed is a reminder that fails exactly when
    /// someone is looking at their phone.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let medicationID = userInfo[NotificationPayload.medicationID] as? String else { return }

        let explicitDate = (userInfo[NotificationPayload.scheduledAt] as? TimeInterval)
            .map(Date.init(timeIntervalSinceReferenceDate:))
        let time = (userInfo[NotificationPayload.time] as? String).flatMap(TimeOfDay.init)

        await handle(
            actionIdentifier: response.actionIdentifier,
            medicationID: medicationID,
            explicitDate: explicitDate,
            time: time,
            // The delivery date, never the tap date: a stale banner still
            // refers to the dose it was fired for.
            deliveredAt: response.notification.date,
            title: response.notification.request.content.title,
            body: response.notification.request.content.body
        )
    }

    private func handle(
        actionIdentifier: String,
        medicationID: String,
        explicitDate: Date?,
        time: TimeOfDay?,
        deliveredAt: Date,
        title: String,
        body: String
    ) async {
        // A refill alert carries no dose; tapping it should just open the
        // medication, not try to log something.
        guard let scheduledAt = resolveScheduledAt(
            medicationID: medicationID, explicitDate: explicitDate,
            time: time, deliveredAt: deliveredAt
        ) else {
            pendingDeepLink = DeepLink(medicationID: medicationID, scheduledAt: nil)
            return
        }

        switch NotificationService.Action(rawValue: actionIdentifier) {
        case .taken:
            store.log(medicationID: medicationID, scheduledAt: scheduledAt, status: .taken)
            await service.cancelReminders(medicationID: medicationID, scheduledAt: scheduledAt)

        case .skip:
            store.log(medicationID: medicationID, scheduledAt: scheduledAt, status: .skipped)
            await service.cancelReminders(medicationID: medicationID, scheduledAt: scheduledAt)

        case .snooze:
            await service.scheduleSnooze(
                medicationID: medicationID, scheduledAt: scheduledAt,
                title: title, body: body, sound: store.preferences.doseSound
            )

        case nil:
            // The user tapped the body (or dismissed). Open to the dose.
            pendingDeepLink = DeepLink(medicationID: medicationID, scheduledAt: scheduledAt)
        }
    }

    /// Works out which dose a notification refers to.
    ///
    /// Follow-ups and snoozes carry the exact instant. Repeating dose reminders
    /// carry only a time of day, because the trigger has no notion of *which*
    /// day it fired on — so we resolve against the banner's delivery date via
    /// `ReminderResolution`, never against the moment it was tapped.
    private func resolveScheduledAt(
        medicationID: String,
        explicitDate: Date?,
        time: TimeOfDay?,
        deliveredAt: Date
    ) -> Date? {
        if let explicitDate { return explicitDate }
        guard let time,
              let medication = store.medication(id: medicationID) else { return nil }
        return ReminderResolution.resolve(
            schedule: medication.schedule, time: time,
            deliveredAt: deliveredAt, calendar: .current
        )
    }
}
