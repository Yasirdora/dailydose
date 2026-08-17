import SwiftUI
import UIKit

/// The doctor report: one A4 PDF that turns the log into something a
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
    }

    /// A4 at 72 dpi.
    static let pageSize = CGSize(width: 595, height: 842)

    @MainActor
    static func generate(_ data: ReportData) throws -> URL {
        var pages: [AnyView] = [AnyView(OverviewPage(data: data))]
        if !data.timingNotes.isEmpty {
            pages.append(AnyView(TimingPage(data: data)))
        }

        let pageRect = CGRect(origin: .zero, size: pageSize)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(generatedAt: data.generatedAt))

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: String(localized: "Medication Adherence Report"),
            kCGPDFContextAuthor as String: "Daily Dose",
        ]

        try UIGraphicsPDFRenderer(bounds: pageRect, format: format).writePDF(to: url) { context in
            for page in pages {
                context.beginPage()
                ImageRenderer(content: page.environment(\.colorScheme, .light)).render { _, draw in
                    draw(context.cgContext)
                }
            }
        }
        return url
    }

    static func fileName(generatedAt: Date) -> String {
        let stamp = generatedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return "Medication-Report-\(stamp).pdf"
    }
}

// MARK: - Page 1: overview

private struct OverviewPage: View {
    let data: DoctorReport.ReportData

    private var periodText: String {
        let start = data.periodStart.formatted(.dateTime.day().month(.abbreviated))
        let end = data.generatedAt.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(start) – \(end)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            overallSection
            chartSection
            medicationSection
            Spacer(minLength: 0)
            ReportFooter(page: 1, totalPages: data.timingNotes.isEmpty ? 1 : 2)
        }
        .padding(44)
        .frame(width: DoctorReport.pageSize.width, height: DoctorReport.pageSize.height)
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
        HStack(spacing: 28) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.15), lineWidth: 10)
                if let percent = data.overall.percent {
                    Circle()
                        .trim(from: 0, to: max(0.01, Double(percent) / 100))
                        .stroke(reportTint(percent: percent),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(data.overall.percent.map { "\($0)%" } ?? "—")
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
                Text(String(localized: "of \(data.overall.total) scheduled doses"))
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
            HStack(alignment: .bottom, spacing: data.periodDays > 7 ? 3 : 6) {
                ForEach(data.buckets) { bucket in
                    RoundedRectangle(cornerRadius: data.periodDays > 7 ? 2 : 4, style: .continuous)
                        .fill(barColor(for: bucket))
                        .frame(height: barHeight(for: bucket))
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
        }
    }

    private func barHeight(for bucket: AdherenceCalculator.DayBucket) -> CGFloat {
        guard bucket.total > 0 else { return 4 }
        return max(6, 90 * bucket.fraction)
    }

    private func barColor(for bucket: AdherenceCalculator.DayBucket) -> Color {
        guard bucket.total > 0 else { return Color.gray.opacity(0.18) }
        if bucket.taken == bucket.total { return Color(red: 0.2, green: 0.75, blue: 0.45) }
        return bucket.taken > 0
            ? Color(red: 0.95, green: 0.62, blue: 0.15)
            : Color(red: 0.9, green: 0.3, blue: 0.25).opacity(0.55)
    }

    private var medicationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Per medication"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.black)

            ForEach(data.medications) { medication in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(medication.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.black)
                        if !medication.detail.isEmpty {
                            Text(medication.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.gray)
                        }
                    }
                    Spacer()
                    Text(String(localized: "\(medication.summary.taken) of \(medication.summary.total) taken"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.gray)
                    Text(medication.summary.percent.map { "\($0)%" } ?? "—")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(reportTint(percent: medication.summary.percent))
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.vertical, 7)

                if medication.id != data.medications.last?.id {
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private func reportTint(percent: Int?) -> Color {
        guard let percent else { return Color.gray }
        switch percent {
        case 90...: return Color(red: 0.2, green: 0.75, blue: 0.45)
        case 70..<90: return Color(red: 0.95, green: 0.62, blue: 0.15)
        default: return Color(red: 0.9, green: 0.3, blue: 0.25)
        }
    }
}

// MARK: - Page 2: timing detail

private struct TimingPage: View {
    let data: DoctorReport.ReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Timing detail"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.black)
                Text(String(localized: "Doses taken notably earlier or later than scheduled."))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.gray)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(data.timingNotes) { note in
                    Text(note.text)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.black)
                        .padding(.vertical, 6)
                    if note.id != data.timingNotes.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }

            Spacer(minLength: 0)
            ReportFooter(page: 2, totalPages: 2)
        }
        .padding(44)
        .frame(width: DoctorReport.pageSize.width, height: DoctorReport.pageSize.height)
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
                Text(String(localized: "Recorded by the patient in Daily Dose. Times are as logged, including early and late doses."))
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
