import SwiftUI

/// Notification controls, arranged the way WhatsApp arranges them: one grouped
/// section per *kind* of alert, each with its own on/off and its own detail
/// rows, current values shown inline rather than hidden behind a tap.
///
/// The organising idea is that a person should be able to silence the part
/// that's bothering them without silencing the part that's keeping them alive.
/// A single global "notifications" switch forces that choice, and people
/// resolve it by turning everything off at the OS level — which is the outcome
/// this screen exists to prevent.
struct NotificationSettingsView: View {
    @Environment(\.doseStore) private var store
    @Environment(AppEnvironment.self) private var environment

    @State private var preferences = NotificationPreferences.default
    @State private var systemStatus: SystemStatus = .unknown
    @State private var didLoad = false

    private enum SystemStatus { case unknown, authorized, denied, notDetermined }

    var body: some View {
        Form {
            if systemStatus == .denied { systemDeniedSection }

            doseSection
            followUpSection
            quietHoursSection
            refillSection
            explainerSection
        }
        .navigationTitle(String(localized: "Notifications"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !didLoad {
                preferences = store?.preferences ?? .default
                didLoad = true
            }
            await refreshSystemStatus()
        }
        .onChange(of: preferences) { _, new in
            // Persist and reschedule on every change — no Save button, the way
            // every Settings screen on the platform behaves.
            store?.preferences = new
            new.save()
        }
    }

    // MARK: - System permission

    private var systemDeniedSection: some View {
        Section {
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Notifications are off in iOS Settings"))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(String(localized: "Nothing below can reach you until you turn them back on."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "bell.slash.fill").foregroundStyle(Theme.missed)
                }
            }
        }
    }

    // MARK: - Dose reminders

    private var doseSection: some View {
        Section {
            Toggle(String(localized: "Show notifications"), isOn: $preferences.doseRemindersEnabled)

            if preferences.doseRemindersEnabled {
                NavigationLink {
                    SoundPickerView(
                        title: String(localized: "Reminder Sound"),
                        selection: $preferences.doseSound,
                        footer: String(localized: "Played for dose reminders and their follow-ups. Medications set to Gentle stay silent whatever you pick here.")
                    )
                } label: {
                    SoundRow(title: String(localized: "Sound"), sound: preferences.doseSound)
                }

                Toggle(isOn: $preferences.bundleSimultaneousDoses) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Group by time"))
                        Text(String(localized: "One alert for everything due at once"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(String(localized: "Dose reminders"))
        } footer: {
            Text(preferences.bundleSimultaneousDoses
                 ? String(localized: "Three medications at 8:00 arrive as one notification. Tap it to log them on the Today screen.")
                 : String(localized: "Each medication gets its own notification, with Taken and Skip buttons on it. More taps saved, more alerts.")
            )
        }
    }

    // MARK: - Follow-up

    private var followUpSection: some View {
        Section {
            Toggle(String(localized: "Remind me again"), isOn: $preferences.followUpEnabled)

            if preferences.followUpEnabled {
                Picker(String(localized: "After"), selection: $preferences.followUpDelay) {
                    ForEach(NotificationPreferences.FollowUpDelay.allCases) { delay in
                        Text(delay.title).tag(delay)
                    }
                }
            }
        } header: {
            Text(String(localized: "Follow-up"))
        } footer: {
            Text(String(localized: "A single second nudge if a dose is still unlogged. It never repeats beyond that — a reminder you learn to ignore stops working for the doses that matter."))
        }
    }

    // MARK: - Quiet hours

    private var quietHoursSection: some View {
        Section {
            Toggle(String(localized: "Quiet hours"), isOn: $preferences.quietHoursEnabled)

            if preferences.quietHoursEnabled {
                DatePicker(
                    String(localized: "From"),
                    selection: timeBinding(\.quietHoursStart),
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    String(localized: "To"),
                    selection: timeBinding(\.quietHoursEnd),
                    displayedComponents: .hourAndMinute
                )
            }
        } header: {
            Text(String(localized: "Quiet hours"))
        } footer: {
            // The distinction that matters, said plainly: we silence what the
            // app decided to send, never what the user scheduled.
            Text(String(localized: "Your scheduled dose reminders still arrive — you chose those times. Quiet hours only hold back follow-ups and refill alerts, unless a medication is marked Important."))
        }
    }

    // MARK: - Refill

    private var refillSection: some View {
        Section {
            Toggle(String(localized: "Show notifications"), isOn: $preferences.refillAlertsEnabled)

            if preferences.refillAlertsEnabled {
                NavigationLink {
                    SoundPickerView(
                        title: String(localized: "Refill Sound"),
                        selection: $preferences.refillSound,
                        footer: String(localized: "Silent by default — running low is worth knowing, not worth interrupting for.")
                    )
                } label: {
                    SoundRow(title: String(localized: "Sound"), sound: preferences.refillSound)
                }

                DatePicker(
                    String(localized: "Time"),
                    selection: timeBinding(\.refillAlertTime),
                    displayedComponents: .hourAndMinute
                )
            }
        } header: {
            Text(String(localized: "Refill alerts"))
        } footer: {
            Text(String(localized: "One daytime nudge when a medication is running low. Never overnight."))
        }
    }

    // MARK: - Explainer

    private var explainerSection: some View {
        Section {
            NavigationLink {
                ImportanceGuideView()
            } label: {
                Label(String(localized: "Per-medication importance"), systemImage: "slider.horizontal.3")
            }
        } footer: {
            Text(String(localized: "Set how much each medication may interrupt on its own page, under Reminders."))
        }
    }

    // MARK: - Helpers

    /// Bridges a `TimeOfDay` preference to the `DatePicker`'s `Date` API without
    /// letting today's date leak into a value that is only ever a clock time.
    private func timeBinding(_ keyPath: WritableKeyPath<NotificationPreferences, TimeOfDay>) -> Binding<Date> {
        Binding(
            get: { preferences[keyPath: keyPath].date(on: .now, calendar: .current) ?? .now },
            set: { preferences[keyPath: keyPath] = TimeOfDay(from: $0) }
        )
    }

    private func refreshSystemStatus() async {
        let status = await environment.notificationService.authorizationStatus()
        systemStatus = switch status {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }
}

/// Explains the three importance levels once, properly, so the picker on each
/// medication can stay a picker instead of growing three paragraphs of footer.
struct ImportanceGuideView: View {
    var body: some View {
        List {
            Section {
                ForEach(MedicationImportance.allCases) { level in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: level.systemImage)
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(level.title).font(.body.weight(.semibold))
                            Text(level.explanation)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                // Honest about the ceiling. Apple's Critical Alerts override the
                // mute switch, and a general medication reminder does not
                // qualify for that entitlement — so the app does not pretend it
                // can shout through a silenced phone.
                Text(String(localized: "Standard and Important reminders break through Focus modes, but all of them respect your phone's silent switch. Daily Dose can't override it."))
            }
        }
        .navigationTitle(String(localized: "Importance"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The per-medication control, shown on a medication's own page.
struct MedicationImportancePicker: View {
    @Binding var importance: MedicationImportance

    var body: some View {
        Picker(selection: $importance) {
            ForEach(MedicationImportance.allCases) { level in
                Label(level.title, systemImage: level.systemImage).tag(level)
            }
        } label: {
            Label(String(localized: "Reminders"), systemImage: "bell.badge")
        }
    }
}
