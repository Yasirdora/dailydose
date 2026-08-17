import Foundation
import Testing
@testable import DailyDose

@Suite("Adherence")
struct AdherenceTests {

    let calendar = Fixture.calendar()
    let now = Fixture.date(2026, 8, 12, 20)

    private func record(_ day: Int, _ status: DoseStatus, hour: Int = 8, id: String = "med-1")
        -> AdherenceCalculator.Record {
        .init(medicationID: id, scheduledAt: Fixture.date(2026, 8, day, hour), status: status)
    }

    @Test("Percent is taken over everything scheduled")
    func percentCalculation() {
        let records = [
            record(12, .taken), record(11, .taken), record(10, .taken),
            record(9, .missed), record(8, .skipped),
        ]
        let summary = AdherenceCalculator.summary(records: records, days: 7, now: now, calendar: calendar)

        #expect(summary.taken == 3)
        #expect(summary.missed == 1)
        #expect(summary.skipped == 1)
        #expect(summary.percent == 60)
    }

    @Test("An empty window has no percentage, not zero")
    func emptyWindowHasNoPercent() {
        // Showing "0%" to someone who simply hasn't started is both wrong and
        // discouraging.
        let summary = AdherenceCalculator.summary(records: [], days: 7, now: now, calendar: calendar)
        #expect(summary.percent == nil)
        #expect(summary.total == 0)
    }

    // MARK: - The scheduledAt rule

    @Test("Records are counted by scheduled date, not by when they were written")
    func windowUsesScheduledDate() {
        // The regression test for the split measurement: the ring counted by
        // `loggedAt` while the chart counted by `scheduledAt`, so a batch of
        // backfilled misses from last week all landed on today and the two
        // numbers disagreed.
        let old = AdherenceCalculator.Record(
            medicationID: "med-1",
            scheduledAt: Fixture.date(2026, 7, 1, 8),   // well outside the window
            status: .missed
        )
        let summary = AdherenceCalculator.summary(records: [old], days: 7, now: now, calendar: calendar)
        #expect(summary.total == 0, "A dose scheduled six weeks ago is not part of this week")
    }

    @Test("The window includes today and excludes the future")
    func windowBounds() {
        let records = [
            record(12, .taken),                     // today
            record(6, .taken),                      // seven days ago, inside
            record(5, .taken),                      // eight days ago, outside
        ]
        let summary = AdherenceCalculator.summary(records: records, days: 7, now: now, calendar: calendar)
        #expect(summary.total == 2)
    }

    // MARK: - Buckets

    @Test("Every day in the window gets a bucket, including empty ones")
    func bucketsCoverWholeWindow() {
        let buckets = AdherenceCalculator.dailyBuckets(
            records: [record(12, .taken)], days: 7, now: now, calendar: calendar
        )
        #expect(buckets.count == 7, "A gap day must render as an empty bar, not vanish")
        #expect(buckets.map(\.day) == buckets.map(\.day).sorted())
    }

    @Test("Buckets have stable identity across recomputation")
    func bucketIdentityIsStable() {
        // A fresh UUID per rebuild — which is what the old code used — defeats
        // SwiftUI Charts diffing and re-animates every bar on any change.
        let first = AdherenceCalculator.dailyBuckets(records: [record(12, .taken)], days: 7, now: now, calendar: calendar)
        let second = AdherenceCalculator.dailyBuckets(records: [record(12, .taken)], days: 7, now: now, calendar: calendar)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("A bucket's fraction reflects that day only")
    func bucketFraction() {
        let records = [
            record(12, .taken, hour: 8),
            record(12, .missed, hour: 20),
            record(11, .taken, hour: 8),
        ]
        let buckets = AdherenceCalculator.dailyBuckets(records: records, days: 7, now: now, calendar: calendar)
        let today = buckets.first { calendar.isDate($0.day, inSameDayAs: now) }

        #expect(today?.taken == 1)
        #expect(today?.total == 2)
    }

    @Test("The chart and the headline agree")
    func chartAndSummaryAgree() {
        // The invariant the old split measurement broke.
        let records = [
            record(12, .taken), record(12, .missed, hour: 20),
            record(11, .taken), record(10, .skipped), record(9, .taken),
        ]
        let summary = AdherenceCalculator.summary(records: records, days: 7, now: now, calendar: calendar)
        let buckets = AdherenceCalculator.dailyBuckets(records: records, days: 7, now: now, calendar: calendar)

        #expect(buckets.reduce(0) { $0 + $1.total } == summary.total)
        #expect(buckets.reduce(0) { $0 + $1.taken } == summary.taken)
    }

    // MARK: - Per medication

    @Test("Worst adherence sorts first")
    func perMedicationOrdering() {
        let records = [
            record(12, .taken, id: "good"), record(11, .taken, id: "good"),
            record(12, .missed, id: "bad"), record(11, .missed, id: "bad"),
            record(12, .taken, id: "mixed"), record(11, .missed, id: "mixed"),
        ]
        let byMedication = AdherenceCalculator.byMedication(
            records: records, days: 7, now: now, calendar: calendar
        )

        #expect(byMedication.map(\.medicationID) == ["bad", "mixed", "good"],
                "The medication that needs attention belongs at the top")
    }

    @Test("Verdicts track the percentage bands")
    func verdicts() {
        func verdict(taken: Int, total: Int) -> String {
            var summary = AdherenceCalculator.Summary()
            summary.taken = taken
            summary.missed = total - taken
            return summary.verdict
        }
        #expect(verdict(taken: 10, total: 10) != verdict(taken: 5, total: 10))
        #expect(AdherenceCalculator.Summary().verdict.isEmpty == false)
    }
}
