import SwiftUI
import SwiftData

/// Calendar at a glance — a bottom sheet showing every day as a progress ring
/// (gray → orange → green), scrollable through the months. Tapping a day
/// reveals that day's doses below the grid, and choosing a day also selects
/// it on the Today screen.
struct CalendarSheetView: View {
    @Binding var selectedDay: Date
    @Query(sort: \Medication.createdAt) private var meds: [Medication]

    @State private var inspectedDay = Date.now

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    private var inspectedDoses: [Dose] {
        DoseEngine.doses(on: inspectedDay, meds: meds, now: .now)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    dayDetail
                    ForEach(months, id: \.self) { month in
                        monthGrid(month)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
            }
        }
    }

    // MARK: - Selected day detail

    private var dayDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(inspectedDay.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.headline)
            if inspectedDoses.isEmpty {
                Text("No doses scheduled")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(inspectedDoses) { dose in
                    HStack(spacing: 12) {
                        PillGlyph(color: MedPalette.color(for: dose.medication.colorName), size: 30)
                        Text(dose.medication.name)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(dose.scheduledAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        stateLabel(dose.state)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .padding(.top, 8)
    }

    @ViewBuilder
    private func stateLabel(_ state: DoseState) -> some View {
        switch state {
        case .logged(.taken):
            Label("Taken", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.green)
        case .logged(.skipped):
            Text("Skipped").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        case .logged(.missed), .overdue:
            Text("Missed").font(.caption.weight(.semibold)).foregroundStyle(.red)
        case .due:
            Text("Due").font(.caption.weight(.semibold)).foregroundStyle(.orange)
        case .upcoming:
            Text("Upcoming").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Month grid

    /// The past 12 months through the end of the current one.
    private var months: [Date] {
        let cal = Calendar.current
        guard let current = cal.dateInterval(of: .month, for: .now)?.start else { return [] }
        return (0...12).compactMap { cal.date(byAdding: .month, value: $0 - 12, to: current) }
    }

    private func monthGrid(_ month: Date) -> some View {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .month, for: month)?.start ?? month
        let dayCount = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        // Weekday of the 1st, normalized to a 0-based column in the user's locale.
        let firstWeekday = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7

        return VStack(alignment: .leading, spacing: 10) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.title3.weight(.bold))
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Calendar.current.shortStandaloneWeekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(0..<firstWeekday, id: \.self) { _ in
                    Color.clear.frame(height: 34)
                }
                ForEach(1...dayCount, id: \.self) { dayNumber in
                    if let day = cal.date(byAdding: .day, value: dayNumber - 1, to: start) {
                        dayCell(day)
                    }
                }
            }
        }
        .padding(14)
        .cardStyle()
    }

    private func dayCell(_ day: Date) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let isInspected = cal.isDate(day, inSameDayAs: inspectedDay)
        let isFuture = cal.startOfDay(for: day) > cal.startOfDay(for: .now)
        let progress = isFuture ? (taken: 0, total: 0) : DoseEngine.dayProgress(on: day, meds: meds, now: .now)

        return DayRing(taken: progress.taken, total: progress.total, size: 34, lineWidth: 4)
            .opacity(isFuture ? 0.35 : 1)
            .overlay {
                Text(day.formatted(.dateTime.day()))
                    .font(.caption.weight(isToday ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isToday ? .white : .primary)
                    .background {
                        if isToday {
                            Circle().fill(MedPalette.accent.gradient).frame(width: 22, height: 22)
                        }
                    }
            }
            .background {
                if isInspected && !isToday {
                    Circle().stroke(MedPalette.accent, lineWidth: 1.5).padding(-4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(duration: 0.25)) {
                    inspectedDay = day
                    selectedDay = day
                }
                Haptics.select()
            }
    }
}
