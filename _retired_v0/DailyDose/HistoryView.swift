import SwiftUI
import SwiftData
import Charts

/// History — one honest story, top to bottom:
/// 1. "How am I doing?"        → big ring + plain-words verdict (Week / Month)
/// 2. "Which days were good?"  → one bar per day in the ring's color language
/// 3. "Which medicine slips?"  → per-medication rings
/// 4. "What actually happened?"→ the log, grouped under human day headers
struct HistoryView: View {
    @Query(sort: \DoseEvent.loggedAt, order: .reverse) private var events: [DoseEvent]
    @Query private var meds: [Medication]

    @State private var period: Period = .week

    private enum Period: Int, CaseIterable {
        case week = 7, month = 30
        var title: String { self == .week ? "Week" : "Month" }
    }

    // MARK: - Data

    private var periodEvents: [DoseEvent] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -period.rawValue, to: .now) else { return [] }
        return events.filter { $0.loggedAt >= cutoff }
    }

    private var stats: (taken: Int, skipped: Int, missed: Int, percent: Int?) {
        DoseEngine.adherence(events: events, days: period.rawValue)
    }

    private struct DayStat: Identifiable {
        let id = UUID()
        let day: Date
        let taken: Int
        let total: Int

        var percent: Double { total > 0 ? Double(taken) / Double(total) : 0 }
        /// The ring's color language: green all taken, orange some, whisper none.
        var color: Color {
            guard total > 0 else { return Color.secondary.opacity(0.18) }
            if taken == total { return .green }
            return taken > 0 ? .orange : .red.opacity(0.55)
        }
    }

    private var chartData: [DayStat] {
        let cal = Calendar.current
        let days = period == .week ? 7 : 30
        return (0..<days).reversed().compactMap { offset -> DayStat? in
            guard let day = cal.date(byAdding: .day, value: -offset, to: .now) else { return nil }
            let start = cal.startOfDay(for: day)
            guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
            let dayEvents = events.filter { $0.scheduledAt >= start && $0.scheduledAt < end }
            return DayStat(day: start,
                           taken: dayEvents.filter { $0.status == .taken }.count,
                           total: dayEvents.count)
        }
    }

    /// Meds that have any logged events in the period, best adherence last —
    /// the one that needs attention surfaces at the top of the list.
    private var medStats: [(med: Medication, taken: Int, total: Int, percent: Int)] {
        meds.compactMap { med in
            let medEvents = periodEvents.filter { $0.medication?.uuid == med.uuid }
            guard !medEvents.isEmpty else { return nil }
            let taken = medEvents.filter { $0.status == .taken }.count
            return (med, taken, medEvents.count, Int(round(100.0 * Double(taken) / Double(medEvents.count))))
        }
        .sorted { $0.percent < $1.percent }
    }

    private var groupedLog: [(day: Date, events: [DoseEvent])] {
        let cal = Calendar.current
        return Dictionary(grouping: Array(events.prefix(120))) { cal.startOfDay(for: $0.scheduledAt) }
            .map { (day: $0.key, events: $0.value.sorted { $0.scheduledAt > $1.scheduledAt }) }
            .sorted { $0.day > $1.day }
    }

    private var verdict: String {
        guard let percent = stats.percent else {
            return "Log your first doses and the story begins."
        }
        switch percent {
        case 90...: return "Excellent — barely a dose missed."
        case 70..<90: return "Good — most doses are taken."
        case 50..<70: return "Fair — there's room to improve."
        default: return "A fresh start — the reminders are here to help."
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                heroCard

                if stats.percent != nil {
                    sectionLabel("Each day")
                    dailyCard
                }

                if !medStats.isEmpty {
                    sectionLabel("Per medication")
                    perMedCard
                }

                sectionLabel("Log")
                logCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("History")
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .padding(.horizontal, 4)
    }

    // MARK: - Hero

    private var heroCard: some View {
        let percent = stats.percent
        let ringTint: Color = percent == nil ? MedPalette.accent
            : percent! >= 90 ? .green
            : percent! >= 60 ? .orange : .red
        return VStack(spacing: 14) {
            ProgressRing(progress: Double(percent ?? 0) / 100,
                         size: 120,
                         lineWidth: 14,
                         tint: ringTint,
                         centerLabel: percent.map { "\($0)%" } ?? "—")
            Text(verdict)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                StatusChip(text: "\(stats.taken) taken", color: .green, systemImage: "checkmark.circle.fill")
                if stats.skipped > 0 {
                    StatusChip(text: "\(stats.skipped) skipped", color: .secondary, systemImage: "forward.fill")
                }
                if stats.missed > 0 {
                    StatusChip(text: "\(stats.missed) missed", color: .red, systemImage: "exclamationmark.circle.fill")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .cardStyle()
    }

    // MARK: - Daily bars

    private var dailyCard: some View {
        let anyTaken = chartData.contains { $0.taken > 0 }
        return Group {
            if anyTaken {
                Chart(chartData) { stat in
                    BarMark(x: .value("Day", stat.day, unit: .day),
                            y: .value("Taken", max(stat.percent * 100, 4))) // whisper bar for empty days
                        .foregroundStyle(stat.color)
                        .cornerRadius(period == .week ? 6 : 3)
                }
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: period == .week ? 1 : 7)) { _ in
                        AxisValueLabel(format: period == .week
                                       ? .dateTime.weekday(.narrow)
                                       : .dateTime.day())
                    }
                }
                .frame(height: 140)
            } else {
                // Nothing taken yet — a whisper of encouragement, not an
                // empty white card with sad red slivers.
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("No taken doses in this \(period == .week ? "week" : "month") yet.")
                        .font(.subheadline.weight(.medium))
                    Text("The bars grow as you log doses — green for full days, orange for partial.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
            }
        }
        .padding(18)
        .cardStyle()
    }

    // MARK: - Per medication

    private var perMedCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(medStats.enumerated()), id: \.element.med.uuid) { index, entry in
                HStack(spacing: 14) {
                    DayRing(taken: entry.taken, total: entry.total, size: 38, lineWidth: 4.5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.med.displayName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Text("\(entry.taken) of \(entry.total) doses taken")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(entry.percent)%")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(entry.percent >= 90 ? .green : entry.percent >= 60 ? .orange : .red)
                }
                .padding(.vertical, 10)
                if index < medStats.count - 1 {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .cardStyle()
    }

    // MARK: - Log

    private func dayHeader(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if events.isEmpty {
                Text("Nothing logged yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(groupedLog, id: \.day) { group in
                    Text(dayHeader(group.day))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 14)
                        .padding(.bottom, 4)

                    ForEach(group.events, id: \.persistentModelID) { event in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(event.medication.map { MedPalette.color(for: $0.colorName) } ?? Color.secondary.opacity(0.4))
                                .frame(width: 10, height: 10)
                            Text(event.medication?.displayName ?? "(deleted)")
                                .font(.body)
                                .lineLimit(1)
                            Spacer()
                            Text(event.scheduledAt.formatted(date: .omitted, time: .shortened))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            StatusChip(text: event.status.rawValue.capitalized,
                                       color: chipColor(for: event.status))
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .cardStyle()
    }

    private func chipColor(for status: DoseStatus) -> Color {
        switch status {
        case .taken: return .green
        case .skipped: return .secondary
        case .missed: return .red
        }
    }
}

#Preview {
    NavigationStack { HistoryView() }
        .modelContainer(sharedModelContainer)
}
