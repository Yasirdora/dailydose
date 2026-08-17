import Foundation
import Testing
@testable import DailyDose

@Suite("Adherence summary")
struct AdherenceSummaryTests {

    let calendar = Fixture.calendar()
    let now = Fixture.date(2026, 8, 12, 18)

    private func summary(taken: Int, skipped: Int = 0, missed: Int = 0) -> AdherenceCalculator.Summary {
        var s = AdherenceCalculator.Summary()
        s.taken = taken; s.skipped = skipped; s.missed = missed
        return s
    }

    private func text(
        overall: AdherenceCalculator.Summary,
        lines: [AdherenceSummary.Line] = [],
        days: Int = 30
    ) -> String {
        AdherenceSummary.text(
            overall: overall, byMedication: lines, days: days,
            now: now, calendar: calendar, locale: Locale(identifier: "en_US_POSIX")
        )
    }

    @Test("The headline percentage matches the summary it was given")
    func percentageMatchesInput() {
        // The guarantee that matters: what someone shares can never disagree
        // with the screen they shared it from, because both read the same
        // AdherenceCalculator result.
        let output = text(overall: summary(taken: 52, skipped: 4, missed: 4))
        #expect(output.contains("87%"), "52 of 60 rounds to 87")
        #expect(output.contains("52 taken"))
        #expect(output.contains("4 skipped"))
        #expect(output.contains("4 missed"))
    }

    @Test("An empty period says so instead of claiming zero percent")
    func emptyPeriodIsHonest() {
        let output = text(overall: AdherenceCalculator.Summary())
        #expect(output.contains("No doses recorded"))
        #expect(!output.contains("0%"), "Nothing logged is not the same as nothing taken")
    }

    @Test("Per-medication lines are included with their own figures")
    func perMedicationLines() {
        let output = text(
            overall: summary(taken: 30, missed: 10),
            lines: [
                .init(name: "Metformin", summary: summary(taken: 20, missed: 5)),
                .init(name: "Lisinopril", summary: summary(taken: 10, missed: 5)),
            ]
        )
        #expect(output.contains("Metformin"))
        #expect(output.contains("Lisinopril"))
        #expect(output.contains("20/25"))
        #expect(output.contains("10/15"))
    }

    @Test("A very long medication name is truncated, not left to wrap")
    func longNamesAreTruncated() {
        let long = "Amoxicillin Clavulanate Potassium Extended Release"
        let output = text(
            overall: summary(taken: 1),
            lines: [.init(name: long, summary: summary(taken: 1))]
        )
        #expect(!output.contains(long), "The full name would break the column alignment")
        #expect(output.contains("…"))
    }

    @Test("The date range covers the requested number of days, inclusive")
    func dateRangeIsInclusive() {
        // 30 days ending today means the 14th of July through the 12th of
        // August — an off-by-one here would misrepresent the period on a
        // document someone might show a doctor.
        let output = text(overall: summary(taken: 1), days: 30)
        #expect(output.contains("30 days"))
        #expect(output.contains("Jul 14"))
        #expect(output.contains("Aug 12"))
    }

    @Test("It states plainly that it is not a medical document")
    func carriesTheDisclaimer() {
        let output = text(overall: summary(taken: 1))
        #expect(output.contains("not a medical document"))
    }

    @Test("Filenames sort chronologically and are identical on every device")
    func filenameIsStable() {
        let name = AdherenceSummary.fileName(days: 30, now: now)
        #expect(name == "daily-dose-adherence-30d-2026-08-12.txt")
        // `canBeConverted` rather than `allSatisfy(\.isASCII)`: a rethrows
        // call inside #expect's macro expansion trips "call can throw".
        #expect(name.canBeConverted(to: .ascii))
        #expect(!name.contains(" "))
    }

    @Test("A medication with nothing logged shows a dash, not zero percent")
    func unloggedMedicationShowsDash() {
        let output = text(
            overall: summary(taken: 5),
            lines: [.init(name: "Vitamin D3", summary: AdherenceCalculator.Summary())]
        )
        #expect(output.contains("—"))
    }
}
