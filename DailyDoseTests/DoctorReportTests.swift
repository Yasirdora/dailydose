import Foundation
import SwiftData
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

/// H9: adherence is counted from recorded events, so an unlogged dose only
/// enters the denominator once the sweep has written `.missed` for it. A
/// 7-day sweep made a 30-day report silently inflate: three weeks of
/// unlogged doses simply never existed as far as the numbers were concerned.
@Suite("H9: the missed sweep covers the longest report")
struct MissedSweepTests {

    @Test("Unlogged doses from three weeks ago still count as missed")
    @MainActor
    func sweepCoversTheWholeMonth() async throws {
        let container = try ModelContainer(
            for: Schema([Medication.self, DoseEvent.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let store = DoseStore(context: container.mainContext, notifications: NullScheduler())
        let calendar = Fixture.calendar()
        let now = Fixture.date(2026, 8, 26, 12)

        let schedule = Fixture.schedule(
            kind: .daily, times: [Fixture.time(8)], start: Fixture.date(2026, 8, 1)
        )
        _ = store.add(name: "Metformin", doseDetail: "500 mg", notes: "",
                      colorName: "teal", schedule: schedule,
                      pillsRemaining: nil, refillThreshold: nil)

        store.recordMissedDoses(now: now)

        let since = calendar.date(byAdding: .day, value: -30, to: now)!
        let missed = store.adherenceRecords(since: since).filter { $0.status == .missed }

        #expect(missed.count == 26, "1 August through 26 August, one dose a day")
        #expect(missed.contains { $0.scheduledAt == Fixture.date(2026, 8, 10, 8, 0) },
                "A 7-day sweep would never record this dose; the month report must")

        // add() spawned an unstructured reschedule Task; awaiting here lets it
        // run while the container is alive. If it fires after the container is
        // gone, SwiftData traps — that was the test bug, not the app's.
        await store.rescheduleNotifications()
        _ = container
    }
}
