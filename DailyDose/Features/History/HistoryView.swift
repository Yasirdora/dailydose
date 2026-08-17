import SwiftUI
import SwiftData
import Charts
import UIKit

/// One honest story, top to bottom:
/// how am I doing → which days were good → which medicine slips → what happened.
///
/// Every figure on this screen is measured the same way: by the day a dose was
/// *scheduled* for. Previously the headline ring counted by `loggedAt` while the
/// chart beneath it counted by `scheduledAt`, so the two could disagree and a
/// batch of backfilled misses landed entirely on today.
struct HistoryView: View {
    @Environment(\.doseStore) private var store
    @Query private var medications: [Medication]
    @Query(sort: \DoseEvent.scheduledAt, order: .reverse) private var allEvents: [DoseEvent]

    @State private var period: Period = .week
    @State private var data = HistoryData()
    @State private var exportedSummary: ExportedSummary?

    /// Wraps the file URL so `.sheet(item:)` can drive the share sheet.
    private struct ExportedSummary: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    enum Period: Int, CaseIterable, Identifiable {
        case week = 7, month = 30

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .week: String(localized: "Week")
            case .month: String(localized: "Month")
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker(String(localized: "Period"), selection: $period) {
                        ForEach(Period.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    HeroCard(summary: data.summary)

                    if data.summary.total > 0 {
                        SectionLabel(title: String(localized: "Each day"))
                        DailyChart(buckets: data.buckets, period: period)
                    }

                    if !data.byMedication.isEmpty {
                        SectionLabel(title: String(localized: "Per medication"))
                        PerMedicationCard(entries: data.byMedication)
                    }

                    SectionLabel(title: String(localized: "Log"))
                    LogCard(groups: data.log)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(String(localized: "History"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ToolbarGlyphButton(
                        systemImage: "square.and.arrow.up",
                        label: String(localized: "Share summary")
                    ) { exportSummary() }
                    .disabled(data.summary.total == 0)
                }
                ToolbarItem(placement: .primaryAction) {
                    SettingsToolbarButton()
                }
            }
            .sheet(item: $exportedSummary) { export in
                HistoryShareSheet(url: export.url)
            }
        }
        .task(id: reloadKey) { reload() }
    }

    /// Recomputes when the period changes or when the underlying data does,
    /// rather than on every render.
    private var reloadKey: String {
        "\(period.rawValue)-\(allEvents.count)-\(medications.count)"
    }

    /// Writes the visible period as plain text and hands it to the share sheet.
    ///
    /// Every number comes from the same `AdherenceCalculator` results the screen
    /// is rendering, so what someone shares can never disagree with what they
    /// were looking at when they shared it.
    private func exportSummary() {
        let text = AdherenceSummary.text(
            overall: data.summary,
            byMedication: data.byMedication.map {
                AdherenceSummary.Line(name: $0.name, summary: $0.summary)
            },
            days: period.rawValue,
            now: .now
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(AdherenceSummary.fileName(days: period.rawValue, now: .now))
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportedSummary = ExportedSummary(url: url)
            Haptics.success()
        } catch {
            Haptics.error()
        }
    }

    private func reload() {
        guard let store else { return }
        let now = Date.now
        let since = Calendar.current.date(byAdding: .day, value: -period.rawValue, to: now) ?? now
        let records = store.adherenceRecords(since: since)
        let names = Dictionary(uniqueKeysWithValues: medications.map { ($0.id, $0) })

        data = HistoryData(
            summary: AdherenceCalculator.summary(records: records, days: period.rawValue, now: now),
            buckets: AdherenceCalculator.dailyBuckets(records: records, days: period.rawValue, now: now),
            byMedication: AdherenceCalculator
                .byMedication(records: records, days: period.rawValue, now: now)
                .compactMap { entry in
                    guard let medication = names[entry.medicationID] else { return nil }
                    return MedicationAdherence(
                        id: entry.medicationID,
                        name: medication.displayName,
                        color: MedicationColor.named(medication.colorName),
                        summary: entry.summary
                    )
                },
            log: LogGroup.group(store.recentEvents(limit: 150))
        )
    }
}

/// `UIActivityViewController` for the summary file — the URL only exists once
/// the user asks for it, so `ShareLink` isn't an option.
private struct HistoryShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - View data

private struct HistoryData {
    var summary = AdherenceCalculator.Summary()
    var buckets: [AdherenceCalculator.DayBucket] = []
    var byMedication: [MedicationAdherence] = []
    var log: [LogGroup] = []
}

private struct MedicationAdherence: Identifiable {
    let id: String
    let name: String
    let color: MedicationColor
    let summary: AdherenceCalculator.Summary
}

private struct LogGroup: Identifiable {
    let day: Date
    let events: [DoseEvent]

    var id: Date { day }

    static func group(_ events: [DoseEvent]) -> [LogGroup] {
        let calendar = Calendar.current
        return Dictionary(grouping: events) { calendar.startOfDay(for: $0.scheduledAt) }
            .map { LogGroup(day: $0.key, events: $0.value.sorted { $0.scheduledAt > $1.scheduledAt }) }
            .sorted { $0.day > $1.day }
    }
}

// MARK: - Cards

private struct HeroCard: View {
    let summary: AdherenceCalculator.Summary

    var body: some View {
        VStack(spacing: 14) {
            ProgressRing(percent: summary.percent)

            Text(summary.verdict)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                StatusChip(text: String(localized: "\(summary.taken) taken"),
                           color: Theme.taken, systemImage: "checkmark.circle.fill")
                if summary.skipped > 0 {
                    StatusChip(text: String(localized: "\(summary.skipped) skipped"), color: Theme.skipped)
                }
                if summary.missed > 0 {
                    StatusChip(text: String(localized: "\(summary.missed) missed"),
                               color: Theme.missed, systemImage: "exclamationmark.circle.fill")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .cardStyle()
    }
}

private struct DailyChart: View {
    let buckets: [AdherenceCalculator.DayBucket]
    let period: HistoryView.Period

    var body: some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value(String(localized: "Day"), bucket.day, unit: .day),
                y: .value(String(localized: "Taken"), max(bucket.fraction * 100, bucket.total > 0 ? 4 : 0))
            )
            .foregroundStyle(color(for: bucket))
            .cornerRadius(period == .week ? 6 : 3)
            // Spoken per-bar, so the chart is navigable rather than an opaque
            // image to a VoiceOver user.
            .accessibilityLabel(bucket.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            .accessibilityValue(
                bucket.total > 0
                    ? String(localized: "\(bucket.taken) of \(bucket.total) doses taken")
                    : String(localized: "nothing scheduled")
            )
        }
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: period == .week ? 1 : 7)) { _ in
                AxisValueLabel(
                    format: period == .week ? .dateTime.weekday(.narrow) : .dateTime.day()
                )
            }
        }
        .frame(height: 140)
        .padding(18)
        .cardStyle()
    }

    private func color(for bucket: AdherenceCalculator.DayBucket) -> Color {
        guard bucket.total > 0 else { return .secondary.opacity(0.18) }
        if bucket.taken == bucket.total { return Theme.taken }
        return bucket.taken > 0 ? Theme.due : Theme.missed.opacity(0.55)
    }
}

private struct PerMedicationCard: View {
    let entries: [MedicationAdherence]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 14) {
                    DayRing(
                        progress: DayProgress(taken: entry.summary.taken, total: entry.summary.total),
                        size: 38, lineWidth: 4.5
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.body.weight(.semibold))
                            .lineLimit(2)
                        Text(String(localized: "\(entry.summary.taken) of \(entry.summary.total) doses taken"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(entry.summary.percent.map { "\($0)%" } ?? "—")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Theme.adherenceColor(percent: entry.summary.percent))
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)

                if index < entries.count - 1 {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .cardStyle()
    }
}

private struct LogCard: View {
    let groups: [LogGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                Text(String(localized: "Nothing logged yet."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(groups) { group in
                    Text(header(for: group.day))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(group.events) { event in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(MedicationColor.named(event.medicationColorName).color)
                                .frame(width: 10, height: 10)
                            // Denormalised, so a deleted medication still reads
                            // by name instead of collapsing to "(deleted)".
                            Text(event.medicationName)
                                .font(.body)
                                .lineLimit(1)
                            Spacer()
                            Text(TimeOfDay(from: event.scheduledAt).formatted())
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            StatusChip(text: label(for: event.status),
                                       color: Theme.statusColor(event.status))
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .cardStyle()
    }

    private func header(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func label(for status: DoseStatus) -> String {
        switch status {
        case .taken: String(localized: "Taken")
        case .skipped: String(localized: "Skipped")
        case .missed: String(localized: "Missed")
        }
    }
}
