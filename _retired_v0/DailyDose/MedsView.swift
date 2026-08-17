import SwiftUI
import SwiftData

/// The Meds page — a card deck, not a table. Each card answers three things
/// at a glance: what it is, when the next dose is, and whether supply is safe.
/// Management actions (pause, delete) live on the detail page behind a
/// confirmation — a list this important shouldn't offer one-swipe destruction.
struct MedsView: View {
    @Query(sort: \Medication.createdAt) private var meds: [Medication]

    @State private var addingNew = false
    @State private var showingHealthImport = false

    private var healthImportAvailable: Bool {
        HealthKitManager.medicationsAPISupported && HealthKitManager.shared.isAvailable
    }

    /// Soonest next dose first; meds without an upcoming dose settle at the end.
    private var active: [Medication] {
        meds.filter(\.isActive).sorted { a, b in
            switch (a.nextDose(), b.nextDose()) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.createdAt < b.createdAt
            }
        }
    }
    private var paused: [Medication] { meds.filter { !$0.isActive } }
    private var lowSupplyCount: Int {
        active.filter { med in
            guard let pills = med.pillsRemaining, let warnAt = med.refillWarnAt else { return false }
            return pills <= warnAt
        }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if healthImportAvailable {
                        importCard
                    }

                    if meds.isEmpty {
                        emptyState
                    } else {
                        if !active.isEmpty {
                            sectionHeader("Active", detail: summaryDetail)
                            ForEach(active) { med in
                                NavigationLink {
                                    MedicationDetailView(med: med)
                                } label: {
                                    MedCard(med: med)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !paused.isEmpty {
                            sectionHeader("Paused", detail: "\(paused.count)")
                                .padding(.top, 8)
                            ForEach(paused) { med in
                                NavigationLink {
                                    MedicationDetailView(med: med)
                                } label: {
                                    MedCard(med: med)
                                }
                                .buttonStyle(.plain)
                                .opacity(0.55)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Medications")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { addingNew = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add medication")
                }
            }
            .sheet(isPresented: $addingNew) {
                AddMedicationView(med: nil)
            }
            .sheet(isPresented: $showingHealthImport) {
                HealthImportView()
            }
        }
    }

    private var summaryDetail: String {
        var parts = ["\(active.count)"]
        if lowSupplyCount > 0 { parts.append("\(lowSupplyCount) low") }
        return parts.joined(separator: " · ")
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(detail.contains("low") ? .orange : .secondary)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Health import

    private var importCard: some View {
        Button { showingHealthImport = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.pink.gradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import from Apple Health")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("One tap — no re-typing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Circle()
                .fill(MedPalette.accent.opacity(0.14))
                .frame(width: 96, height: 96)
                .overlay {
                    Image(systemName: "pills.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(MedPalette.accent)
                }
            VStack(spacing: 6) {
                Text("No medications yet")
                    .font(.title3.weight(.bold))
                Text("Add your first one — reminders, supply tracking\nand history start right away.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                addingNew = true
            } label: {
                Label("Add Medication", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
            }
            .prominentButtonStyle()
            .tint(MedPalette.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

// MARK: - Med card

struct MedCard: View {
    let med: Medication

    private var color: Color { MedPalette.color(for: med.colorName) }

    private var lowSupply: Bool {
        guard let pills = med.pillsRemaining, let warnAt = med.refillWarnAt else { return false }
        return pills <= warnAt
    }

    private func prettyNext(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " \(time)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(color.gradient)
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: "pill.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(med.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !med.doseDetail.isEmpty {
                        Text(LabelScanParser.flatten(med.doseDetail))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Label(med.scheduleSummary, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            if med.isActive {
                // One chip for what matters (next dose); supply only speaks up
                // when it's running low — a calm card is a readable card.
                let next = med.nextDose()
                if next != nil || lowSupply {
                    HStack(spacing: 8) {
                        if let next {
                            StatusChip(text: "Next: \(prettyNext(next))",
                                       color: MedPalette.accent,
                                       systemImage: "alarm.fill")
                        }
                        if lowSupply, let pills = med.pillsRemaining {
                            StatusChip(text: "\(pills) left",
                                       color: .orange,
                                       systemImage: "exclamationmark.triangle.fill")
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

#Preview {
    MedsView()
        .modelContainer(sharedModelContainer)
}
