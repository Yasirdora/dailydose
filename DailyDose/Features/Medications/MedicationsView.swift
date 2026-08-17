import SwiftUI
import SwiftData

struct MedicationsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \Medication.createdAt) private var medications: [Medication]

    @State private var isAdding = false
    /// Bumped when the add sheet closes — see the add button's `.id` above.
    @State private var toolbarReset = 0
    @State private var isImportingFromHealth = false
    @State private var searchText = ""
    /// Next-dose is computed once per medication per data change, not inside a
    /// sort comparator where it ran O(n log n) times per render.
    @State private var nextDoses: [String: Date] = [:]

    private var active: [Medication] {
        matching(medications.filter(\.isActive))
            .sorted { lhs, rhs in
                switch (nextDoses[lhs.id], nextDoses[rhs.id]) {
                case let (l?, r?): l < r
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): lhs.createdAt < rhs.createdAt
                }
            }
    }

    private var paused: [Medication] { matching(medications.filter { !$0.isActive }) }

    /// Search appears only once a list is long enough to be worth searching.
    /// Polypharmacy is the target user, and scrolling a card deck to find one
    /// medication is the first friction they hit.
    private var showsSearch: Bool { medications.count > 5 }

    private func matching(_ list: [Medication]) -> [Medication] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return list }
        return list.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.doseDetail.localizedCaseInsensitiveContains(query)
        }
    }

    private var lowSupplyCount: Int { active.filter(\.isLowOnSupply).count }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // Only while there's nothing to show. A one-time setup
                    // action shouldn't hold permanent space on a primary tab —
                    // it lives in Settings → Tracking from then on.
                    if HealthKitService.isSupported, medications.isEmpty {
                        HealthImportCard { isImportingFromHealth = true }
                    }

                    if medications.isEmpty {
                        MedicationsEmptyState { isAdding = true }
                    } else if active.isEmpty, paused.isEmpty {
                        // Searching found nothing. Say so, rather than showing
                        // an empty screen that reads as "you have no medications".
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 40)
                    } else {
                        if !active.isEmpty {
                            SectionLabel(
                                title: String(localized: "Active"),
                                detail: summaryDetail,
                                detailColor: lowSupplyCount > 0 ? Theme.due : .secondary
                            )
                            ForEach(active) { medication in
                                NavigationLink {
                                    MedicationDetailView(medication: medication)
                                } label: {
                                    MedicationCard(medication: medication, nextDose: nextDoses[medication.id])
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !paused.isEmpty {
                            SectionLabel(title: String(localized: "Paused"), detail: "\(paused.count)")
                                .padding(.top, 8)
                            ForEach(paused) { medication in
                                NavigationLink {
                                    MedicationDetailView(medication: medication)
                                } label: {
                                    MedicationCard(medication: medication, nextDose: nil)
                                        .opacity(0.6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(String(localized: "Medications"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // `.id` works around iOS 26 leaving a toolbar glass
                    // button dimmed after the sheet it presented closes.
                    AddMedicationToolbarButton { isAdding = true }
                        .id(toolbarReset)
                }
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    SettingsToolbarButton()
                }
            }
            .searchable(
                when: showsSearch,
                text: $searchText,
                prompt: String(localized: "Search medications")
            )
            .sheet(isPresented: $isAdding) { MedicationEditor(medication: nil) }
            .onChange(of: isAdding) { _, adding in
                if !adding { toolbarReset += 1 }
            }
            .sheet(isPresented: $isImportingFromHealth) { HealthImportView() }
            // Recompute on every store write, not on persistentModelID: an
            // edited schedule keeps the same ID, and the old key left
            // "next dose" showing a time the store no longer holds.
            .task(id: environment.store.revision) { recomputeNextDoses() }
        }
    }

    private var summaryDetail: String {
        var parts = ["\(active.count)"]
        if lowSupplyCount > 0 { parts.append(String(localized: "\(lowSupplyCount) low")) }
        return parts.joined(separator: " · ")
    }

    private func recomputeNextDoses() {
        let now = Date.now
        nextDoses = medications.reduce(into: [:]) { result, medication in
            guard medication.isActive else { return }
            result[medication.id] = medication.schedule.nextOccurrence(after: now)
        }
    }
}

// MARK: - Card

struct MedicationCard: View {
    let medication: Medication
    let nextDose: Date?

    private var color: MedicationColor { MedicationColor.named(medication.colorName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MedicationTile(
                    color: color,
                    size: 54,
                    badge: medication.needsSchedule ? .needsSetup : nil
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(medication.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !medication.doseDetail.isEmpty {
                        Text(medication.doseDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // Subheadline, not caption, and plain words, not an icon:
                    // "4 times a day" is the single most-asked question about
                    // any medication, and it must be readable at arm's length.
                    Text(scheduleText)
                        .font(.subheadline)
                        .foregroundStyle(medication.needsSchedule ? Theme.due : .secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            if medication.isActive, nextDose != nil || medication.isLowOnSupply {
                HStack(spacing: 8) {
                    if let nextDose {
                        StatusChip(
                            text: relativeText(nextDose),
                            color: Theme.accent,
                            systemImage: "alarm.fill"
                        )
                    }
                    if medication.isLowOnSupply, let remaining = medication.pillsRemaining {
                        StatusChip(
                            text: String(localized: "\(remaining) left"),
                            color: Theme.due,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// A medication with no dose times can never remind. Say so on the card
    /// instead of showing "Every day" for something that will never fire —
    /// which is where every Apple Health import used to land.
    private var scheduleText: String {
        medication.needsSchedule
            ? String(localized: "Tap to set a schedule")
            : medication.schedule.frequencySummary()
    }

    private func relativeText(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = TimeOfDay(from: date).formatted()
        if calendar.isDateInToday(date) { return String(localized: "Today \(time)") }
        if calendar.isDateInTomorrow(date) { return String(localized: "Tomorrow \(time)") }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " \(time)"
    }
}

// MARK: - Empty state

private struct MedicationsEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "pills.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent)
                .padding(26)
                .background(Theme.accent.opacity(0.12), in: .circle)

            VStack(spacing: 6) {
                Text(String(localized: "No medications yet"))
                    .font(.title3.weight(.bold))
                Text(String(localized: "Add your first one — reminders, supply tracking and history start right away."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: onAdd) {
                Label(String(localized: "Add Medication"), systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
            }
            .prominentButton()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

private struct HealthImportCard: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.pink.gradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "Import from Apple Health"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(String(localized: "One tap — no re-typing."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: .rect(cornerRadius: 20, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
