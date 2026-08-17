import Foundation
import UserNotifications
import SwiftData

/// Notification strategy (see project plan, §2.1–2.2):
/// · Dose reminders use REPEATING weekly calendar triggers — they survive reboots
///   and never exhaust the 64-pending-notification ceiling (meds × times each count once).
/// · Follow-up nags (+30 min if unlogged) are non-repeating and maintained in a rolling
///   2-day window, cancelled as soon as the dose is logged — like Apple Health.
/// · Time-Sensitive interruption level breaks through Focus modes. NOTE: the
///   `com.apple.developer.usernotifications.time-sensitive` entitlement requires a PAID
///   Apple Developer account — it is intentionally left out of DailyDose.entitlements so
///   free Personal Teams can run the app (delivery gracefully degrades to standard alerts).
///   Re-add that key to DailyDose.entitlements when a paid account is available (required
///   for App Store / TestFlight anyway).
@MainActor
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationScheduler()

    let center = UNUserNotificationCenter.current()

    private let categoryID = "DOSE_REMINDER"
    private let actionTaken = "DOSE_TAKEN"
    private let actionSnooze = "DOSE_SNOOZE"
    private let actionSkip = "DOSE_SKIP"
    private let maxFollowUps = 30

    override init() {
        super.init()
    }

    func configure() {
        center.delegate = self
        registerCategories()
    }

    private func registerCategories() {
        let taken = UNNotificationAction(identifier: actionTaken, title: "Taken", options: [])
        let snooze = UNNotificationAction(identifier: actionSnooze, title: "Snooze 10 min", options: [])
        let skip = UNNotificationAction(identifier: actionSkip, title: "Skip", options: [.destructive])
        let category = UNNotificationCategory(identifier: categoryID,
                                              actions: [taken, snooze, skip],
                                              intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            // Time-sensitive delivery comes from the entitlement + interruptionLevel;
            // the .timeSensitive authorization option is deprecated since iOS 15.
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    // MARK: - Scheduling

    /// Rebuilds the full notification plan from the data model.
    func rescheduleAll(meds: [Medication]) async {
        center.removeAllPendingNotificationRequests()

        for med in meds where med.isActive {
            // Repeating weekly triggers can't express end dates or intervals —
            // those meds get a rolling 60-day projection of one-shot requests.
            let needsProjection = med.endDate != nil || med.scheduleKind == .everyXDays || med.scheduleKind == .monthly
            if !needsProjection {
                // Repeating weekly triggers: survive reboots, count once against the
                // 64-pending ceiling each. Daily = all seven weekdays.
                let days = med.scheduleKind == .daily ? Array(1...7) : med.weekdays
                for time in med.times {
                    let parts = time.split(separator: ":").compactMap { Int($0) }
                    guard parts.count == 2 else { continue }
                    for weekday in days {
                        var comps = DateComponents()
                        comps.weekday = weekday
                        comps.hour = parts[0]
                        comps.minute = parts[1]
                        let id = "dose-\(med.uuid)-\(weekday)-\(time)"
                        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                        try? await center.add(UNNotificationRequest(identifier: id, content: doseContent(med: med, time: time), trigger: trigger))
                    }
                }
            } else {
                let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyyMMdd"
                var added = 0
                for offset in 0...60 where added < 20 {
                    guard let day = Calendar.current.date(byAdding: .day, value: offset, to: .now),
                          med.isScheduledOn(day) else { continue }
                    for time in med.times {
                        guard let at = DoseEngine.scheduledAt(on: day, time: time), at > .now else { continue }
                        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
                        let id = "dose-\(med.uuid)-\(dayFmt.string(from: day))-\(time)"
                        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                        try? await center.add(UNNotificationRequest(identifier: id, content: doseContent(med: med, time: time), trigger: trigger))
                        added += 1
                    }
                }
            }
        }
        await refreshFollowUps(meds: meds)
    }

    /// +30 min nags for unlogged doses due in the next 2 days (capped).
    func refreshFollowUps(meds: [Medication]) async {
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix("follow-") || $0.hasPrefix("snooze-") || $0.hasPrefix("refill-") }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }

        let now = Date.now
        var scheduledCount = 0
        for dayOffset in 0...2 {
            guard let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            for dose in DoseEngine.doses(on: day, meds: meds, now: now) {
                guard scheduledCount < maxFollowUps else { return }
                if case .logged = dose.state { continue }
                let nagDate = dose.scheduledAt.addingTimeInterval(30 * 60)
                guard nagDate > now else { continue }

                let content = UNMutableNotificationContent()
                content.title = "Still not logged: \(dose.medication.name)"
                content.body = "Scheduled for \(Self.prettyTime(dose.scheduledAt)). Tap to log it."
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.categoryIdentifier = categoryID
                content.userInfo = ["medUUID": dose.medication.uuid,
                                    "time": Self.timeString(from: dose.scheduledAt)]
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: nagDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: "follow-\(dose.id)", content: content, trigger: trigger))
                scheduledCount += 1
            }
        }

        // Refill-low alerts: a gentle morning nudge for the next 3 days while any
        // tracked med is at or below its warning threshold.
        for med in meds where med.isActive {
            guard let remaining = med.pillsRemaining,
                  let warnAt = med.refillWarnAt,
                  remaining <= warnAt else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(med.name) is running low"
            content.body = remaining <= 0
                ? "No pills left — time for a refill."
                : "\(remaining) pill\(remaining == 1 ? "" : "s") left — plan a refill soon."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            for dayOffset in 1...3 {
                guard let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: now) else { continue }
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
                comps.hour = 9
                comps.minute = 0
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: "refill-\(med.uuid)-\(dayOffset)", content: content, trigger: trigger))
            }
        }
    }

    /// Cancels any pending nag for a medication (called right after logging).
    func cancelFollowUps(medUUID: String) async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter {
            ($0.hasPrefix("follow-") || $0.hasPrefix("snooze-")) && $0.contains(medUUID)
        }
        if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
    }

    // MARK: - Content helpers

    private func doseContent(med: Medication, time: String) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = "Time for \(med.name)"
        let pretty = Self.prettyTimeString(time)
        var body = med.doseDetail.isEmpty ? "Scheduled for \(pretty)" : "\(med.doseDetail) · \(pretty)"
        if !med.notes.isEmpty { body += " · \(med.notes)" }
        c.body = body
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        c.categoryIdentifier = categoryID
        c.userInfo = ["medUUID": med.uuid, "time": time]
        return c
    }

    private func scheduleSnooze(med: Medication, time: String) async {
        let id = "snooze-\(med.uuid)-\(time)-\(Int(Date.now.timeIntervalSince1970))"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: doseContent(med: med, time: time), trigger: trigger))
    }

    static func prettyTimeString(_ time: String) -> String {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return time }
        var comps = DateComponents(); comps.hour = parts[0]; comps.minute = parts[1]
        guard let date = Calendar.current.date(from: comps) else { return time }
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func prettyTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func timeString(from date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banner + sound even when the app is in the foreground.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// Taken / Snooze / Skip straight from the notification — no app launch required.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        guard let uuid = info["medUUID"] as? String,
              let time = info["time"] as? String else {
            completionHandler()
            return
        }
        let actionID = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            let context = ModelContext(sharedModelContainer)
            let fetch = FetchDescriptor<Medication>(predicate: #Predicate { $0.uuid == uuid })
            guard let med = try? context.fetch(fetch).first,
                  let at = DoseEngine.mostRecentScheduledAt(med: med, time: time) else { return }
            switch actionID {
            case actionTaken:
                DoseEngine.log(med: med, at: at, status: .taken, context: context)
                await cancelFollowUps(medUUID: uuid)
            case actionSkip:
                DoseEngine.log(med: med, at: at, status: .skipped, context: context)
                await cancelFollowUps(medUUID: uuid)
            case actionSnooze:
                await scheduleSnooze(med: med, time: time)
            default:
                break // user tapped the notification body — the app opens
            }
        }
    }
}
