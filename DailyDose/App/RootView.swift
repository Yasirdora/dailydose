import SwiftUI
import SwiftData

/// The tab shell.
///
/// Settings lived in two places before — a tab on iOS 17 *and* a toolbar button
/// on Today — so the same screen had two front doors depending on the OS. It
/// now lives in exactly one: behind Today's toolbar, on every version.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var selection: Tab = .today
    @State private var tabBeforeScan: Tab = .today
    @State private var isScanning = false
    @State private var deepLink: TodayDeepLink?

    enum Tab: Hashable {
        case today, medications, history, scan
    }

    var body: some View {
        Group {
            if case .degraded(let reason) = environment.status {
                // The store failed to open. Rather than crash — which is what
                // this app used to do — explain it and offer a way out.
                RecoveryView(reason: reason)
            } else {
                tabs
            }
        }
        .tint(Theme.accent)
        // The camera tab doesn't go anywhere — it opens the scanner as a
        // bottom sheet, the way Wallet's Add Card slides up over whatever you
        // were doing. A small, satisfying thud marks the detour.
        .onChange(of: selection) { old, tab in
            if tab == .scan {
                tabBeforeScan = old == .scan ? tabBeforeScan : old
                Haptics.impact()
                isScanning = true
            }
        }
        .onChange(of: isScanning) { _, scanning in
            // Leaving the scanner returns you to exactly where you were —
            // the camera is a detour, never a destination.
            if !scanning, selection == .scan { selection = tabBeforeScan }
        }
        .sheet(isPresented: $isScanning) {
            ScanTabView(onFinish: { isScanning = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                // A dragged-down live camera sliding over the tab UI is what
                // glitched before; the chevron inside is the one honest exit.
                .interactiveDismissDisabled()
        }
        .onChange(of: environment.coordinator.pendingDeepLink) { _, link in
            guard let link else { return }
            selection = .today
            // The day comes along: DeepLink exists "so the app can open on
            // the right day", and discarding it dumped a stale-banner tap
            // onto today.
            deepLink = TodayDeepLink(medicationID: link.medicationID, day: link.scheduledAt)
            environment.coordinator.pendingDeepLink = nil
        }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: $selection) {
                // `SwiftUI.Tab` — the nested `Tab` enum shadows the type here.
                SwiftUI.Tab(String(localized: "Doses"), systemImage: "clock.badge.checkmark.fill", value: Tab.today) {
                    TodayView(deepLink: $deepLink)
                }
                SwiftUI.Tab(String(localized: "Meds"), systemImage: "pills.fill", value: Tab.medications) {
                    MedicationsView()
                }
                SwiftUI.Tab(String(localized: "History"), systemImage: "chart.bar.fill", value: Tab.history) {
                    HistoryView()
                }
                // The camera lives apart, in its own trailing capsule — the
                // layout iOS 26 reserves for the one action that isn't a
                // place. Its content stays empty: selecting it opens the
                // scanner cover above, and two live cameras must never exist.
                SwiftUI.Tab(String(localized: "Scan"), systemImage: "camera.viewfinder", value: Tab.scan, role: .search) {
                    Color.clear
                }
            }
        } else {
            TabView(selection: $selection) {
                TodayView(deepLink: $deepLink)
                    .tabItem { Label(String(localized: "Doses"), systemImage: "clock.badge.checkmark.fill") }
                    .tag(Tab.today)
                MedicationsView()
                    .tabItem { Label(String(localized: "Meds"), systemImage: "pills.fill") }
                    .tag(Tab.medications)
                HistoryView()
                    .tabItem { Label(String(localized: "History"), systemImage: "chart.bar.fill") }
                    .tag(Tab.history)
                Color.clear
                    .tabItem { Label(String(localized: "Scan"), systemImage: "camera.viewfinder") }
                    .tag(Tab.scan)
            }
        }
    }
}

/// Shown when the data store could not be opened.
///
/// The on-disk file is deliberately left alone: recovery may still be possible
/// and the user's history is worth more than a clean launch.
struct RecoveryView: View {
    let reason: String

    @Environment(AppEnvironment.self) private var environment
    @State private var isResetting = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(String(localized: "Your data couldn't be opened"), systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text(String(localized: """
                    Daily Meds is running, but it can't reach your saved medications. \
                    Your file has not been changed — reinstalling or updating the app may recover it.
                    """))
            } actions: {
                VStack(spacing: 12) {
                    Text(reason)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)

                    Button(String(localized: "Start Fresh"), role: .destructive) {
                        isResetting = true
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
            .navigationTitle(String(localized: "Recovery"))
            .confirmationDialog(
                String(localized: "Start with an empty library?"),
                isPresented: $isResetting,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Start Fresh"), role: .destructive) {
                    // Actually rebuilds — in the degraded state the store is
                    // an in-memory scratch, so wiping it would clear nothing
                    // and land the user back on this screen.
                    environment.startFresh()
                    Haptics.warning()
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "This can't be undone. Your medications and history will be cleared."))
            }
        }
    }
}
