import SwiftUI
import SwiftData

/// Month grids of adherence rings, newest first.
///
/// The current month sits on top and the past unfolds downward, the way a
/// journal reads — no scroll-to-today dance on open. Tapping any day opens
/// that day as a sheet of the same medication cards the Doses tab uses, so
/// reviewing and correcting history is one gesture, with one visual language.
///
/// The weekday header rotates with the locale's first weekday, and progress
/// is computed once, off the main thread, into a dictionary — per-cell live
/// computation is what made this sheet stall with a few months of history.
struct CalendarSheet: View {
    @Binding var selectedDay: Date

    @Environment(\.doseStore) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var progressByDay: [Date: DayProgress] = [:]
    /// The day currently shown as a sheet, if any.
    @State private var presentedDay: Date?

    private let calendar = Calendar.current

    /// Twelve months back through this month, ascending — the present rests
    /// at the bottom of the sheet, and the past is a scroll *upward*, the way
    /// a message thread works. The sheet opens already at the bottom, so the
    /// first thing seen is this month.
    private var months: [Date] {
        guard let thisMonth = calendar.dateInterval(of: .month, for: .now)?.start else { return [] }
        return (-12...0).compactMap { calendar.date(byAdding: .month, value: $0, to: thisMonth) }
    }

    /// Weekday symbols rotated to the user's first day of the week, so the
    /// labels line up with the columns beneath them.
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(months, id: \.self) { month in
                            monthGrid(month).id(month)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .task {
                    await loadProgress()
                    // The present rests at the bottom; the past is a scroll up.
                    if let thisMonth = months.last {
                        proxy.scrollTo(thisMonth, anchor: .bottom)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(String(localized: "Calendar"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
            }
        }
        .sheet(isPresented: Binding(
            get: { presentedDay != nil },
            set: { if !$0 { presentedDay = nil } }
        )) {
            if let presentedDay {
                DayDetailSheet(day: presentedDay, onChange: {
                    Task { await loadProgress() }
                })
            }
        }
    }

    // MARK: - Month grid

    private func monthGrid(_ month: Date) -> some View {
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let dayCount = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let leadingBlanks = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7

        return VStack(alignment: .leading, spacing: 10) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 10) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                ForEach(0..<leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(height: 34)
                }
                ForEach(1...dayCount, id: \.self) { dayNumber in
                    if let day = calendar.date(byAdding: .day, value: dayNumber - 1, to: start) {
                        dayCell(day)
                    }
                }
            }
        }
        .padding(14)
        .cardStyle()
    }

    private func dayCell(_ day: Date) -> some View {
        let dayStart = calendar.startOfDay(for: day)
        let isToday = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isFuture = dayStart > calendar.startOfDay(for: .now)
        let progress = progressByDay[dayStart] ?? DayProgress(taken: 0, total: 0)

        return Button {
            // The calendar navigates the Doses tab as before — and now also
            // opens the day itself, so a tap is answered immediately.
            selectedDay = day
            presentedDay = dayStart
            Haptics.select()
        } label: {
            DayRing(progress: isFuture ? DayProgress(taken: 0, total: 0) : progress)
                .opacity(isFuture ? 0.35 : 1)
                .overlay {
                    Text(day.formatted(.dateTime.day()))
                        .font(.caption.weight(isToday ? .bold : .medium).monospacedDigit())
                        .foregroundStyle(isToday ? .white : .primary)
                        .background {
                            if isToday {
                                Circle().fill(Theme.accent.gradient).frame(width: 24, height: 24)
                            }
                        }
                }
                .background {
                    if isSelected && !isToday {
                        Circle().stroke(Theme.accent, lineWidth: 1.5).padding(-4)
                    }
                }
                // 44pt: the primary correction control in a calendar, for the
                // population most likely to have tremor. The ring stays its
                // visual size; the frame carries the hit target.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(day: day, progress: progress, isFuture: isFuture))
        .accessibilityHint(String(localized: "Opens the day"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func accessibilityLabel(day: Date, progress: DayProgress, isFuture: Bool) -> String {
        let date = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        if isFuture || progress.total == 0 { return date }
        return "\(date), \(String(localized: "\(progress.taken) of \(progress.total) doses taken"))"
    }

    // MARK: - Data

    /// Computes every day's progress once, off the main actor.
    ///
    /// The whole range is fetched in a single pass and indexed, rather than
    /// re-deriving each cell during scrolling — which is what made this sheet
    /// stall once a user had a few months of history.
    private func loadProgress() async {
        guard let store else { return }

        guard let first = months.first,
              let rangeEnd = calendar.date(byAdding: .month, value: 1, to: months.last ?? .now)
        else { return }

        let snapshots = store.snapshots()
        let events = store.loggedEvents(from: first, to: rangeEnd)
        let now = Date.now
        let calendar = self.calendar
        let window = store.doseWindow

        let computed = await Task.detached(priority: .userInitiated) {
            var result: [Date: DayProgress] = [:]
            var day = calendar.startOfDay(for: first)
            while day < rangeEnd {
                let progress = DoseCalculator.progress(
                    on: day, medications: snapshots, events: events,
                    now: now, window: window, calendar: calendar
                )
                if progress.total > 0 { result[day] = progress }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            return result
        }.value

        progressByDay = computed
    }
}

/// One day, opened from the calendar.
///
/// The same medication cards the Doses tab speaks in — timeline chips, action
/// buttons, the works — so correcting a past day feels identical to logging
/// today's, and nothing about the presentation needs to be learned twice.
private struct DayDetailSheet: View {
    let day: Date
    /// Called after every write so the calendar's rings stay honest.
    let onChange: () -> Void

    @Environment(\.doseStore) private var store

    @State private var cards: [MedicationDayCard] = []
    @State private var presentedDose: ResolvedDose?

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if cards.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 36))
                                .foregroundStyle(Theme.accent)
                            Text(String(localized: "Nothing scheduled for this day"))
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .cardStyle()
                    } else {
                        ForEach(cards) { card in
                            MedicationDayCardView(
                                card: card,
                                now: .now,
                                window: store?.doseWindow ?? .default,
                                onLog: { log($0, as: $1) },
                                onOpen: { presentedDose = $0 },
                                onOpenDay: {
                                    if let next = card.actionable ?? card.doses.first {
                                        presentedDose = next
                                    }
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
            }
        }
        .presentationDetents([.medium, .large])
        .task { reload() }
        .sheet(item: $presentedDose) { dose in
            DoseDetailSheet(
                dose: dose,
                now: .now,
                window: store?.doseWindow ?? .default,
                onLog: { log(dose, as: $0) },
                onUndo: { undo(dose) }
            )
        }
    }

    // MARK: - Data

    private func reload() {
        guard let store else { return }
        let snapshots = store.snapshots()
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
        let events = store.loggedEvents(from: dayStart, to: dayEnd)
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })

        let resolved = DoseCalculator
            .doses(on: day, medications: snapshots, events: events,
                   now: .now, window: store.doseWindow, calendar: calendar)
            .compactMap { dose in byID[dose.medicationID].map { ResolvedDose(dose: dose, medication: $0) } }

        // Same order attention demands on the Doses tab: what needs action,
        // then the record.
        cards = DayPlan(doses: resolved).cards.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            return lhs.sortDate < rhs.sortDate
        }
    }

    private func log(_ dose: ResolvedDose, as status: DoseStatus) {
        store?.log(medicationID: dose.medication.id, scheduledAt: dose.scheduledAt, status: status)
        Haptics.success()
        reload()
        onChange()
    }

    private func undo(_ dose: ResolvedDose) {
        store?.undoLog(medicationID: dose.medication.id, scheduledAt: dose.scheduledAt)
        Haptics.tap()
        reload()
        onChange()
    }
}
