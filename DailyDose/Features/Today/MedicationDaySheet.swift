import SwiftUI

/// One medication's whole day, opened from its card.
///
/// The card answers the first tap with this sheet — the same gesture Apple
/// Health uses — rather than fanning a stack open in place. Everything about
/// the day lives here: each scheduled time, what became of it, and the
/// actions to change it. Logging happens *in place*; the sheet does not slam
/// shut, because the caller re-reads the card from the rebuilt model, so the
/// row updates where the user is looking.
struct MedicationDaySheet: View {
    let card: MedicationDayCard
    /// The clock and the missed-dose window the timing tags are read against.
    var now: Date = .now
    var window: DoseWindow = .default
    let onLog: (ResolvedDose, DoseStatus, Date?) -> Void
    let onUndo: (ResolvedDose) -> Void

    /// The row whose Taken tap opened the time wheel.
    @State private var confirmingTakenForDoseID: String?
    /// The wheel's time — seeded to *now* on the dose's own day, scrollable
    /// back to when it really happened.
    @State private var earlierTime: Date = .now

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    hero
                    doseList
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var day: Date { card.doses.first?.scheduledAt ?? .now }

    // MARK: - Hero

    private var hero: some View {
        HStack(spacing: 14) {
            MedicationTile(color: MedicationColor.named(card.medication.colorName), size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.medication.name)
                    .font(.title3.bold())
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        [card.medication.doseDetail,
         card.medication.schedule.frequencySummary(),
         card.medication.notes]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // MARK: - Dose list

    /// Every moment of the day, in order, each row telling the truth and
    /// offering the one action that makes sense for its state.
    private var doseList: some View {
        VStack(spacing: 0) {
            ForEach(card.doses) { dose in
                if dose.id != card.doses.first?.id {
                    Divider().padding(.leading, 16)
                }
                row(for: dose)
            }
        }
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private func row(for dose: ResolvedDose) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(TimeOfDay(from: dose.scheduledAt).formatted())
                    .font(.headline.monospacedDigit())
                Spacer()
                statusChip(for: dose)
            }
            .padding(16)

            actions(for: dose)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actions(for dose: ResolvedDose) -> some View {
        switch dose.state {
        case .due, .overdue, .logged(.missed):
            actionableControls(for: dose)

        case .upcoming where isEarlyLoggable(dose):
            // Up to two hours early, logging is allowed — appointments and
            // travel are real. The wheel keeps the record honest about *when*.
            actionableControls(for: dose)

        case .logged(.taken), .logged(.skipped):
            // A settled dose — taken or skipped — gets exactly one way back:
            // undo to unlogged, then choose again. Offering Skipped/Taken on
            // an already-skipped row only invites a mis-tap.
            Button { undo(dose) } label: {
                Label(String(localized: "Undo — back to unlogged"),
                      systemImage: "arrow.uturn.backward")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .secondaryButton()
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

        case .upcoming:
            // Beyond the early window there is deliberately no button.
            // Logging a dose hours ahead is how double-dosing starts.
            EmptyView()
        }
    }

    /// An upcoming dose within the early window — up to two hours before its
    /// time, today — may be logged now.
    private func isEarlyLoggable(_ dose: ResolvedDose) -> Bool {
        guard dose.state == .upcoming,
              Calendar.current.isDateInToday(dose.scheduledAt) else { return false }
        return Date.now >= dose.scheduledAt - DoseCalculator.earlyGrace
    }

    /// One pair of answers everywhere: Skipped in quiet glass, Taken in
    /// green. When the taken lands noticeably late — or early — the buttons
    /// give way to a time wheel, already set to *now*, and one green commit
    /// that says exactly what will be recorded.
    @ViewBuilder
    private func actionableControls(for dose: ResolvedDose) -> some View {
        VStack(spacing: 10) {
            if confirmingTakenForDoseID == dose.id {
                DatePicker(
                    String(localized: "When did you take it?"),
                    selection: $earlierTime,
                    in: dayRange(for: dose),
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Button {
                    act(dose, .taken, at: mergedTime(earlierTime, onto: dose.scheduledAt))
                    confirmingTakenForDoseID = nil
                } label: {
                    Label(String(localized: "Log taken at \(mergedTime(earlierTime, onto: dose.scheduledAt).formatted(date: .omitted, time: .shortened))"),
                          systemImage: "checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .prominentButton()
                .tint(Theme.taken)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else {
                HStack(spacing: 10) {
                    Button { act(dose, .skipped) } label: {
                        Text(String(localized: "Skipped"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .secondaryButton()

                    Button { takenTapped(dose) } label: {
                        Label(String(localized: "Taken"), systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .prominentButton()
                    .tint(Theme.taken)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(.smooth(duration: 0.3), value: confirmingTakenForDoseID)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func statusChip(for dose: ResolvedDose) -> some View {
        switch dose.state {
        case .upcoming:
            StatusChip(
                text: dose.scheduledAt.formatted(.relative(presentation: .named)),
                color: .secondary
            )
        case .due, .overdue:
            // The same vocabulary as the card chips: due, late, missed —
            // resolved against the user's window, never hardcoded.
            switch DoseCalculator.timingTag(for: dose.scheduledAt, now: now, window: window) {
            case .late:
                StatusChip(text: String(localized: "Late"), color: Theme.due,
                           systemImage: "clock.badge.exclamationmark")
            case .missed:
                StatusChip(text: String(localized: "Missed"), color: Theme.missed)
            default:
                StatusChip(text: String(localized: "Due now"), color: Theme.due, systemImage: "bell.fill")
            }
        case .logged(.taken):
            StatusChip(text: String(localized: "Taken"), color: Theme.taken,
                       systemImage: "checkmark.circle.fill")
        case .logged(.skipped):
            StatusChip(text: String(localized: "Skipped"), color: Theme.skipped,
                       systemImage: "forward.end.fill")
        case .logged(.missed):
            StatusChip(text: String(localized: "Missed"), color: Theme.missed)
        }
    }

    // MARK: - Actions

    /// Tapping Taken logs immediately only when the dose is on time. Landing
    /// noticeably late (over 90 minutes past) or *early* (an upcoming dose
    /// inside the early window) earns the time wheel, already set to now —
    /// the record deserves the real time in both directions.
    private func takenTapped(_ dose: ResolvedDose) {
        let isLate = Date.now.timeIntervalSince(dose.scheduledAt) > 90 * 60
        guard isLate || isEarlyLoggable(dose) else {
            act(dose, .taken)
            return
        }
        withAnimation(.smooth(duration: 0.25)) {
            confirmingTakenForDoseID = confirmingTakenForDoseID == dose.id ? nil : dose.id
            // Seed the wheel on the dose's own day — a date outside the
            // picker's range clamps it shut and the wheel won't move.
            earlierTime = mergedTime(.now, onto: dose.scheduledAt)
        }
        Haptics.select()
    }

    private func act(_ dose: ResolvedDose, _ status: DoseStatus, at loggedAt: Date? = nil) {
        onLog(dose, status, loggedAt)
        Haptics.success()
    }

    private func undo(_ dose: ResolvedDose) {
        onUndo(dose)
        Haptics.tap()
    }

    /// The wheel spans from the early window's edge (two hours before the
    /// scheduled time) to now: it never offers a time that hasn't happened
    /// yet, nor one earlier than the medically sensible window.
    private func dayRange(for dose: ResolvedDose) -> ClosedRange<Date> {
        let start = max(
            Calendar.current.startOfDay(for: dose.scheduledAt),
            dose.scheduledAt - DoseCalculator.earlyGrace
        )
        let end = min(
            Calendar.current.date(byAdding: .day, value: 1,
                                  to: Calendar.current.startOfDay(for: dose.scheduledAt))!,
            .now
        )
        return start...max(start, end)
    }

    /// The wheel edits hours and minutes on today's date; the answer belongs
    /// to the dose's own day.
    private func mergedTime(_ time: Date, onto day: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(
            bySettingHour: components.hour ?? 0,
            minute: components.minute ?? 0,
            second: 0,
            of: day
        ) ?? day
    }
}
