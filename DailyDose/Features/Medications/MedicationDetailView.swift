import SwiftUI
import SwiftData

/// A calm clinical card stack: identity → next dose → schedule → supply →
/// adherence → options. The reading order answers questions in the order a
/// caregiver asks them.
struct MedicationDetailView: View {
    let medication: Medication

    @Environment(\.doseStore) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var isConfirmingDelete = false
    @State private var isLoggingRefill = false
    @State private var adherence = AdherenceCalculator.Summary()
    /// Captured before deletion so the view can finish rendering safely.
    @State private var isDeleted = false

    private var color: MedicationColor { MedicationColor.named(medication.colorName) }
    private var nextDose: Date? { medication.schedule.nextOccurrence(after: .now) }

    var body: some View {
        List {
            heroSection
            if medication.needsSchedule { needsScheduleSection }
            if let nextDose, medication.isActive { nextDoseSection(nextDose) }
            scheduleSection
            if medication.pillsRemaining != nil { supplySection }
            adherenceSection
            remindersSection
            optionsSection
        }
        .navigationTitle(medication.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Edit")) { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) { MedicationEditor(medication: medication) }
        .sheet(isPresented: $isLoggingRefill) {
            RefillSheet { amount in
                store?.addSupply(amount, to: medication)
                Haptics.success()
            }
        }
        .confirmationDialog(
            String(localized: "Delete \(medication.displayName)?"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete Medication"), role: .destructive) { delete() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            // This sentence is now true. Under the old cascade delete rule the
            // history was destroyed while the dialog promised it would be kept.
            Text(String(localized: "Reminders stop, and it leaves your list. Doses you already logged stay in your history."))
        }
        .task(id: medication.persistentModelID) { refreshAdherence() }
    }

    // MARK: - Sections

    private var heroSection: some View {
        Section {
            VStack(spacing: 10) {
                MedicationTile(color: color, size: 88)
                    .shadow(color: color.color.opacity(0.3), radius: 12, y: 6)

                Text(medication.displayName)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                if !medication.doseDetail.isEmpty {
                    Text(medication.doseDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !medication.notes.isEmpty {
                    Label(medication.notes, systemImage: "text.alignleft")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if !medication.isActive {
                    StatusChip(text: String(localized: "Paused"), color: Theme.due, systemImage: "pause.fill")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Color.clear)
    }

    private var needsScheduleSection: some View {
        Section {
            Button {
                isEditing = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Set a schedule"))
                            .font(.body.weight(.semibold))
                        Text(String(localized: "This medication has no dose times yet, so it won't remind you."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark.fill")
                        .foregroundStyle(Theme.due)
                }
            }
        }
    }

    private func nextDoseSection(_ date: Date) -> some View {
        Section {
            LabeledContent {
                Text(relativeText(date)).font(.body.weight(.semibold))
            } label: {
                Label(String(localized: "Next dose"), systemImage: "alarm.fill")
            }
        }
    }

    private var scheduleSection: some View {
        Section(String(localized: "Schedule")) {
            Label(medication.schedule.summary(), systemImage: "calendar")
            ForEach(medication.schedule.sortedTimes, id: \.self) { time in
                Label {
                    HStack {
                        Text(time.formatted())
                        Spacer()
                        if !medication.doseDetail.isEmpty {
                            Text(medication.doseDetail).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "clock")
                }
            }
        }
    }

    private var supplySection: some View {
        Section(String(localized: "Supply")) {
            HStack(spacing: 14) {
                Text("\(medication.pillsRemaining ?? 0)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(medication.isLowOnSupply ? Theme.due : .primary)
                    .contentTransition(.numericText())

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "doses left")).font(.subheadline)
                    if let threshold = medication.refillThreshold {
                        Text(String(localized: "warns at \(threshold)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(String(localized: "Refill")) { isLoggingRefill = true }
                    .secondaryButton()
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

            if let runOut = estimatedRunOutDate() {
                Label {
                    Text(String(localized: "At this rate, you'll run out around \(runOut.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))."))
                } icon: {
                    Image(systemName: "calendar.badge.exclamationmark")
                }
                .font(.caption)
                .foregroundStyle(medication.isLowOnSupply ? Theme.due : .secondary)
            }
        }
    }

    private var adherenceSection: some View {
        Section(String(localized: "Last 7 days")) {
            HStack(spacing: 16) {
                DayRing(
                    progress: DayProgress(taken: adherence.taken, total: adherence.total),
                    size: 46, lineWidth: 5
                )
                VStack(alignment: .leading, spacing: 3) {
                    if let percent = adherence.percent {
                        Text(String(localized: "\(percent)% taken")).font(.body.weight(.semibold))
                        Text(String(localized: "\(adherence.taken) taken · \(adherence.skipped) skipped · \(adherence.missed) missed"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "No doses logged yet")).font(.body.weight(.semibold))
                        Text(String(localized: "Your week will appear here."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    /// The reminder level, visible without opening the editor — it changes how
    /// loudly this medication speaks, so it belongs on the page that answers
    /// "what is this and what does it do".
    private var remindersSection: some View {
        Section(String(localized: "Reminders")) {
            LabeledContent {
                Text(medication.importance.title).foregroundStyle(.secondary)
            } label: {
                Label(String(localized: "Importance"), systemImage: medication.importance.systemImage)
            }
            Text(medication.importance.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var optionsSection: some View {
        Section {
            Button(medication.isActive
                   ? String(localized: "Pause Medication")
                   : String(localized: "Resume Medication")) {
                store?.setActive(!medication.isActive, for: medication)
                Haptics.tap()
            }

            Button(String(localized: "Delete Medication"), role: .destructive) {
                isConfirmingDelete = true
            }
        } footer: {
            Text(medication.isActive
                 ? String(localized: "Pausing stops reminders without deleting anything.")
                 : String(localized: "Paused — no reminders will be sent."))
        }
    }

    // MARK: - Helpers

    /// Projects the supply forward against the real schedule, so a
    /// twice-daily medication runs out twice as fast as a once-daily one.
    private func estimatedRunOutDate() -> Date? {
        guard let remaining = medication.pillsRemaining, remaining > 0, medication.isActive else { return nil }
        let calendar = Calendar.current
        let now = Date.now
        guard let horizon = calendar.date(byAdding: .day, value: 365, to: now) else { return nil }
        let upcoming = medication.schedule.occurrences(from: now, to: horizon, calendar: calendar)
        guard upcoming.count >= remaining else { return nil }
        return upcoming[remaining - 1]
    }

    private func relativeText(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = TimeOfDay(from: date).formatted()
        if calendar.isDateInToday(date) { return String(localized: "Today, \(time)") }
        if calendar.isDateInTomorrow(date) { return String(localized: "Tomorrow, \(time)") }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + ", \(time)"
    }

    private func refreshAdherence() {
        guard let store else { return }
        let since = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        let records = store.adherenceRecords(since: since)
            .filter { $0.medicationID == medication.id }
        adherence = AdherenceCalculator.summary(records: records, days: 7, now: .now)
    }

    /// Dismiss *before* deleting.
    ///
    /// SwiftUI would otherwise re-evaluate this body against a model object the
    /// context has already invalidated, which traps at runtime. Leaving the
    /// screen first is both correct and what the user expects.
    private func delete() {
        guard !isDeleted else { return }
        isDeleted = true
        let medication = self.medication
        let store = self.store
        dismiss()
        Task { @MainActor in
            store?.delete(medication)
        }
    }
}

// MARK: - Refill sheet

private struct RefillSheet: View {
    let onAdd: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amount = 30

    /// Real pack sizes. The old stepper moved in fives, which could not express
    /// a 28-tablet blister pack or a 90-day supply — the two most common
    /// quantities a pharmacy actually hands over.
    private let presets = [14, 28, 30, 56, 60, 90, 100]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $amount, in: 1...500) {
                        Text(String(localized: "Add \(amount) doses"))
                            .contentTransition(.numericText())
                    }
                } footer: {
                    Text(String(localized: "Count what's in the new pack and add it to your supply."))
                }

                Section(String(localized: "Common pack sizes")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(presets, id: \.self) { preset in
                                Button {
                                    amount = preset
                                    Haptics.select()
                                } label: {
                                    Text("\(preset)")
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(
                                            amount == preset ? Theme.accent.opacity(0.16) : Color(.tertiarySystemFill),
                                            in: .capsule
                                        )
                                        .foregroundStyle(amount == preset ? Theme.accent : .primary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(String(localized: "\(preset) doses"))
                                .accessibilityAddTraits(amount == preset ? [.isButton, .isSelected] : .isButton)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            .navigationTitle(String(localized: "Log a Refill"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Add")) {
                        onAdd(amount)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
