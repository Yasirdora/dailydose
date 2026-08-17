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
