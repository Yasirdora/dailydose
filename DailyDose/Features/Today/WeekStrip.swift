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
                            // A day that hasn't happened yet is dimmed, not
                            // emptied: an empty ring reads as "fully missed",
                            // and a future day can never be missed.
                            .opacity(day.isFuture ? 0.3 : 1)
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
        if day.isFuture {
            return day.progress.total > 0
                ? "\(date), \(String(localized: "\(day.progress.total) doses scheduled, upcoming"))"
                : "\(date), \(String(localized: "upcoming"))"
        }
        guard day.progress.total > 0 else {
            return "\(date), \(String(localized: "nothing scheduled"))"
        }
        return "\(date), \(String(localized: "\(day.progress.taken) of \(day.progress.total) doses taken"))"
    }
}


// MARK: - Paging between weeks

/// The week strip as an endless pager: drag it sideways, and the previous
/// and next weeks are already there, riding with your finger.
///
/// Neither a page `TabView` nor a paging `ScrollView` is right for this.
/// Both decide the target page the instant the finger lifts and then play
/// their own settle animation — if any state changes in that window (and a
/// week commit always changes state), the animation is cancelled mid-flight
/// and the strip jumps. This pager instead owns the whole motion:
///
/// · While dragging, the three strips translate 1:1 with the finger.
/// · On release, a spring either snaps back or carries the strip fully off
///   screen, decided by *predicted* end position, so a quick flick always
///   turns the page and a slow drag has to earn it past halfway.
/// · Only when the spring is logically complete does the week commit happen
///   and the offset silently reset to zero — the swap lands on identical
///   content at rest, which is what makes it invisible.
///
/// The only mutable state is the drag offset; the strips' positions are a
/// pure function of the model's 3-week window, so rebuilds from logging or
/// day taps can never move anything under the user's finger.
struct WeekPager: View {
    let model: TodayModel
    var onSelect: ((Date) -> Void)? = nil

    /// Live finger translation, in points. Zero means the current week sits
    /// centred; ±width means a neighbour fully covers it.
    @State private var drag: CGFloat = 0
    @State private var width: CGFloat = 0
    /// Set while the commit spring is playing, so a second grab can't fight it.
    @State private var isCommitting = false

    private let settle = Animation.spring(duration: 0.35)

    var body: some View {
        let weeks = model.weekWindow.compactMap { days -> (start: Date, days: [WeekDay])? in
            days.first.map { ($0.date, days) }
        }

        ZStack {
            ForEach(Array(weeks.enumerated()), id: \.element.start) { index, week in
                WeekStrip(days: week.days) { date in
                    select(date)
                }
                .frame(width: width)
                .offset(x: CGFloat(index - 1) * width + drag)
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard !isCommitting else { return }
                drag = value.translation.width
            }
            .onEnded { value in
                guard !isCommitting, width > 0 else { return }
                let predicted = value.predictedEndTranslation.width
                if predicted <= -width / 2 {
                    commit(1)       // flung or dragged left → next week
                } else if predicted >= width / 2 {
                    commit(-1)      // right → previous week
                } else {
                    withAnimation(settle) { drag = 0 }
                }
            }
    }

    /// Slides the strip fully aside with a spring, then — once the motion is
    /// logically complete — shifts the selected day by a week and resets the
    /// offset without animation. At rest, over identical content.
    private func commit(_ direction: Int) {
        isCommitting = true
        withAnimation(settle, completionCriteria: .logicallyComplete) {
            drag = direction == 1 ? -width : width
        } completion: {
            if let shifted = Calendar.current.date(byAdding: .day, value: 7 * direction,
                                                   to: model.selectedDay) {
                model.selectedDay = shifted
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                drag = 0
                isCommitting = false
            }
            Haptics.select()
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
