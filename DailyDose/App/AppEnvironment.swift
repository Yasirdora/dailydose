import Foundation
import SwiftData
import SwiftUI

/// Boots the data stack and wires the services together.
///
/// The previous version did this at file scope with a `fatalError` on failure:
///
/// ```swift
/// let sharedModelContainer: ModelContainer = { … fatalError(…) }()
/// ```
///
/// For a medication app that is the worst possible behaviour. A schema
/// migration hiccup, a corrupt store or a full disk turned into a launch crash
/// with no message, no recovery and no way for the user to reach their data —
/// on the app they rely on to take their heart medication.
///
/// Now failure is a state the app can be in, and one the user can act on.
@MainActor
@Observable
final class AppEnvironment {

    enum Status {
        case ready
        /// The store failed to open. The app still runs, in memory, so the user
        /// can see what happened and export or reset — instead of a dead icon.
        case degraded(reason: String)
    }

    let container: ModelContainer
    let store: DoseStore
    let notificationService: NotificationService
    let coordinator: NotificationCoordinator
    private(set) var status: Status

    init() {
        let schema = Schema(versionedSchema: DailyDoseSchemaV3.self)
        var status: Status = .ready
        var container: ModelContainer

        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: DailyDoseMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)]
            )
        } catch {
            // Fall back to an in-memory store so the UI can boot and explain
            // itself. The on-disk file is left untouched — recovery may still
            // be possible, and destroying it here would remove that chance.
            status = .degraded(reason: error.localizedDescription)
            container = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        }

        let service = NotificationService()
        self.container = container
        self.status = status
        self.notificationService = service
        self.store = DoseStore(context: container.mainContext, notifications: service)
        self.coordinator = NotificationCoordinator(store: store, service: service)
    }

    /// Everything that must happen once, at launch.
    func bootstrap() {
        coordinator.start()
        seedDemoDataIfRequested()
        Task { await refresh() }
    }

    /// Seeds a small demo library when launched with `-seedDemo`.
    ///
    /// Exists purely for design review and screenshots on the Simulator, where
    /// typing data in by hand is slow. Never runs in a normal launch, and never
    /// overwrites a real library.
    private func seedDemoDataIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-seedDemo"),
              case .ready = status,
              store.medications().isEmpty
        else { return }

        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)

        func at(_ day: Date, _ time: TimeOfDay) -> Date {
            time.date(on: day, calendar: calendar) ?? day
        }

        let panadol = store.add(
            name: "Panadol Advance", doseDetail: "500 mg", notes: "Take with water",
            colorName: MedicationColor.mint.rawValue,
            schedule: DoseSchedule(
                kind: .daily,
                times: Set([TimeOfDay(hour: 8, minute: 0)!, TimeOfDay(hour: 14, minute: 0)!,
                            TimeOfDay(hour: 18, minute: 0)!, TimeOfDay(hour: 22, minute: 0)!].compactMap { $0 }),
                startDate: today
            ),
            pillsRemaining: 34, refillThreshold: 10
        )
        let metformin = store.add(
            name: "Metformin HCL", doseDetail: "850 mg", notes: "With food",
            colorName: MedicationColor.navy.rawValue,
            schedule: DoseSchedule(
                kind: .daily,
                times: Set([TimeOfDay(hour: 8, minute: 0)!, TimeOfDay(hour: 20, minute: 0)!].compactMap { $0 }),
                startDate: today
            ),
            pillsRemaining: 9, refillThreshold: 10
        )
        let vitaminD = store.add(
            name: "Vitamin D3", doseDetail: "1000 IU", notes: "",
            colorName: MedicationColor.yellow.rawValue,
            schedule: DoseSchedule(
                kind: .daily,
                times: [TimeOfDay(hour: 9, minute: 0)!],
                startDate: today
            ),
            pillsRemaining: nil, refillThreshold: nil
        )

        // A course with one dose due right now, so the actionable card — chip,
        // Taken/Skip row and "1 of 3" counter — is visible in screenshots.
        let nowTime = TimeOfDay(from: now)
        func hoursLater(_ hours: Int) -> TimeOfDay {
            TimeOfDay(hour: (nowTime.hour + hours) % 24, minute: nowTime.minute)!
        }
        let course = store.add(
            name: "Amoxicillin", doseDetail: "500 mg", notes: "Finish the course",
            colorName: MedicationColor.coral.rawValue,
            schedule: DoseSchedule(
                kind: .daily,
                times: Set([nowTime, hoursLater(5), hoursLater(10)]),
                startDate: today,
                endDate: calendar.date(byAdding: .day, value: 6, to: today)
            ),
            pillsRemaining: 21, refillThreshold: 5
        )

        // A believable trail: the morning dose taken today, a full day yesterday,
        // and a missed evening the day before — so the rings have a story to tell.
        store.log(medicationID: panadol.id, scheduledAt: at(today, TimeOfDay.morning), status: .taken)
        store.log(medicationID: metformin.id, scheduledAt: at(today, TimeOfDay.morning), status: .taken)
        store.log(medicationID: vitaminD.id, scheduledAt: at(today, TimeOfDay(hour: 9, minute: 0)!), status: .taken)

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            for time in panadol.schedule.sortedTimes {
                store.log(medicationID: panadol.id, scheduledAt: at(yesterday, time), status: .taken)
            }
            for time in metformin.schedule.sortedTimes {
                store.log(medicationID: metformin.id, scheduledAt: at(yesterday, time), status: .taken)
            }
        }
        if let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today) {
            store.log(medicationID: panadol.id, scheduledAt: at(twoDaysAgo, TimeOfDay.morning), status: .taken)
            store.log(medicationID: panadol.id, scheduledAt: at(twoDaysAgo, TimeOfDay(hour: 22, minute: 0)!), status: .missed)
        }
    }

    /// Everything that must happen whenever the app comes back to the front —
    /// and, via the background refresh task, sometimes when it doesn't.
    ///
    /// Rescheduling here is the fix for reminders going stale: the plan is now
    /// rebuilt on every foreground, not only when the user happens to edit a
    /// medication.
    ///
    /// Awaited, so a background refresh only completes when the reconcile has
    /// actually finished — returning early lets iOS suspend the process with
    /// the notification plan half-written.
    func refresh() async {
        guard case .ready = status else { return }
        store.recordMissedDoses()
        await store.rescheduleNotifications()
    }
}

// MARK: - Environment plumbing

private struct DoseStoreKey: EnvironmentKey {
    @MainActor static let defaultValue: DoseStore? = nil
}

extension EnvironmentValues {
    var doseStore: DoseStore? {
        get { self[DoseStoreKey.self] }
        set { self[DoseStoreKey.self] = newValue }
    }
}

extension View {
    func doseStore(_ store: DoseStore) -> some View {
        environment(\.doseStore, store)
    }
}
