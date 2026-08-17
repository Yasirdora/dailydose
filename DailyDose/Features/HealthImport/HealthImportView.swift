import SwiftUI
import SwiftData

/// Pick which medications to bring across from Apple Health.
///
/// Health's schedule model doesn't map onto ours, so imports arrive without
/// dose times. That used to leave them silently inert — listed as "Every day"
/// while never reminding anyone. Now the import ends by walking straight into
/// the editor for the first one, and every unscheduled medication is badged
/// until it has times.
struct HealthImportView: View {
    @Environment(\.doseStore) private var store
    @Environment(\.dismiss) private var dismiss
    @Query private var existing: [Medication]

    @State private var phase: Phase = .loading
    @State private var candidates: [HealthMedication] = []
    @State private var selection: Set<String> = []
    @State private var medicationToSchedule: Medication?

    private enum Phase: Equatable {
        case loading, ready, empty, unsupported
        case failed(String)
    }

    private var existingNames: Set<String> {
        Set(existing.map { $0.displayName.lowercased() })
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "Import from Health"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
                    if phase == .ready {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Import")) { importSelected() }
                                .fontWeight(.semibold)
                                .disabled(selection.isEmpty)
                        }
                    }
                }
                .task { await load() }
                .sheet(item: $medicationToSchedule) { medication in
                    MedicationEditor(medication: medication, onSaved: { dismiss() })
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                Text(String(localized: "Reading your medications from Apple Health…"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unsupported:
            ContentUnavailableView {
                Label(String(localized: "Not available on this device"), systemImage: "heart.text.square")
            } description: {
                Text(String(localized: "Importing medications from Apple Health needs iOS 26 or later. You can add them by hand in the meantime."))
            }

        case .empty:
            ContentUnavailableView {
                Label(String(localized: "Nothing to import"), systemImage: "heart.text.square")
            } description: {
                Text(String(localized: "No active medications were found in Apple Health — or access wasn't granted. You can change that in Settings → Health → Data Access & Devices."))
            }

        case .failed(let detail):
            ContentUnavailableView {
                Label(String(localized: "Couldn't read Apple Health"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(String(localized: "Please try again. Your health data never leaves this device."))
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
                        row(candidate)
                    }
                } header: {
                    Text(String(localized: "Found in Apple Health"))
                } footer: {
                    Text(String(localized: "Imported medications arrive without reminder times — you'll set the schedule next. Your Health data is only read, never written or shared."))
                }
            }
        }
    }

    private func row(_ candidate: HealthMedication) -> some View {
        let isDuplicate = existingNames.contains(candidate.name.lowercased())
        let isSelected = selection.contains(candidate.id)

        return Button {
            if isSelected { selection.remove(candidate.id) } else { selection.insert(candidate.id) }
            Haptics.select()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary.opacity(0.4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle(candidate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if isDuplicate {
                    Text(String(localized: "Already added"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isDuplicate)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func subtitle(_ candidate: HealthMedication) -> String {
        var parts = [candidate.form]
        if candidate.name != candidate.clinicalName { parts.append(candidate.clinicalName) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Loading

    private func load() async {
        guard HealthKitService.isSupported else {
            phase = .unsupported
            return
        }
        guard #available(iOS 26.0, *) else {
            phase = .unsupported
            return
        }
        do {
            try await HealthKitService.shared.requestReadAuthorization()
            let found = try await HealthKitService.shared.fetchMedications()
            candidates = found
            selection = Set(
                found.filter { !existingNames.contains($0.name.lowercased()) }.map(\.id)
            )
            phase = found.isEmpty ? .empty : .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Importing

    private func importSelected() {
        guard let store else { return }
        let palette = MedicationColor.allCases
        // Continue the palette from what's already in use, so a second import
        // doesn't hand out the same colours again.
        var colorIndex = existing.count

        var firstImported: Medication?
        for candidate in candidates where selection.contains(candidate.id) {
            let color = palette[colorIndex % palette.count]
            colorIndex += 1

            let medication = store.add(
                name: candidate.name,
                doseDetail: candidate.name == candidate.clinicalName ? "" : candidate.clinicalName,
                notes: candidate.form == "medication" ? "" : String(localized: "Form: \(candidate.form)"),
                colorName: color.rawValue,
                // No times yet — deliberately, and visibly. The card badges it
                // and the next step sets the schedule.
                schedule: DoseSchedule(kind: .daily, times: [], startDate: .now),
                pillsRemaining: nil,
                refillThreshold: nil
            )
            if firstImported == nil { firstImported = medication }
        }

        Haptics.success()
        // Hand the user straight into scheduling rather than dropping them back
        // on a list of medications that won't remind them of anything.
        if let firstImported {
            medicationToSchedule = firstImported
        } else {
            dismiss()
        }
    }
}
