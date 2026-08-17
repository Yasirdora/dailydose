import SwiftUI

/// Seven days with their adherence rings.
///
/// Each day is a real `Button` with a full spoken label, so a VoiceOver user
/// hears "Wednesday 13 August, 2 of 3 doses taken" rather than an unlabelled
/// graphic they cannot activate.
struct WeekStrip: View {
    let days: [WeekDay]
    let onSelect: (Date) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                Button { onSelect(day.date) } label: {
                    VStack(spacing: 6) {
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(day.isSelected ? Theme.accent : .secondary)

                        DayRing(progress: day.progress)
                            .overlay {
                                // Selected: a filled accent disc with the
                                // number inverted to white — Calendar's own
                                // grammar, so it reads instantly. The ring
                                // still wraps around it, so adherence is
                                // never hidden by the selection.
                                Text(day.date.formatted(.dateTime.day()))
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(day.isSelected ? .white
                                                     : day.isToday ? Theme.accent : .primary)
                                    .background {
                                        if day.isSelected {
                                            Circle()
                                                .fill(Theme.accent.gradient)
                                                .padding(-7)
                                        }
                                    }
                            }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(for: day))
                .accessibilityAddTraits(day.isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 12)
        .cardStyle(cornerRadius: 20, interactive: true)
    }

    private func label(for day: WeekDay) -> String {
        let date = day.isToday
            ? String(localized: "Today")
            : day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        guard day.progress.total > 0 else {
            return "\(date), \(String(localized: "nothing scheduled"))"
        }
        return "\(date), \(String(localized: "\(day.progress.taken) of \(day.progress.total) doses taken"))"
    }
}

// MARK: - Paging between weeks

/// The week strip as an endless pager: swipe left for next week, right for
/// the previous one.
///
/// Built on a paging `ScrollView`, not a page `TabView`. A TabView reports
/// its selection the moment the finger lifts — *before* the settle animation
/// finishes — so committing the week change there cancels the animation
/// mid-flight and the strip visibly jumps. `onScrollPhaseChange` instead
/// tells us exactly when paging has come to rest; only then do we shift the
/// selected day by one week (same weekday, Calendar's grammar) and silently
/// recentre the window. The swap happens at rest, with identical content, so
/// the eye never catches it.
struct WeekPager: View {
    let model: TodayModel
    var onSelect: ((Date) -> Void)? = nil

    /// The week currently under the finger, identified by its first day.
    /// Stable across rebuilds — logging a dose rewrites the rings without
    /// moving the pager.
    @State private var visibleWeek: Date?
    /// True while the user is dragging or the page is still settling. A
    /// rebuild that lands mid-gesture must not recenter — that yank is the
    /// jerk a native pager never has.
    @State private var isInteracting = false

    var body: some View {
        // (week start, days) pairs with stable identity across rebuilds.
        let weeks = model.weekWindow.compactMap { days -> (start: Date, days: [WeekDay])? in
            days.first.map { ($0.date, days) }
        }

        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(weeks, id: \.start) { week in
                    WeekStrip(days: week.days) { date in
                        select(date)
                    }
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $visibleWeek)
        .onAppear { visibleWeek = middle(of: weeks) }
        .modifier(ScrollSettleReporter(position: $visibleWeek) { atRest in
            isInteracting = !atRest
            if atRest { settle(weeks: weeks) }
        })
        .onChange(of: model.weekWindow) { _, _ in
            // A rebuild that nobody asked the pager about — a dose logged, a
            // day tapped, the calendar sheet — must never move the strip
            // mid-gesture.
            guard !isInteracting else { return }
            recenter()
        }
    }

    private func middle(of weeks: [(start: Date, days: [WeekDay])]) -> Date? {
        weeks.count == 3 ? weeks[1].start : weeks.first?.start
    }

    /// The pager has come to rest. If it rests on a side week, that week
    /// becomes the selected one; either way the window recentres on the
    /// middle page without animation.
    private func settle(weeks: [(start: Date, days: [WeekDay])]) {
        guard let visibleWeek,
              let index = weeks.firstIndex(where: { $0.start == visibleWeek }) else {
            recenter()
            return
        }
        let delta = index - 1
        if delta != 0,
           let shifted = Calendar.current.date(byAdding: .day, value: 7 * delta,
                                               to: model.selectedDay) {
            withAnimation(.smooth(duration: 0.3)) { model.selectedDay = shifted }
            Haptics.select()
            // The rebuild that follows triggers onChange(weekWindow), which
            // recentres — we are idle now, so it is allowed to.
        } else {
            recenter()
        }
    }

    private func recenter() {
        let middle = model.weekWindow.count == 3 ? model.weekWindow[1].first?.date : nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { visibleWeek = middle }
    }

    private func select(_ date: Date) {
        if let onSelect {
            onSelect(date)
        } else {
            withAnimation(.smooth(duration: 0.3)) { model.selectedDay = date }
        }
        Haptics.select()
    }
}

/// Reports when a pager has genuinely come to rest.
///
/// iOS 18 has the honest answer — `onScrollPhaseChange` fires `.idle` only
/// after tracking, deceleration and the settle animation have all finished.
/// iOS 17 has no such signal, so there every change of the visible page arms
/// a debounce; half a second of stillness counts as rest. Either way the
/// commitment logic never runs mid-animation — committing early is exactly
/// what makes a pager jump.
private struct ScrollSettleReporter: ViewModifier {
    @Binding var position: Date?
    let onRestChange: (Bool) -> Void

    @State private var debounce: Task<Void, Never>?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                onRestChange(phase == .idle)
            }
        } else {
            content.onChange(of: position) { _, _ in
                onRestChange(false)
                debounce?.cancel()
                debounce = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    onRestChange(true)
                }
            }
        }
    }
}

