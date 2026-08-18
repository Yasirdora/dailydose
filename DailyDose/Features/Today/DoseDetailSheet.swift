import SwiftUI

/// Everything the card withholds: full context and every action that isn't an
/// immediate call to action — undo, late logging, correcting a mistake.
///
/// Modelled on Apple Health's medication logging sheet: a calm hero, one
/// grouped card, glass buttons, and — crucially — logging happens *in place*.
/// The sheet does not slam shut when you tap Taken; the card updates to show
/// the new state, and you leave through Done. Slamming shut robbed the user
/// of the confirmation moment and made a mis-tap feel unrecoverable.
struct DoseDetailSheet: View {
    let dose: ResolvedDose
    /// The clock and the missed-dose window the timing tags are read against.
    var now: Date = .now
    var window: DoseWindow = .default
    let onLog: (DoseStatus) -> Void
    let onUndo: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// What the user did *inside* this sheet. The passed-in `dose` is a
    /// snapshot from presentation time; without this override the card would
    /// keep showing the old state after a successful log.
    @State private var override: DoseState?

    private var effectiveState: DoseState { override ?? dose.state }

    private var timeText: String {
        TimeOfDay(from: dose.scheduledAt).formatted()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    card
                    if !dose.medication.notes.isEmpty {
                        Label(dose.medication.notes, systemImage: "text.alignleft")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .navigationTitle(dose.scheduledAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(dose.color.color.gradient)
                    .frame(width: 88, height: 88)
                Image(systemName: heroIcon)
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .shadow(color: dose.color.color.opacity(0.35), radius: 12, y: 6)

            Text(String(localized: "\(timeText) Medication"))
                .font(.title.bold())
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// The hero confirms the outcome: a checkmark once taken, the pills
    /// otherwise. Symbol replacement animates the moment of logging.
    private var heroIcon: String {
        if case .logged(.taken) = effectiveState { return "checkmark" }
        return "pills.fill"
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                MedicationTile(color: dose.color, form: dose.medication.form, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dose.medication.name)
                        .font(.headline)
                    if !dose.medication.doseDetail.isEmpty {
                        Text(dose.medication.doseDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(statusText.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(statusText.color)
                        .contentTransition(.numericText())
                }
                Spacer()
            }
            .padding(16)

            actions
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.snappy(duration: 0.25), value: effectiveState)
    }

    @ViewBuilder
    private var actions: some View {
        switch effectiveState {
        case .due, .overdue:
            Divider().padding(.leading, 16)
            HStack(spacing: 10) {
                Button { act(.skipped) } label: {
                    Text(String(localized: "Skipped"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .secondaryButton()

                Button { act(.taken) } label: {
                    Label(String(localized: "Taken"), systemImage: "checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .prominentButton()
                .tint(Theme.taken)
            }
            .padding(12)
            .transition(.opacity)

        case .logged(.taken):
            Divider().padding(.leading, 16)
            Button { undo() } label: {
                Label(String(localized: "Undo — back to unlogged"),
                      systemImage: "arrow.uturn.backward")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .secondaryButton()
            .padding(12)
            .transition(.opacity)

        case .logged(.skipped):
            // A skip is one tap with no confirmation, so the escape must be
            // one tap too: undo first, the way MedicationDaySheet offers it.
            // "Mark as taken" stays, but second — recording a pill you didn't
            // take should never be the only way back.
            Divider().padding(.leading, 16)
            HStack(spacing: 10) {
                Button { undo() } label: {
                    Label(String(localized: "Undo"), systemImage: "arrow.uturn.backward")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .secondaryButton()

                Button { act(.taken) } label: {
                    Label(String(localized: "Taken"), systemImage: "checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .prominentButton()
                .tint(Theme.taken)
            }
            .padding(12)
            .transition(.opacity)

        case .logged(.missed):
            // Missed is the system's record, not the user's tap: the one
            // correction that matters is "I actually took it".
            Divider().padding(.leading, 16)
            Button { act(.taken) } label: {
                Label(String(localized: "Mark as taken"), systemImage: "checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .prominentButton()
            .tint(Theme.taken)
            .padding(12)
            .transition(.opacity)

        case .upcoming:
            if Calendar.current.isDateInToday(dose.scheduledAt),
               Date.now >= dose.scheduledAt - DoseCalculator.earlyGrace {
                // Inside the early window (up to two hours before): logging
                // is allowed, recorded at the real time.
                Divider().padding(.leading, 16)
                HStack(spacing: 10) {
                    Button { act(.skipped) } label: {
                        Text(String(localized: "Skipped"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .secondaryButton()

                    Button { act(.taken) } label: {
                        Label(String(localized: "Taken"), systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .prominentButton()
                    .tint(Theme.taken)
                }
                .padding(12)
                .transition(.opacity)
            } else {
                // Deliberately no "take it early" button beyond the window.
                // Logging a dose hours ahead is how double-dosing starts, and
                // the reminder is already on its way.
                Divider().padding(.leading, 16)
                Label(String(localized: "Not due yet — the reminder will come to you."),
                      systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    // MARK: Status

    private var statusText: (label: String, color: Color) {
        switch effectiveState {
        case .upcoming: (String(localized: "Upcoming"), .secondary)
        case .due, .overdue:
            switch DoseCalculator.timingTag(for: dose.scheduledAt, now: now, window: window) {
            case .late: (String(localized: "Late — can still be taken"), Theme.due)
            case .missed: (String(localized: "Missed — you can still log it"), Theme.missed)
            default: (String(localized: "Due now"), Theme.due)
            }
        case .logged(.taken): (String(localized: "Taken"), Theme.taken)
        case .logged(.skipped): (String(localized: "Skipped"), .secondary)
        case .logged(.missed): (String(localized: "Missed"), Theme.missed)
        }
    }

    private func act(_ status: DoseStatus) {
        onLog(status)
        Haptics.success()
        override = .logged(status)
    }

    private func undo() {
        onUndo()
        Haptics.tap()
        // Back to actionable: if the scheduled moment has passed the dose is
        // late, otherwise it's simply due again.
        override = dose.scheduledAt > .now ? .due : .overdue
    }
}
