import Foundation
import Testing
@testable import DailyDose

/// H1: the doctor report paginates instead of silently clipping.
///
/// The overview page's fixed chrome (header, ring, chart, footer) leaves room
/// for only a handful of medication rows; before pagination, a patient with
/// more medications simply lost the rest from the PDF — the report a doctor
/// received never mentioned them. Page counts and numbers are now derived,
/// never hardcoded.
@Suite("H1: doctor report pagination")
struct DoctorReportPaginationTests {

    private func row(_ id: String) -> DoctorReport.ReportData.MedicationRow {
        DoctorReport.ReportData.MedicationRow(
            id: id, name: "Med \(id)", detail: "", summary: AdherenceCalculator.Summary()
        )
    }

    private func data(medications: Int, timingNotes: Int) -> DoctorReport.ReportData {
        DoctorReport.ReportData(
            periodDays: 30,
            periodStart: Fixture.date(2026, 7, 18),
            generatedAt: Fixture.date(2026, 8, 17),
            overall: AdherenceCalculator.Summary(),
            buckets: [],
            medications: (0..<medications).map { row("med-\($0)") },
            timingNotes: (0..<timingNotes).map {
                DoctorReport.ReportData.TimingNote(id: "note-\($0)", text: "Note \($0)")
            },
            timingNoteCount: timingNotes
        )
    }

    @Test("Every medication lands on a page, however many there are")
    func everyMedicationIsPlaced() {
        let layout = DoctorReport.PageLayout(data: data(medications: 31, timingNotes: 0))
        let placed = layout.overviewMedications.count
            + layout.medicationPages.reduce(0) { $0 + $1.count }
        #expect(placed == 31, "No row may fall off the report")
        #expect(layout.overviewMedications.count == DoctorReport.PageLayout.overviewRowBudget)
        #expect(layout.medicationPages.allSatisfy { $0.count <= DoctorReport.PageLayout.continuationRowBudget })
    }

    @Test("Few medications fit on the overview alone")
    func fewMedicationsNeedNoContinuation() {
        let layout = DoctorReport.PageLayout(data: data(medications: 3, timingNotes: 0))
        #expect(layout.medicationPages.isEmpty)
        #expect(layout.totalPages == 1)
    }

    @Test("The page total counts every continuation page")
    func pageTotalIsDerived() {
        // 5 on the overview + 26 continuation rows -> 2 medication pages.
        // 30 timing notes -> 3 timing pages. Total: 1 + 2 + 3 = 6.
        let layout = DoctorReport.PageLayout(data: data(medications: 31, timingNotes: 30))
        #expect(layout.medicationPages.count == 2)
        #expect(layout.timingPages.count == 3)
        #expect(layout.totalPages == 6)
    }

    @Test("No timing notes means no empty timing page")
    func noNotesNoPage() {
        let layout = DoctorReport.PageLayout(data: data(medications: 2, timingNotes: 0))
        #expect(layout.timingPages.isEmpty)
        #expect(layout.totalPages == 1)
    }

    @Test("The file name carries the period")
    func fileNameCarriesPeriod() {
        let day = Fixture.date(2026, 8, 17)
        let week = DoctorReport.fileName(periodDays: 7, generatedAt: day)
        let month = DoctorReport.fileName(periodDays: 30, generatedAt: day)
        #expect(week.hasPrefix("Medication-Report-7d-"))
        #expect(month.hasPrefix("Medication-Report-30d-"))
        #expect(week != month,
                "Two reports of different periods must never overwrite each other")
        #expect(month.hasSuffix(".pdf"))
    }
}
