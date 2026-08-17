import SwiftUI
import SwiftData
import BackgroundTasks

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
    static let refreshTaskIdentifier = "com.dailydose.ios.refresh"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .doseStore(environment.store)
                .modelContainer(environment.container)
                .task {
                    Haptics.prepare()
                    environment.bootstrap()
                    scheduleBackgroundRefresh()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await environment.refresh() }
            case .background:
                scheduleBackgroundRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskIdentifier)) {
            // Awaited to the end of the reconcile: the system may suspend the
            // process the moment this closure returns, and a half-written
            // notification plan is a missed medication with no error message.
            await environment.refresh()
            scheduleBackgroundRefresh()
        }
    }

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
