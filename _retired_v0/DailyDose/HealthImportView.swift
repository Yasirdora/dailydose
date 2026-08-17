import SwiftUI
import SwiftData

/// Review sheet for one-tap import from Apple Health.
/// The user picks which medications to bring in; schedules (times) are then
/// set in Daily Dose, since Health's schedule model differs from ours.
struct HealthImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var existingMeds: [Medication]

    enum Phase: Equatable { case loading, ready, empty, failed(String) }
    @State private var phase: Phase = .loading
    @State private var candidates: [HealthImportCandidate] = []
    @State private var selected: Set<String> = []
    @State private var paletteIndex = 0

    private var existingNames: Set<String> {
        Set(existingMeds.map { $0.name.lowercased() })
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Reading your medications from Apple Health…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    ContentUnavailableView {
                        Label("Nothing to import", systemImage: "heart.text.square")
                    } description: {
                        Text("No active medications were found in Apple Health — or access wasn't granted. You can change this in Settings → Health → Data Access & Devices.")
                    }
                case .failed(let detail):
                    ContentUnavailableView {
                        Label("Couldn't read Apple Health", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Please try again. Your data never leaves this device.")
                    } actions: {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                case .ready:
                    List {
                        Section {
                            ForEach(candidates) { candidate in
                                let isDuplicate = existingNames.contains(candidate.name.lowercased())
                                HStack(spacing: 12) {
                                    Image(systemName: selected.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(selected.contains(candidate.id) ? MedPalette.accent : Color.secondary.opacity(0.4))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.name)
                                            .font(.body.weight(.medium))
                                        Text(candidateSubtitle(candidate))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if isDuplicate {
                                        Text("Added")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard !isDuplicate else { return }
                                    if selected.contains(candidate.id) {
                                        selected.remove(candidate.id)
                                    } else {
                                        selected.insert(candidate.id)
                                    }
                                }
                            }
                        } header: {
                            Text("Found in Apple Health")
                        } footer: {
                            Text("Imported medications start without reminder times — tap one afterward to set its schedule. Your Health data is only read, never written or shared.")
                        }
                    }
                }
            }
            .navigationTitle("Import from Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton()
                }
                if phase == .ready {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import \(selected.isEmpty ? "" : "(\(selected.count))")") { importSelected() }
                            .disabled(selected.isEmpty)
                    }
                }
            }
            .task { await load() }
        }
    }

    private func candidateSubtitle(_ c: HealthImportCandidate) -> String {
        var parts = [c.form]
        if c.name != c.clinicalName { parts.append(c.clinicalName) }
        parts.append(c.hasSchedule ? "Scheduled in Health" : "As needed in Health")
        return parts.joined(separator: " · ")
    }

    @available(iOS 26.0, *)
    private func loadHealthKit() async {
        do {
            try await HealthKitManager.shared.requestReadAuthorization()
            let found = try await HealthKitManager.shared.fetchMedications()
            candidates = found
            selected = Set(found.filter { !existingNames.contains($0.name.lowercased()) }.map(\.id))
            phase = found.isEmpty ? .empty : .ready
        } catch {
            phase = .failed("\(error)")
        }
    }

    private func load() async {
        guard #available(iOS 26.0, *) else { phase = .failed("Requires iOS 26 or later."); return }
        await loadHealthKit()
    }

    private func importSelected() {
        for candidate in candidates where selected.contains(candidate.id) {
            let color = MedPalette.names[paletteIndex % MedPalette.names.count]
            paletteIndex += 1
            let med = Medication(
                name: candidate.name,
                doseDetail: candidate.name == candidate.clinicalName ? "" : candidate.clinicalName,
                notes: candidate.form == "medication" ? "" : "Form: \(candidate.form)",
                colorName: color,
                times: []
            )
            context.insert(med)
        }
        try? context.save()
        dismiss()
    }
}
