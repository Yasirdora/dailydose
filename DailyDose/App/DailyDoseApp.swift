import SwiftUI
import SwiftData
import BackgroundTasks
import os

@main
struct DailyDoseApp: App {
    @State private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    /// Tops up one-shot reminders even when the app isn't opened.
    ///
    /// Repeating triggers survive on their own, but finite courses and interval
    /// schedules are projected as one-shots and need periodic replenishment.
    /// Without this, someone who doesn't open the app for a week stops being
    /// reminded — silently, which is the worst way for a medication app to fail.
    nonisolated static let refreshTaskIdentifier = "com.dailydose.ios.refresh"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .doseStore(environment.store)
                .modelContainer(environment.container)
                .task {
                    Haptics.prepare()
                    environment.bootstrap()
                    Self.scheduleBackgroundRefresh()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await environment.refresh() }
            case .background:
                Self.scheduleBackgroundRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskIdentifier)) {
            // Awaited to the end of the reconcile: the system may suspend the
            // process the moment this closure returns, and a half-written
            // notification plan is a missed medication with no error message.
            await environment.refresh()
            Self.scheduleBackgroundRefresh()
        }
    }

    nonisolated private static let log = Logger(subsystem: "com.ysr.dailydose", category: "refresh")

    /// Asks the system to wake us in twelve hours to top up the reminders.
    ///
    /// The failure is logged rather than swallowed. This used to be a `try?`,
    /// and the silence cost months: `BGTaskSchedulerPermittedIdentifiers` was
    /// set through an `INFOPLIST_KEY_` build setting that Xcode does not honour
    /// for that key, so it never reached the built app, every submit was
    /// refused, and nothing anywhere said so. The plist is fixed — but a
    /// submit can still fail for reasons only the device knows (Background App
    /// Refresh switched off, Low Power Mode, too many pending requests), and
    /// the app must be able to say which.
    ///
    /// Deliberately not surfaced to the user: there is nothing they can act on
    /// from here, and their scheduled reminders still fire from their own
    /// repeating triggers. This is a line in the console for whoever is holding
    /// the phone and wondering.
    nonisolated private static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.log.notice("Background refresh scheduled: \(Self.refreshTaskIdentifier, privacy: .public)")
        } catch {
            Self.log.error(
                """
                Background refresh NOT scheduled: \(error.localizedDescription, privacy: .public) — reminders for finite courses will not be topped up while the app stays closed
                """
            )
        }
    }
}
