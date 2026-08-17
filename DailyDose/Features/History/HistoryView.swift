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
    /// Bounded to the longest window this screen can show. The old query
    /// materialised every event ever recorded — two years at four doses a day
    /// is ~2,900 objects — to draw a 7-day chart.
    @Query private var events: [DoseEvent]

    @State private var period: Period = .week
    @State private var data = HistoryData()
    @State private var exportedSummary: ExportedSummary?
    /// One export at a time: two taps used to render two PDFs onto the same
    /// URL, the second overwriting a file an in-flight share still held.
    @State private var isExporting = false

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

    init() {
        // One day past the longest period, so a month view ending today still
        // sees its first day after the clock rolls past midnight.
        let since = Calendar.current.date(
            byAdding: .day, value: -(Period.month.rawValue + 1), to: .now
        ) ?? .distantPast
        _events = Query(
            filter: #Predicate { $0.scheduledAt >= since },
            sort: \DoseEvent.scheduledAt, order: .reverse
        )
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
                        label: String(localized: "Share doctor report")
                    ) { exportSummary() }
                    .disabled(data.summary.total == 0 || isExporting)
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
        "\(period.rawValue)-\(events.count)-\(medications.count)"
    }

    /// The name a medication row should carry. A deleted medication still has
    /// doses in the period, and DoseEvent denormalises `medicationName` for
    /// exactly this: the table must sum to the headline, or the report
    /// quietly disagrees with itself.
    private func rowName(for medicationID: String) -> (name: String, detail: String, color: MedicationColor) {
        if let medication = medications.first(where: { $0.id == medicationID }) {
            return (
                medication.displayName,
                [medication.doseDetail, medication.schedule.frequencySummary()]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                MedicationColor.named(medication.colorName)
            )
        }
        let remembered = events.first { $0.medicationID == medicationID }?.medicationName
        return (
            remembered ?? String(localized: "Deleted medication"),
            String(localized: "No longer in your list"),
            .default
        )
    }

    /// Writes the visible period as an A4 PDF doctor report and hands it to
    /// the share sheet.
    ///
    /// The numbers are recomputed from the store *at export time*, never
    /// reused from the on-screen cache: that cache is refreshed by a
    /// count-based key, and a dose flipped from taken to skipped changes no
    /// count — so the PDF could have contradicted the screen it was shared
    /// from. The timing appendix carries the honest pair — scheduled 08:00,
    /// taken 11:40 — which is the detail a physician actually asks about.
    private func exportSummary() {
        guard let store, !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        let now = Date.now
        let periodStart = Calendar.current.date(byAdding: .day, value: -(period.rawValue - 1), to: Calendar.current.startOfDay(for: now)) ?? now
        let since = Calendar.current.date(byAdding: .day, value: -period.rawValue, to: now) ?? now

        let records = store.adherenceRecords(since: since)

        let windowEvents = events
            .filter { $0.scheduledAt >= periodStart && $0.scheduledAt <= now }
            .sorted { $0.scheduledAt > $1.scheduledAt }
        let notable = windowEvents.compactMap(timingNote(for:))

        let reportData = DoctorReport.ReportData(
            periodDays: period.rawValue,
            periodStart: periodStart,
            generatedAt: now,
            overall: AdherenceCalculator.summary(records: records, days: period.rawValue, now: now),
            buckets: AdherenceCalculator.dailyBuckets(records: records, days: period.rawValue, now: now),
            medications: AdherenceCalculator
                .byMedication(records: records, days: period.rawValue, now: now)
                .map { entry in
                    let row = rowName(for: entry.medicationID)
                    return DoctorReport.ReportData.MedicationRow(
                        id: entry.medicationID,
                        name: row.name,
                        detail: row.detail,
                        summary: entry.summary
                    )
                },
            timingNotes: notable.prefix(20).map { DoctorReport.ReportData.TimingNote(id: $0, text: $0) },
            timingNoteCount: notable.count
        )

        do {
            let url = try DoctorReport.generate(reportData)
            exportedSummary = ExportedSummary(url: url)
            Haptics.success()
        } catch {
            Haptics.error()
        }
    }

    /// "Mon 10 Aug · Metformin — scheduled 08:00, taken 11:40 (3 hr 40 min late)"
    /// — only for doses whose timing strayed far enough to matter to a doctor.
    /// Every word goes through the localization layer: a raw-interpolated
    /// "scheduled"/"taken" would ship English inside every other language,
    /// and the hand-built "h"/"min" ignored the locale entirely.
    private func timingNote(for event: DoseEvent) -> String? {
        let delta = event.loggedAt.timeIntervalSince(event.scheduledAt)
        // Notable: over an hour late, or over 15 minutes early.
        let isLate = delta > 3600
        let isEarly = delta < -DoseCalculator.dueGrace
        guard isLate || isEarly else { return nil }

        let day = event.scheduledAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let scheduled = event.scheduledAt.formatted(date: .omitted, time: .shortened)
        let taken = event.loggedAt.formatted(date: .omitted, time: .shortened)

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = abs(delta) >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        let span = formatter.string(from: abs(delta)) ?? "\(Int(abs(delta) / 60)) min"
        let direction = isLate
            ? String(localized: "\(span) late")
            : String(localized: "\(span) early")
        return String(localized: "\(day) · \(event.medicationName) — scheduled \(scheduled), taken \(taken) (\(direction))")
    }

    private func reload() {
        guard let store else { return }
        let now = Date.now
        let since = Calendar.current.date(byAdding: .day, value: -period.rawValue, to: now) ?? now
        let records = store.adherenceRecords(since: since)

        data = HistoryData(
            summary: AdherenceCalculator.summary(records: records, days: period.rawValue, now: now),
            buckets: AdherenceCalculator.dailyBuckets(records: records, days: period.rawValue, now: now),
            byMedication: AdherenceCalculator
                .byMedication(records: records, days: period.rawValue, now: now)
                .map { entry in
                    let row = rowName(for: entry.medicationID)
                    return MedicationAdherence(
                        id: entry.medicationID,
                        name: row.name,
                        detail: row.detail,
                        color: row.color,
                        summary: entry.summary
                    )
                },
            log: LogGroup.group(store.recentEvents(limit: 150))
        )
    }
}

/// `UIActivityViewController` for the summary file — the URL only exists once
/// the user asks for it, so `ShareLink` isn't an option.
///
/// The PDF is a temp file and temp files must not pile up: when the share
/// sheet finishes — sent, saved, or cancelled — the file is deleted.
private struct HistoryShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url)
        }
        return controller
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
    let detail: String
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

    /// Below the trend threshold the ring stays silent and the words say why —
    /// the counts underneath still tell the user exactly what happened.
    private var verdictText: String {
        if summary.total > 0 && !summary.isTrendMeaningful {
            return String(localized: "A good start — the trend appears after \(AdherenceCalculator.Summary.minimumTrendSample) logged doses.")
        }
        return summary.verdict
    }

    var body: some View {
        VStack(spacing: 14) {
            ProgressRing(percent: summary.isTrendMeaningful ? summary.percent : nil)

            Text(verdictText)
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
