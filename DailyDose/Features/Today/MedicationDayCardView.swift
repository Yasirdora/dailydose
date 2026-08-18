import SwiftUI

/// One medication's whole day, on one card.
///
/// The header says *what*; the timeline of chips says *how the day went* —
/// one chip per scheduled time, colour and glyph carrying the outcome. A
/// 4×-daily medicine is no longer four cards shouting for attention, and a
/// missed 13:00 can never again hide beneath a green "Taken": the red chip
/// sits in the open, in sequence.
///
/// Every chip is a real `Button` that opens the dose's detail sheet — undo,
/// late logging and corrections stay one tap away, reachable by VoiceOver,
/// Switch Control, Voice Control and Full Keyboard Access alike.
struct MedicationDayCardView: View {
    let card: MedicationDayCard
    var isHighlighted: Bool = false
    /// The clock and the missed-dose window the timing tags are read against.
    var now: Date = .now
    var window: DoseWindow = .default
    let onLog: (ResolvedDose, DoseStatus) -> Void
    /// A chip tap — opens that specific dose.
    let onOpen: (ResolvedDose) -> Void
    /// A header tap — opens the medication's whole day as a sheet.
    let onOpenDay: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The tap-confirm moment: the Taken button morphs into a checkmark
    /// before the log is written, so the feedback lands *before* the card
    /// moves to the Done section — not after, when the user is no longer
    /// looking.
    ///
    /// Keyed to the dose, not a bare flag, and always cleared after the log.
    /// A bare Bool here once disabled both buttons permanently: logging the
    /// 08:00 dose advanced the card to the 12:00 dose, SwiftUI reused the
    /// view with its @State intact, and the noon dose could never be logged.
    @State private var confirmingDoseID: String?

    private var actionable: ResolvedDose? { card.actionable }

    /// The dose that owns the headline time: the one needing action now, or
    /// the next one coming. Everything else stays in the chip row.
    private var nextDose: ResolvedDose? {
        actionable ?? card.doses.first { !$0.state.isLogged }
    }

    /// The chips show the rest of the day — the next dose already has the
    /// top-right spotlight, so repeating it as a chip would say it twice.
    private var chipDoses: [ResolvedDose] {
        guard let next = nextDose else { return card.doses }
        return card.doses.filter { $0.id != next.id }
    }

    /// Unlogged doses, any state — what the stack still holds.
    private var pendingCount: Int { card.doses.filter { !$0.state.isLogged }.count }

    /// The Lock Screen grammar: two or more doses still to take show as card
    /// edges peeking beneath, with the count badged on the tile.
    private var showsStackEdges: Bool { pendingCount >= 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !chipDoses.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(chipDoses) { dose in
                        Button {
                            Haptics.tap()
                            onOpen(dose)
                        } label: {
                            TimelineChip(dose: dose, now: now, window: window)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accessibilityLabel(for: dose))
                        .accessibilityHint(String(localized: "Opens details and more actions"))
                    }
                }
            }

            if let actionable {
                Divider()
                actions(for: actionable)
            }
        }
        .padding(16)
        .cardStyle()
        .background(alignment: .bottom) { stackEdges }
        // Room for the peeking edges, so they never touch the next card.
        .padding(.bottom, showsStackEdges ? 12 : 0)
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2.5)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: card)
        .accessibilityActions {
            if let actionable {
                Button(String(localized: "Log as taken")) { onLog(actionable, .taken) }
                Button(String(localized: "Mark as skipped")) { onLog(actionable, .skipped) }
            }
        }
    }

    // MARK: - Header

    /// The header is one big button — the card must answer a tap anywhere,
    /// the way the old stack did. The first tap opens the medication's whole
    /// day as a sheet; each chip below still opens its own specific dose.
    private var header: some View {
        Button {
            Haptics.tap()
            onOpenDay()
        } label: {
            headerContent
        }
        .buttonStyle(.plain)
        .accessibilityLabel(headerAccessibilityLabel)
        .accessibilityHint(String(localized: "Opens the day's doses for this medication"))
    }

    private var headerContent: some View {
        HStack(spacing: 14) {
            MedicationTile(
                color: MedicationColor.named(card.medication.colorName),
                form: card.medication.form,
                badge: headerBadge
            )
            .overlay(alignment: .topTrailing) {
                // The notification-stack count badge: how many doses of this
                // medication are still to take today.
                if showsStackEdges {
                    Text("\(pendingCount)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Color(.label), in: .circle)
                        .offset(x: 7, y: -7)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(card.medication.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    // Two lines, not one: at accessibility text sizes a single
                    // line truncated most real medication names.
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: 8)

            // The next moment, in the top-right spotlight — big and loud
            // while it needs you, quieter once it's simply on its way.
            if let next = nextDose {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(TimeOfDay(from: next.scheduledAt).formatted())
                        .font(.headline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(next.needsAction() ? .primary : .secondary)
                    if !next.needsAction() {
                        TimelineChip(dose: next, showsTime: false, now: now, window: window)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
    }

    private var headerAccessibilityLabel: String {
        var parts = [card.medication.name]
        if !detail.isEmpty { parts.append(detail) }
        if let next = nextDose {
            let time = TimeOfDay(from: next.scheduledAt).formatted()
            let status: String = switch next.state {
            case .upcoming: String(localized: "upcoming")
            case .due: String(localized: "due now")
            case .overdue: String(localized: "overdue")
            case .logged(.taken): String(localized: "taken")
            case .logged(.skipped): String(localized: "skipped")
            case .logged(.missed): String(localized: "missed")
            }
            parts.append("\(time), \(status)")
        }
        return parts.joined(separator: ", ")
    }

    /// The day's verdict, compressed onto the tile: a check when everything
    /// scheduled is taken, a warning when something was missed, nothing while
    /// the day is still in motion.
    private var headerBadge: MedicationTile.Badge? {
        if card.doses.allSatisfy({ $0.state == .logged(.taken) }) { return .taken }
        if card.doses.contains(where: card.isMissed) { return .missed }
        return nil
    }

    private var detail: String {
        [card.medication.doseDetail, frequency, card.medication.notes]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// "500 mg · **4 times a day**" — the frequency is the piece the chips
    /// can't say at a glance, because counting chips *is* reading. The
    /// wording lives on `DoseSchedule` so the Doses and Meds tabs always
    /// describe the same medication the same way.
    private var frequency: String {
        card.medication.schedule.frequencySummary()
    }

    // MARK: - Stack edges

    /// The two card edges that say "there is more to take" without a word of
    /// text. Frosted material with a hairline highlight and a soft shadow —
    /// the same treatment grouped notifications get on the Lock Screen, so
    /// the metaphor reads instantly.
    @ViewBuilder
    private var stackEdges: some View {
        if showsStackEdges {
            ZStack {
                stackEdge(inset: 18, drop: 12, material: .thinMaterial)
                stackEdge(inset: 9, drop: 6, material: .regularMaterial)
            }
            .accessibilityHidden(true)
        }
    }

    private func stackEdge(inset: CGFloat, drop: CGFloat, material: Material) -> some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(material)
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
            .padding(.horizontal, inset)
            .offset(y: drop)
    }

    // MARK: - Actions

    /// The call to action: the state chip anchors the left, and on the right
    /// two compact capsules — Skip in quiet glass, Taken in green.
    private func actions(for dose: ResolvedDose) -> some View {
        HStack(spacing: 10) {
            TimelineChip(dose: dose, showsTime: false, now: now, window: window)
                .accessibilityHidden(true)

            Spacer(minLength: 4)

            Button { onLog(dose, .skipped) } label: {
                Text(String(localized: "Skip"))
                    .font(.subheadline.weight(.semibold))
            }
            .secondaryButton()
            .disabled(confirmingDoseID != nil)

            Button { confirmTaken(dose) } label: {
                let confirming = confirmingDoseID == dose.id
                ZStack {
                    Text(String(localized: "Taken"))
                        .opacity(confirming ? 0 : 1)
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .opacity(confirming ? 1 : 0)
                        .scaleEffect(confirming ? 1 : 0.4)
                }
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 64)
            }
            .prominentButton()
            .tint(Theme.taken)
            .disabled(confirmingDoseID != nil)
        }
    }

    private func confirmTaken(_ dose: ResolvedDose) {
        guard confirmingDoseID == nil else { return }
        Haptics.success()
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.5)) {
            confirmingDoseID = dose.id
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            onLog(dose, .taken)
            // Always released — even if the card is reused for the next dose,
            // that dose's buttons must answer.
            confirmingDoseID = nil
        }
    }

    private func accessibilityLabel(for dose: ResolvedDose) -> String {
        let time = TimeOfDay(from: dose.scheduledAt).formatted()
        let status: String = switch dose.state {
        case .upcoming: String(localized: "upcoming")
        case .due: String(localized: "due now")
        case .overdue: String(localized: "overdue")
        case .logged(.taken): String(localized: "taken")
        case .logged(.skipped): String(localized: "skipped")
        case .logged(.missed): String(localized: "missed")
        }
        return "\(card.medication.name), \(time), \(status)"
    }
}

/// One scheduled moment: the time in monospaced digits, the outcome as colour
/// and glyph. Taken is a quiet green tick, missed an unmistakable red cross,
/// what's still to come a plain outline — the eye reads the row left to right
/// like a sentence.
///
/// Unlogged doses wear the clinical vocabulary — "Due now", "Late", "Missed"
/// — resolved from `DoseCalculator.timingTag`, so the chip, the sheet and the
/// detail view can never disagree about what a dose is.
private struct TimelineChip: View {
    let dose: ResolvedDose
    var showsTime = true
    var now: Date = .now
    var window: DoseWindow = .default

    /// Only meaningful for unlogged, non-upcoming doses.
    private var tag: DoseTimingTag {
        DoseCalculator.timingTag(for: dose.scheduledAt, now: now, window: window)
    }

    private var tint: Color {
        switch dose.state {
        case .upcoming: .secondary
        case .due, .overdue: tag == .missed ? Theme.missed : Theme.due
        case .logged(.taken): Theme.taken
        case .logged(.skipped): Theme.skipped
        case .logged(.missed): Theme.missed
        }
    }

    private var glyph: String? {
        switch dose.state {
        // In the chip row an upcoming dose shows a clock beside its time; in
        // the header's status position the relative text speaks for itself.
        case .upcoming: showsTime ? "clock" : nil
        case .due, .overdue:
            switch tag {
            case .dueNow: "bell.fill"
            case .late: "clock.badge.exclamationmark"
            case .missed: "xmark"
            case .scheduled: "clock"
            }
        case .logged(.taken): "checkmark"
        case .logged(.skipped): "forward.end.fill"
        case .logged(.missed): "xmark"
        }
    }

    private var label: String {
        let time = TimeOfDay(from: dose.scheduledAt).formatted()
        switch dose.state {
        case .upcoming:
            // Header position answers "when?" in words — "in 8 hours" is
            // kinder than "Upcoming" under a time that's already visible.
            return showsTime ? time : dose.scheduledAt.formatted(.relative(presentation: .named))
        case .logged:
            return showsTime ? time : statusText
        case .due, .overdue:
            if showsTime { return time }
            switch tag {
            case .dueNow: return String(localized: "Due now")
            case .late: return String(localized: "Late")
            case .missed: return String(localized: "Missed")
            case .scheduled: return String(localized: "Scheduled")
            }
        }
    }

    private var statusText: String {
        switch dose.state {
        case .upcoming: String(localized: "Upcoming")
        case .due, .overdue:
            switch tag {
            case .dueNow: String(localized: "Due now")
            case .late: String(localized: "Late")
            case .missed: String(localized: "Missed")
            case .scheduled: String(localized: "Scheduled")
            }
        case .logged(.taken): String(localized: "Taken")
        case .logged(.skipped): String(localized: "Skipped")
        case .logged(.missed): String(localized: "Missed")
        }
    }

    /// Logged and due/overdue moments get a filled capsule; upcoming doses in
    /// the chip row stay an outline, so attention lands on what happened and
    /// what needs doing. In the header's status position the upcoming chip is
    /// the quiet gray capsule it always was.
    private var isFilled: Bool {
        if case .upcoming = dose.state { return !showsTime }
        return true
    }

    var body: some View {
        HStack(spacing: 5) {
            if let glyph {
                Image(systemName: glyph)
            }
            Text(label)
                .monospacedDigit()
        }
        // Footnote, not caption: a dose time is information people act on,
        // and 12pt fails older eyes. The 44pt frame is the hit target and the
        // capsule grows with it — these chips are the primary way to correct
        // a dose, for the population most likely to have tremor.
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(tint)
        .background {
            if isFilled {
                Capsule().fill(tint.opacity(0.14))
            } else {
                Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 1)
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

/// Chips wrap like words in a paragraph: as many per row as fit, then a new
/// line. A missed chip must never scroll offscreen inside a horizontal
/// strip — wrapping keeps the whole truth visible at once.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
