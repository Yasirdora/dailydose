import SwiftUI
import SwiftData
import UIKit
import UserNotifications
import UniformTypeIdentifiers

/// The app's settings.
///
/// Five sections, none longer than three rows, ordered by how consequential
/// they are rather than by how the code is organised:
///
/// 1. **Reminders** — the app's core promise, and the most-visited setting.
/// 2. **Tracking** — how the app *interprets* what you do. The dose window
///    silently decides your adherence percentage, so it belongs near the top.
/// 3. **Your data** — periodic actions, not daily ones.
/// 4. **About** — rarely opened, but must exist.
/// 5. **Delete** — destructive, alone, at the bottom.
///
/// Anything currently broken surfaces as a single banner above all of it,
/// rather than as a section buried mid-list where it reads as informational.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.doseStore) private var store
    @Environment(\.modelContext) private var context
    @Query private var medications: [Medication]
    @Query private var events: [DoseEvent]

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var tracking = TrackingPreferences.default
    @State private var isImporting = false
    @State private var isImportingFromHealth = false
    @State private var exportedBackup: BackupFile?
    @State private var importSummary: BackupService.ImportSummary?
    @State private var errorMessage: String?
    @State private var isConfirmingReset = false
    @State private var didLoad = false

    /// Wraps the URL so `.sheet(item:)` can drive the share sheet directly —
    /// the old flow created the file, then revealed a *second* row to share it.
    private struct BackupFile: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let alert = activeAlert { alertBanner(alert) }

                remindersSection
                trackingSection
                dataSection
                aboutSection
                deleteSection
            }
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
            }
            .task {
                if !didLoad {
                    tracking = store?.tracking ?? .default
                    didLoad = true
                }
                notificationStatus = await environment.notificationService.authorizationStatus()
            }
            .onChange(of: tracking) { _, new in
                store?.tracking = new
                new.save()
            }
            .sheet(item: $exportedBackup) { backup in
                ShareSheet(url: backup.url)
            }
            .sheet(isPresented: $isImportingFromHealth) { HealthImportView() }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.json, UTType(filenameExtension: BackupService.fileExtension) ?? .json]
            ) { handleImport($0) }
            .alert(
                String(localized: "Backup restored"),
                isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })
            ) {
                Button(String(localized: "OK"), role: .cancel) { importSummary = nil }
            } message: {
                if let importSummary {
                    Text(String(localized: """
                        \(importSummary.medicationsAdded) medications added, \
                        \(importSummary.medicationsUpdated) updated, \
                        \(importSummary.eventsAdded) history entries restored.
                        """))
                }
            }
            .alert(
                String(localized: "Something went wrong"),
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button(String(localized: "OK"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            // Presented from the Form, not the row: dialogs attached inside a
            // Form section are at the mercy of row reuse, and this one must
            // appear every single time.
            .confirmationDialog(
                String(localized: "Delete everything?"),
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Delete All Data"), role: .destructive) {
                    deleteEverything()
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "Every medication and all history will be removed from this device. Back up first if you might want it back."))
            }
        }
    }

    // MARK: - Alert banner

    private enum SettingsAlert {
        case notificationsDenied
        case remindersAtCapacity(count: Int)
    }

    /// One banner, top of the screen, only when something is actually wrong.
    ///
    /// Both of these used to be easy to miss — permission denial wasn't shown
    /// here at all, and the capacity warning sat between two ordinary sections
    /// where it read as a note. It isn't a note: it means somebody is not being
    /// reminded.
    private var activeAlert: SettingsAlert? {
        if notificationStatus == .denied { return .notificationsDenied }
        let deferred = environment.store.deferredMedicationIDs
        if !deferred.isEmpty { return .remindersAtCapacity(count: deferred.count) }
        return nil
    }

    @ViewBuilder
    private func alertBanner(_ alert: SettingsAlert) -> some View {
        Section {
            switch alert {
            case .notificationsDenied:
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                } label: {
                    bannerLabel(
                        icon: "bell.slash.fill",
                        title: String(localized: "Reminders are off in iOS Settings"),
                        detail: String(localized: "Nothing below can reach you until you turn them back on."),
                        showsChevron: true
                    )
                }

            case .remindersAtCapacity(let count):
                NavigationLink {
                    CapacityDetailView(medications: deferredMedications)
                } label: {
                    bannerLabel(
                        icon: "exclamationmark.triangle.fill",
                        title: String(localized: "\(count) medications aren't being reminded"),
                        detail: String(localized: "iOS limits how many reminders an app can schedule."),
                        showsChevron: false
                    )
                }
            }
        }
    }

    private func bannerLabel(icon: String, title: String, detail: String, showsChevron: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(Theme.missed)
        }
        .accessibilityElement(children: .combine)
    }

    private var deferredMedications: [Medication] {
        let ids = environment.store.deferredMedicationIDs
        return medications.filter { ids.contains($0.id) }
    }

    // MARK: - 1. Reminders

    private var remindersSection: some View {
        Section {
            NavigationLink {
                NotificationSettingsView()
            } label: {
                LabeledContent {
                    Text(notificationSummary)
                        .foregroundStyle(notificationStatus == .denied ? Theme.missed : .secondary)
                } label: {
                    Label(String(localized: "Notifications"), systemImage: "bell.badge.fill")
                }
            }

            if notificationStatus == .notDetermined {
                Button(String(localized: "Turn on notifications")) {
                    Task {
                        await environment.notificationService.requestAuthorization()
                        notificationStatus = await environment.notificationService.authorizationStatus()
                        await store?.rescheduleNotifications()
                    }
                }
            }
        } header: {
            Text(String(localized: "Reminders"))
        }
    }

    private var notificationSummary: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            store?.preferences.doseRemindersEnabled == false
                ? String(localized: "Off")
                : String(localized: "On")
        case .denied: String(localized: "Blocked")
        default: String(localized: "Not set up")
        }
    }

    // MARK: - 2. Tracking

    private var trackingSection: some View {
        Section {
            NavigationLink {
                DoseWindowPicker(window: $tracking.doseWindow)
            } label: {
                LabeledContent {
                    Text(tracking.doseWindow.title).foregroundStyle(.secondary)
                } label: {
                    Label(String(localized: "Dose window"), systemImage: "clock.badge.checkmark")
                }
            }
        } header: {
            Text(String(localized: "Tracking"))
        } footer: {
            Text(String(localized: "The dose window is how long a dose stays actionable before it counts as missed."))
        }
    }

    // MARK: - 3. Your data

    private var dataSection: some View {
        Section {
            Button {
                exportBackup()
            } label: {
                Label(String(localized: "Back up"), systemImage: "arrow.down.doc")
                    .foregroundStyle(.primary)
            }

            Button {
                isImporting = true
            } label: {
                Label(String(localized: "Restore from a backup"), systemImage: "arrow.up.doc")
                    .foregroundStyle(.primary)
            }

            if HealthKitService.isSupported {
                Button {
                    isImportingFromHealth = true
                } label: {
                    Label(String(localized: "Import from Apple Health"), systemImage: "heart.text.square.fill")
                        .foregroundStyle(.primary)
                }
            }
        } header: {
            Text(String(localized: "Your data"))
        } footer: {
            Text(String(localized: "Your data stays on this device — no account, no server. A backup contains everything, including schedules and history, and restoring never overwrites what you already have."))
        }
    }

    /// One action: build the archive and hand it straight to the share sheet.
    /// The old flow created a file and then revealed a second row to share it,
    /// which is an implementation detail leaking into the interface.
    private func exportBackup() {
        do {
            let archive = BackupService.makeArchive(medications: medications, events: events)
            exportedBackup = BackupFile(url: try BackupService.writeArchive(archive))
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            // Files chosen through the picker live outside the sandbox.
            let needsRelease = url.startAccessingSecurityScopedResource()
            defer { if needsRelease { url.stopAccessingSecurityScopedResource() } }

            let archive = try BackupService.decode(try Data(contentsOf: url))
            importSummary = try BackupService.restore(archive, into: context)
            store?.rescheduleNotifications()
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    // MARK: - 4. About

    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutView()
            } label: {
                Label(String(localized: "About Daily Dose"), systemImage: "info.circle")
            }

            Link(destination: URL(string: "https://dailymeds.figoodle.com/privacy/")!) {
                LabeledContent {
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                } label: {
                    Label(String(localized: "Privacy Policy"), systemImage: "hand.raised")
                        .foregroundStyle(.primary)
                }
            }

            if let mail = FeedbackMail.url {
                Link(destination: mail) {
                    LabeledContent {
                        Image(systemName: "arrow.up.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    } label: {
                        Label(String(localized: "Help & Feedback"), systemImage: "envelope")
                            .foregroundStyle(.primary)
                    }
                }
            }

            LabeledContent(String(localized: "Version")) {
                Text(Bundle.main.shortVersionString)
            }
        } header: {
            Text(String(localized: "About"))
        } footer: {
            Text(String(localized: "Daily Dose is not a medical device and does not give medical advice — always follow your prescriber's instructions."))
        }
    }

    // MARK: - 5. Delete

    private var deleteSection: some View {
        Section {
            Button(String(localized: "Delete All Data"), role: .destructive) {
                isConfirmingReset = true
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Goes through `environment.store`, not the optional `\.doseStore`
    /// environment value: a silent no-op is the one failure this button must
    /// never have. Any store error is shown, not dropped.
    private func deleteEverything() {
        environment.store.deleteAllData()
        if let error = environment.store.lastError {
            environment.store.lastError = nil
            errorMessage = error.errorDescription
            Haptics.error()
        } else {
            Haptics.warning()
        }
    }
}

// MARK: - Capacity detail

/// Which medications aren't being reminded, and what to do about it.
private struct CapacityDetailView: View {
    let medications: [Medication]

    var body: some View {
        List {
            Section {
                ForEach(medications) { medication in
                    Label(medication.displayName, systemImage: "bell.slash")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "Not being reminded"))
            } footer: {
                Text(String(localized: "iOS allows an app to schedule a limited number of reminders. These medications are still tracked and still appear on Today — they just can't send an alert."))
            }

            Section(String(localized: "What helps")) {
                hint(String(localized: "Turn on Group by time"),
                     String(localized: "Medications due together share one alert, which frees a lot of room."))
                hint(String(localized: "Pause anything you're not taking"),
                     String(localized: "A paused medication keeps its history but stops using a slot."))
                hint(String(localized: "Simplify a complex schedule"),
                     String(localized: "Specific weekdays cost more slots than every day."))
            }
        }
        .navigationTitle(String(localized: "Reminders at Capacity"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func hint(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Share sheet

/// `UIActivityViewController` for the backup file. A `ShareLink` would need the
/// URL to exist before the row is drawn; the file is created on demand.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension Bundle {
    var shortVersionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
