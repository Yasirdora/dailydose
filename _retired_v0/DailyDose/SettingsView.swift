import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var meds: [Medication]
    @Query private var events: [DoseEvent]

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var exportURL: URL?
    @State private var crashReport: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Label("Reminders", systemImage: "bell.badge.fill")
                        Spacer()
                        Text(statusText)
                            .foregroundStyle(statusColor)
                            .font(.subheadline.weight(.medium))
                    }
                    if notificationStatus == .notDetermined {
                        Button("Enable notifications") {
                            Task {
                                let granted = await NotificationScheduler.shared.requestAuthorization()
                                if granted { await NotificationScheduler.shared.rescheduleAll(meds: meds) }
                                notificationStatus = await NotificationScheduler.shared.authorizationStatus()
                            }
                        }
                    }
                    if notificationStatus == .denied {
                        Button("Open iPhone Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Daily Dose uses time-sensitive alerts that break through Focus modes. Doses nag again after 30 minutes if unlogged.")
                }

                Section {
                    Button("Export backup (JSON)") { exportBackup() }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share backup file", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("There is no cloud — by design. Export a backup regularly. Import is coming in a future update; backups are compatible with the Daily Dose web app.")
                }

                if let crashReport {
                    Section {
                        ScrollView {
                            Text(crashReport)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                        HStack {
                            Button("Copy report") {
                                UIPasteboard.general.string = crashReport
                            }
                            Spacer()
                            Button("Clear", role: .destructive) {
                                CrashReport.clear()
                                self.crashReport = nil
                            }
                            .tint(.red) // keep destructive red under the app-wide blue tint
                        }
                    } header: {
                        Text("Diagnostics")
                    } footer: {
                        Text("The app quit unexpectedly last time. This report stays on your device — screenshot or copy it to help fix the bug.")
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Why Daily Dose exists", systemImage: "heart.fill")
                            .font(.headline)
                        Text("Medication reminders are healthcare, not a subscription. Daily Dose is free, unlimited, and private — forever. No account, no server, no tracking. Your data never leaves this device.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Settings")
            .task {
                notificationStatus = await NotificationScheduler.shared.authorizationStatus()
                crashReport = CrashReport.pendingReport()
            }
        }
    }

    private var statusText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Off — tap to fix"
        default: return "Not set up"
        }
    }

    private var statusColor: Color {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        default: return .secondary
        }
    }

    // MARK: - Backup

    private struct MedBackup: Codable {
        let name, doseDetail, notes, colorName: String
        let times: [String]
        let weekdays: [Int]
        let isActive: Bool
        let pillsRemaining, refillWarnAt: Int?
    }
    private struct EventBackup: Codable {
        let medName: String
        let scheduledAt: Date
        let status: String
        let loggedAt: Date
    }
    private struct Backup: Codable {
        var app = "Daily Dose iOS"
        var version = 1
        var exportedAt = Date()
        let medications: [MedBackup]
        let events: [EventBackup]
    }

    private func exportBackup() {
        let backup = Backup(
            medications: meds.map {
                MedBackup(name: $0.name, doseDetail: $0.doseDetail, notes: $0.notes,
                          colorName: $0.colorName, times: $0.times, weekdays: $0.weekdays,
                          isActive: $0.isActive, pillsRemaining: $0.pillsRemaining,
                          refillWarnAt: $0.refillWarnAt)
            },
            events: events.map {
                EventBackup(medName: $0.medication?.name ?? "(deleted)",
                            scheduledAt: $0.scheduledAt, status: $0.status.rawValue,
                            loggedAt: $0.loggedAt)
            }
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(backup)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("daily-dose-backup-\(Date.now.formatted(.iso8601.year().month().day())).json")
            try data.write(to: url)
            exportURL = url
        } catch {
            // Stay silent on failure for now; surfaced in a later polish pass.
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(sharedModelContainer)
}
