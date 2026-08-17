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
/// Three pages — previous, current, next — rendered from `model.weekWindow`
/// under a native page `TabView`, so the physics (drag, rubber-band, settle)
/// are the same ones every Apple pager has. Landing on a side page shifts the
/// selected day by exactly one week — the same weekday, the way Calendar's
/// week view moves — and the window then silently recentres on the middle
/// page, ready to swipe again in either direction. There is no first or last
/// week to hit.
struct WeekPager: View {
    let model: TodayModel
    var onSelect: ((Date) -> Void)? = nil

    @State private var page = 1   // 0 previous · 1 current · 2 next

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(model.weekWindow.enumerated()), id: \.offset) { index, days in
                WeekStrip(days: days) { date in
                    select(date)
                }
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // The strip's intrinsic height: weekday label + gap + ring + card
        // padding. Page TabViews need a bound or they collapse.
        .frame(height: 104)
        .onChange(of: page) { _, landed in
            guard landed != 1 else { return }
            let delta = landed == 2 ? 7 : -7
            withAnimation(.smooth(duration: 0.3)) {
                if let shifted = Calendar.current.date(byAdding: .day, value: delta,
                                                       to: model.selectedDay) {
                    model.selectedDay = shifted
                }
            }
            Haptics.select()
        }
        .onChange(of: model.selectedDay) { _, _ in
            // Any day change — a tap, the return-to-today arrow, or a settled
            // swipe — recentres the window without animation, so the user
            // never sees the middle page swap.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { page = 1 }
        }
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

