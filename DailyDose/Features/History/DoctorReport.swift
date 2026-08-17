import SwiftUI
import UIKit

/// The doctor report: a paginated A4 PDF that turns the log into something a
/// physician can act on.
///
/// Everything on the page is measured the same way the History tab measures
/// it — by the day a dose was *scheduled* for — and every timing note comes
/// from the honest pair we record: scheduled 08:00, taken 11:40. The report
/// a patient hands over can never disagree with the app they were looking at.
///
/// Rendered natively: SwiftUI pages → `ImageRenderer` → `UIGraphicsPDFRenderer`.
/// Fixed light scheme and explicit colors, because a PDF has no dark mode.
enum DoctorReport {

    struct ReportData {
        struct MedicationRow: Identifiable {
            let id: String
            let name: String
            let detail: String
            let summary: AdherenceCalculator.Summary
        }

        struct TimingNote: Identifiable {
            let id: String
            let text: String
        }

        let periodDays: Int
        let periodStart: Date
        let generatedAt: Date
        let overall: AdherenceCalculator.Summary
        let buckets: [AdherenceCalculator.DayBucket]
        let medications: [MedicationRow]
        /// Doses taken notably late or early — the detail a doctor actually
        /// asks about. Capped; the report is a summary, not a dump.
        let timingNotes: [TimingNote]
        /// How many notable doses exist in total, so a capped list can say
        /// "the 20 most recent of 47" instead of implying it is complete.
        var timingNoteCount: Int = 0
    }

    /// A4 at 72 dpi.
    static let pageSize = CGSize(width: 595, height: 842)

    // MARK: - Pagination

    /// Splits the content into page-sized chunks *before* rendering.
    ///
    /// The overview page has a fixed cost (header, ring, chart, footer) that
    /// leaves room for only a handful of medication rows; beyond that, rows
    /// used to spill past the page bounds and were silently clipped away —
    /// the PDF simply never mentioned some medications. Chunking up front
    /// means every row lands on a page, page numbers are true, and the
    /// footer total is derived rather than guessed.
    struct PageLayout {
        /// Rows that fit on the overview beneath the chart.
        let overviewMedications: [ReportData.MedicationRow]
        /// Remaining rows, one slice per continuation page.
        let medicationPages: [[ReportData.MedicationRow]]
        /// Timing notes, one slice per page.
        let timingPages: [[ReportData.TimingNote]]

        /// Row budgets are deliberately conservative: a wrapped medication
        /// detail line or a long note must still fit, and `.clipped()` on the
        /// page frame is the last-resort guard, not the plan.
        static let overviewRowBudget = 5
        static let continuationRowBudget = 13
        static let timingRowBudget = 14

        var totalPages: Int {
            1 + medicationPages.count + timingPages.count
        }

        init(data: ReportData) {
            let medications = data.medications
            overviewMedications = Array(medications.prefix(Self.overviewRowBudget))
            medicationPages = Array(medications.dropFirst(Self.overviewRowBudget))
                .chunked(into: Self.continuationRowBudget)
            timingPages = data.timingNotes.chunked(into: Self.timingRowBudget)
        }
    }

    @MainActor
    static func generate(_ data: ReportData) throws -> URL {
        let layout = PageLayout(data: data)
        let total = layout.totalPages

        var pages: [AnyView] = [AnyView(OverviewPage(
            data: data, medications: layout.overviewMedications,
            continues: !layout.medicationPages.isEmpty,
            page: 1, totalPages: total
        ))]
        for (index, chunk) in layout.medicationPages.enumerated() {
            pages.append(AnyView(MedicationPage(
                medications: chunk, page: index + 2, totalPages: total
            )))
        }
        for (index, chunk) in layout.timingPages.enumerated() {
            pages.append(AnyView(TimingPage(
                notes: chunk, showsHeading: index == 0,
                totalCount: data.timingNoteCount,
                page: layout.medicationPages.count + index + 2, totalPages: total
            )))
        }

        let pageRect = CGRect(origin: .zero, size: pageSize)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(periodDays: data.periodDays, generatedAt: data.generatedAt))

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: String(localized: "Medication Adherence Report"),
            kCGPDFContextAuthor as String: "Daily Dose",
        ]

        try UIGraphicsPDFRenderer(bounds: pageRect, format: format).writePDF(to: url) { context in
            for page in pages {
                context.beginPage()
                let cg = context.cgContext
                cg.saveGState()
                // ImageRenderer draws in SwiftUI's top-left space; a PDF page
                // is bottom-left. Flip the context or every page prints
                // upside down — and flip by the size the renderer actually
                // used, not the size we hoped for.
                ImageRenderer(content: page.environment(\.colorScheme, .light)).render { size, draw in
                    cg.translateBy(x: 0, y: size.height)
                    cg.scaleBy(x: 1, y: -1)
                    draw(cg)
                }
                cg.restoreGState()
            }
        }
        return url
    }

    static func fileName(periodDays: Int, generatedAt: Date) -> String {
        let stamp = generatedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return "Medication-Report-\(periodDays)d-\(stamp).pdf"
    }
}

// MARK: - Page 1: overview

private struct OverviewPage: View {
    let data: DoctorReport.ReportData
    let medications: [DoctorReport.ReportData.MedicationRow]
    /// True when further medication rows continue on the next page.
    let continues: Bool
    let page: Int
    let totalPages: Int

    private var periodText: String {
        let start = data.periodStart.formatted(.dateTime.day().month(.abbreviated))
        let end = data.generatedAt.formatted(.dateTime.day().month(.abbreviated).year())
        // One localized string, not two dates around a bare en-dash — raw
        // concatenation renders in reversed order in RTL languages.
        return String(localized: "\(start) – \(end)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            overallSection
            chartSection
            medicationSection
            Spacer(minLength: 0)
            ReportFooter(page: page, totalPages: totalPages)
        }
        .padding(44)
        .frame(width: DoctorReport.pageSize.width, height: DoctorReport.pageSize.height)
        // Overflow must fail visibly in development, never silently in a
        // report a patient hands to their doctor.
        .clipped()
        .background(Color.white)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Medication Adherence Report"))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.black)
                Text(periodText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.gray)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("Daily Dose")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.0, green: 0.68, blue: 0.78))
                Text(String(localized: "Generated \(data.generatedAt.formatted(.dateTime.day().month(.abbreviated).year()))"))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.gray)
            }
        }
    }

    private var overallSection: some View {
        // Below the trend threshold the ring shows a dash, same as the
        // on-screen hero card — a doctor reading "100%" over one logged dose
        // would be misled.
        let percent = data.overall.isTrendMeaningful ? data.overall.percent : nil
        return HStack(spacing: 28) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.15), lineWidth: 10)
                if let percent {
                    Circle()
                        .trim(from: 0, to: max(0.01, Double(percent) / 100))
                        .stroke(Theme.adherencePrintColor(percent: percent),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(percent.map { "\($0)%" } ?? "—")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.black)
            }
            .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Overall adherence"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.black)
                Text(String(localized: "\(data.overall.taken) taken · \(data.overall.skipped) skipped · \(data.overall.missed) missed"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.gray)
                Text(data.overall.total == 1
                     ? String(localized: "of 1 scheduled dose")
                     : String(localized: "of \(data.overall.total) scheduled doses"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.gray)
            }
            Spacer()
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Each day"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.black)

            // Hand-drawn bars, not SwiftUI Charts: fully deterministic in a
            // renderer, no animation or layout passes to surprise the PDF.
            //
            // Meaning is carried by shape, not hue alone — this page's normal
            // fate is a monochrome office laser, where green-at-full and
            // red-at-55% are the same grey. The outline's height is the day's
            // scheduled count; the solid fill rising from the bottom is the
            // taken share; a day with nothing scheduled is a hollow dash.
            HStack(alignment: .bottom, spacing: data.periodDays > 7 ? 3 : 6) {
                ForEach(data.buckets) { bucket in
                    if bucket.total > 0 {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(barColor(for: bucket))
                                .frame(height: max(3, outlineHeight(for: bucket) * bucket.fraction))
                        }
                        .frame(height: outlineHeight(for: bucket))
                    } else {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                            .frame(height: 8)
                    }
                }
            }
            .frame(height: 90)

            HStack {
                Text(data.periodStart.formatted(.dateTime.day().month(.abbreviated)))
                Spacer()
                Text(data.generatedAt.formatted(.dateTime.day().month(.abbreviated)))
            }
            .font(.system(size: 9))
            .foregroundStyle(Color.gray)

            Text(String(localized: "Outline: doses scheduled · Solid fill: doses taken · Dash: nothing scheduled"))
                .font(.system(size: 9))
                .foregroundStyle(Color.gray)
        }
    }

    private var cornerRadius: CGFloat { data.periodDays > 7 ? 2 : 4 }

    /// Tallest scheduled day in the period, so outline heights are relative.
    private var maxDailyTotal: Int {
        max(1, data.buckets.map(\.total).max() ?? 1)
    }

    private func outlineHeight(for bucket: AdherenceCalculator.DayBucket) -> CGFloat {
        max(10, 90 * CGFloat(bucket.total) / CGFloat(maxDailyTotal))
    }

    private func barColor(for bucket: AdherenceCalculator.DayBucket) -> Color {
        if bucket.taken == bucket.total { return Color(red: 0.2, green: 0.75, blue: 0.45) }
        return bucket.taken > 0
            ? Color(red: 0.95, green: 0.62, blue: 0.15)
            : Color(red: 0.9, green: 0.3, blue: 0.25)
    }

    private var medicationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Per medication"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.black)

            ForEach(medications) { medication in
                MedicationReportRow(
                    medication: medication,
                    showsDivider: medication.id != medications.last?.id || continues
                )
            }

            if continues {
                Text(String(localized: "Continued on the next page"))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.gray)
            }
        }
    }
}

// MARK: - A single medication row

private struct MedicationReportRow: View {
    let medication: DoctorReport.ReportData.MedicationRow
    let showsDivider: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(medication.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.black)
                if !medication.detail.isEmpty {
                    Text(medication.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.gray)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(String(localized: "\(medication.summary.taken) of \(medication.summary.total) taken"))
                .font(.system(size: 11))
                .foregroundStyle(Color.gray)
            Text(medication.summary.percent.map { "\($0)%" } ?? "—")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 7)

        if showsDivider {
            Divider().opacity(0.4)
        }
    }

    private var tint: Color {
        guard let percent = medication.summary.percent else { return Color.gray }
        switch percent {
        case 90...: return Color(red: 0.2, green: 0.75, blue: 0.45)
        case 70..<90: return Color(red: 0.95, green: 0.62, blue: 0.15)
        default: return Color(red: 0.9, green: 0.3, blue: 0.25)
        }
    }
}

// MARK: - Continuation pages: medications

private struct MedicationPage: View {
    let medications: [DoctorReport.ReportData.MedicationRow]
    let page: Int
    let totalPages: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(String(localized: "Per medication (continued)"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.black)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(medications) { medication in
                    MedicationReportRow(
                        medication: medication,
                        showsDivider: medication.id != medications.last?.id
                    )
                }
            }

            Spacer(minLength: 0)
            ReportFooter(page: page, totalPages: totalPages)
        }
        .padding(44)
        .frame(width: DoctorReport.pageSize.width, height: DoctorReport.pageSize.height)
        .clipped()
        .background(Color.white)
    }
}

// MARK: - Timing detail pages

private struct TimingPage: View {
    let notes: [DoctorReport.ReportData.TimingNote]
    /// Only the first timing page carries the heading; continuation pages
    /// keep the space for rows.
    let showsHeading: Bool
    /// Total notable doses before capping, for "the 20 most recent of 47".
    let totalCount: Int
    let page: Int
    let totalPages: Int

    private var subtitle: String {
        if totalCount > notes.count {
            return String(localized: "Doses taken notably earlier or later than scheduled — the \(notes.count) most recent of \(totalCount).")
        }
        return String(localized: "Doses taken notably earlier or later than scheduled.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if showsHeading {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Timing detail"))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.black)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.gray)
                }
            } else {
                Text(String(localized: "Timing detail (continued)"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.black)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(notes) { note in
                    Text(note.text)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.black)
                        .lineLimit(2)
                        .padding(.vertical, 6)
                    if note.id != notes.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }

            Spacer(minLength: 0)
            ReportFooter(page: page, totalPages: totalPages)
        }
        .padding(44)
        .frame(width: DoctorReport.pageSize.width, height: DoctorReport.pageSize.height)
        .clipped()
        .background(Color.white)
    }
}

// MARK: - Footer

private struct ReportFooter: View {
    let page: Int
    let totalPages: Int

    var body: some View {
        VStack(spacing: 8) {
            Divider().opacity(0.4)
            HStack {
                // Two sentences every page must carry: where the numbers came
                // from, and what the page is not. An A4 sheet titled
                // "Medication Adherence Report" reads as a clinical instrument;
                // it is a personal record and says so.
                Text(String(localized: "Recorded by the patient in Daily Dose — a personal record, not a medical document. Times are as logged, including early and late doses."))
                    .font(.system(size: 9))
                    .foregroundStyle(Color.gray)
                Spacer()
                Text("\(page) / \(totalPages)")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.gray)
            }
        }
    }
}

// MARK: - Chunking

private extension Array {
    /// Slices of at most `size` elements. An empty array yields no pages at
    /// all — an empty timing section must not produce a blank page.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
