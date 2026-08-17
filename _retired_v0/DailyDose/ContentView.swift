import SwiftUI
import SwiftData

struct ContentView: View {
    enum AppTab { case today, meds, history, camera }

    @Environment(\.modelContext) private var context
    @Query private var meds: [Medication]
    @State private var selectedTab: AppTab = .today
    @State private var previewDetail: Medication?

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                // iOS 26 tab anatomy: browsing tabs on one side (Today, Meds,
                // History — Settings lives behind the header pill on Today),
                // the Camera hero action separated on the trailing side.
                // Camera is a real tab: while active, the system tab bar hides
                // and its own bottom chrome (manual pill + shutter) takes over.
                TabView(selection: $selectedTab) {
                    Tab("Today", systemImage: "sun.max.fill", value: .today) { TodayView() }
                    Tab("Meds", systemImage: "pills.fill", value: .meds) { MedsView() }
                    Tab("History", systemImage: "chart.bar.fill", value: .history) {
                        NavigationStack { HistoryView() }
                    }
                    Tab("Camera", systemImage: "camera.viewfinder", value: .camera, role: .search) {
                        CameraTabView(onExit: {
                            Haptics.light()
                            selectedTab = .today
                        })
                    }
                }
            } else {
                TabView {
                    TodayView()
                        .tabItem { Label("Today", systemImage: "sun.max.fill") }
                    MedsView()
                        .tabItem { Label("Meds", systemImage: "pills.fill") }
                    NavigationStack { HistoryView() }
                        .tabItem { Label("History", systemImage: "chart.bar.fill") }
                    CameraTabView()
                        .tabItem { Label("Camera", systemImage: "camera.viewfinder") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                }
            }
        }
        .tint(MedPalette.accent)
        .task { seedDemoDataIfRequested() }
        // Dev aid: launch with `-seedDemo -previewDetail` to open the detail
        // page of the first med directly (used for visual design checks).
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-previewMeds") { selectedTab = .meds }
            if args.contains("-previewHistory") { selectedTab = .history }
            guard args.contains("-previewDetail") else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if previewDetail == nil { previewDetail = meds.first }
        }
        .fullScreenCover(item: $previewDetail) { med in
            NavigationStack { MedicationDetailView(med: med) }
        }
    }

    /// Development aid: launch with `-seedDemo` to populate sample data (never runs otherwise).
    private func seedDemoDataIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-seedDemo"), meds.isEmpty else { return }
        let cal = Calendar.current
        func hm(_ h: Int, _ m: Int) -> String { String(format: "%02d:%02d", h, m) }
        let nowH = cal.component(.hour, from: .now)
        let nowM = cal.component(.minute, from: .now)

        let meta = Medication(name: "Metformin", doseDetail: "500 mg · 1 tablet",
                              notes: "Take with food", colorName: "navy",
                              times: [hm(8, 0), hm(max(0, nowH - 1), nowM)],
                              pillsRemaining: 18, refillWarnAt: 20)
        let lisi = Medication(name: "Lisinopril", doseDetail: "10 mg · 1 tablet",
                              colorName: "coral", times: [hm(9, 30)],
                              pillsRemaining: 42, refillWarnAt: 10)
        let d3 = Medication(name: "Vitamin D3", doseDetail: "2000 IU · 1 capsule",
                            colorName: "mint", times: [hm(8, 0)])
        [meta, lisi, d3].forEach { context.insert($0) }

        // A week of plausible history so charts have something to show.
        for med in [meta, lisi, d3] {
            for dayOffset in 1...10 {
                guard let day = cal.date(byAdding: .day, value: -dayOffset, to: .now) else { continue }
                for time in med.times {
                    guard let at = DoseEngine.scheduledAt(on: day, time: time) else { continue }
                    let roll = (dayOffset + med.name.count) % 7
                    let status: DoseStatus = roll == 0 ? .missed : (roll == 3 ? .skipped : .taken)
                    context.insert(DoseEvent(medication: med, scheduledAt: at, status: status))
                }
            }
        }
        try? context.save()
    }
}
