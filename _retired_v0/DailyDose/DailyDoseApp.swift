import SwiftUI
import SwiftData

let sharedModelContainer: ModelContainer = {
    let schema = Schema([Medication.self, DoseEvent.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    do {
        return try ModelContainer(for: schema, configurations: [config])
    } catch {
        fatalError("Could not create ModelContainer: \(error)")
    }
}()

@main
struct DailyDoseApp: App {
    init() {
        CrashReport.install()
        NotificationScheduler.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
