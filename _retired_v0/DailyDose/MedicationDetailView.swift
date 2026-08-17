import SwiftUI
import SwiftData

/// The medication detail page — designed as a calm clinical card stack:
/// hero identity → next dose → schedule → supply → adherence → options.
/// Reading order answers the questions in the order a caregiver asks them:
/// "What is it? When is the next one? Do we have enough? Are we on track?"
struct MedicationDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allMeds: [Medication]

    let med: Medication

    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var showingRefill = false
    @State private var refillAmount = 30

    private var medColor: Color { MedPalette.color(for: med.colorName) }

    private var lowSupply: Bool {
        guard let pills = med.pillsRemaining, let warnAt = med.refillWarnAt else { return false }
        return pills <= warnAt
    }

    /// First unlogged scheduled dose (shared engine — see Models.swift).
    private var nextDose: Date? { med.nextDose() }

    private func prettyNextDose(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today, \(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow, \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + ", \(time)"
    }

    var body: some View {
        List {
            // MARK: Hero — identity at a glance
            Section {
                VStack(spacing: 10) {
                    Circle()
                        .fill(medColor.gradient)
                        .frame(width: 88, height: 88)
                        .overlay {
                            Image(systemName: "pill.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: medColor.opacity(0.35), radius: 12, y: 6)

                    Text(med.displayName)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if !med.doseDetail.isEmpty {
                        Text(med.doseDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !med.notes.isEmpty {
                        Label(med.notes, systemImage: "text.alignleft")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !med.isActive {
                        StatusChip(text: "Paused", color: .orange, systemImage: "pause.fill")
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .listRowBackground(Color.clear)

            // MARK: Next dose — the single most important answer
            if let next = nextDose {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "alarm.fill")
                            .font(.title3)
                            .foregroundStyle(MedPalette.accent)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Next dose")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(prettyNextDose(next))
                                .font(.body.weight(.semibold))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }

            // MARK: Schedule
            Section("Schedule") {
                Label(med.scheduleSummary, systemImage: "calendar")
                ForEach(med.times.sorted(), id: \.self) { time in
                    Label {
                        HStack {
                            Text(NotificationScheduler.prettyTimeString(time))
                            Spacer()
                            if !med.doseDetail.isEmpty {
                                Text(med.doseDetail)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
            }

            // MARK: Supply
            if let pills = med.pillsRemaining {
                Section("Supply") {
                    HStack(spacing: 14) {
                        Text("\(pills)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(lowSupply ? .orange : .primary)
                            .contentTransition(.numericText())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("pills left")
                                .font(.subheadline)
                            if let warnAt = med.refillWarnAt {
                                Text("warns below \(warnAt)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Refill") { showingRefill = true }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(MedPalette.accent)
                    }
                    .padding(.vertical, 4)

                    if lowSupply {
                        Label("Running low — plan a refill soon.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            // MARK: Adherence
            Section("Last 7 days") {
                let stats = DoseEngine.adherence(events: med.events, days: 7)
                HStack(spacing: 16) {
                    DayRing(taken: stats.taken, total: stats.taken + stats.skipped + stats.missed,
                            size: 46, lineWidth: 5)
                    VStack(alignment: .leading, spacing: 3) {
                        if let percent = stats.percent {
                            Text("\(percent)% taken")
                                .font(.body.weight(.semibold))
                            Text("\(stats.taken) taken · \(stats.skipped) skipped · \(stats.missed) missed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No doses logged yet")
                                .font(.body.weight(.semibold))
                            Text("Your week will appear here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            // MARK: Options
            Section {
                Button(med.isActive ? "Pause Medication" : "Resume Medication") {
                    toggleActive()
                }
                .foregroundStyle(MedPalette.accent)

                Button("Delete Medication") {
                    confirmingDelete = true
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle(med.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // One Edit, top right — like Apple's own detail pages.
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            AddMedicationView(med: med)
        }
        .sheet(isPresented: $showingRefill) {
            refillSheet
        }
        .confirmationDialog("Delete \(med.name)?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete Medication", role: .destructive) { deleteMed() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its history stays in your records, but reminders will stop.")
        }
    }

    // MARK: - Refill sheet

    private var refillSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Add \(refillAmount) pills", value: $refillAmount, in: 5...500, step: 5)
                } footer: {
                    Text("Count the pills in the new pack and add them to your supply.")
                }
            }
            .navigationTitle("Log a Refill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        med.pillsRemaining = (med.pillsRemaining ?? 0) + refillAmount
                        try? context.save()
                        Task { await NotificationScheduler.shared.rescheduleAll(meds: allMeds) }
                        Haptics.success()
                        showingRefill = false
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.bold))
                    }
                    .tint(MedPalette.accent)
                    .accessibilityLabel("Add to supply")
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    // MARK: - Actions

    private func toggleActive() {
        med.isActive.toggle()
        try? context.save()
        Task { await NotificationScheduler.shared.rescheduleAll(meds: allMeds) }
        Haptics.light()
    }

    private func deleteMed() {
        context.delete(med)
        try? context.save()
        Task {
            await NotificationScheduler.shared.rescheduleAll(meds: allMeds.filter { $0.uuid != med.uuid })
        }
        dismiss()
    }
}
