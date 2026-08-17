import Foundation
import Testing
@testable import DailyDose

/// One medication, one card — the grouping and section-honesty rules behind
/// the Doses tab's timeline cards.
@Suite("Medication day cards")
struct DayPlanCardsTests {

    private let calendar = Fixture.calendar()

    private func medication(_ id: String, name: String) -> MedicationSnapshot {
        Fixture.medication(
            id: id, name: name,
            schedule: Fixture.schedule(start: Fixture.date(2026, 1, 1))
        )
    }

    private func dose(_ medication: MedicationSnapshot, hour: Int, state: DoseState) -> ResolvedDose {
        // Same-day fixtures keep `needsAction` (calendar "today") stable.
        let day = calendar.startOfDay(for: .now)
        let at = calendar.date(byAdding: .hour, value: hour, to: day)!
        return ResolvedDose(
            dose: Dose(medicationID: medication.id, scheduledAt: at, state: state),
            medication: medication
        )
    }

    @Test("Doses group into one card per medication, chronological")
    func grouping() {
        let metformin = medication("a", name: "Metformin")
        let dolorinin = medication("b", name: "Dolorinin")
        let plan = DayPlan(doses: [
            dose(metformin, hour: 22, state: .upcoming),
            dose(dolorinin, hour: 9, state: .logged(.taken)),
            dose(metformin, hour: 8, state: .logged(.taken)),
            dose(metformin, hour: 13, state: .logged(.missed)),
        ])

        #expect(plan.cards.map(\.medication.name) == ["Metformin", "Dolorinin"])

        let card = plan.cards[0]
        #expect(card.doses.map { calendar.component(.hour, from: $0.scheduledAt) } == [8, 13, 22])
    }

    @Test("A missed dose keeps the card out of Done even when others are taken")
    func missedOutranksSettled() {
        let med = medication("a", name: "Metformin")
        let plan = DayPlan(doses: [
            dose(med, hour: 8, state: .logged(.taken)),
            dose(med, hour: 13, state: .logged(.missed)),
            dose(med, hour: 18, state: .logged(.taken)),
        ])
        #expect(plan.cards[0].tier == 2)
    }

    @Test("Actionable outranks upcoming and missed")
    func actionableOutranksAll() {
        let med = medication("a", name: "Metformin")
        let plan = DayPlan(doses: [
            dose(med, hour: 8, state: .logged(.missed)),
            dose(med, hour: 23, state: .due),
        ])
        #expect(plan.cards[0].tier == 0)
        #expect(plan.cards[0].actionable?.state == .due)
    }

    @Test("Upcoming outranks a settled day, missed sits between")
    func tierOrdering() {
        let settled = medication("a", name: "Settled")
        let coming = medication("b", name: "Coming")
        let missed = medication("c", name: "Missed")
        let plan = DayPlan(doses: [
            dose(settled, hour: 8, state: .logged(.taken)),
            dose(coming, hour: 22, state: .upcoming),
            dose(missed, hour: 9, state: .logged(.missed)),
        ])
        let tiers = Dictionary(uniqueKeysWithValues: plan.cards.map { ($0.medication.name, $0.tier) })
        #expect(tiers == ["Settled": 3, "Coming": 1, "Missed": 2])
    }

    @Test("Cards sort inside a section by the moment that earned the tier")
    func sortDate() {
        let early = medication("a", name: "Early")
        let late = medication("b", name: "Late")
        let cards = [
            DayPlan(doses: [dose(late, hour: 21, state: .due)]).cards[0],
            DayPlan(doses: [dose(early, hour: 6, state: .due)]).cards[0],
        ]
        let sorted = cards.sorted { $0.sortDate < $1.sortDate }
        #expect(sorted.map(\.medication.name) == ["Early", "Late"])
    }
}

/// H6: the screen used to hold three definitions of "missed" — the summary
/// sheet counted every overdue dose (even one you could still take), the
/// completion card counted only logged misses, and the card tier used the
/// correct union. All now share `ResolvedDose.isMissed`.
@Suite("H6: one definition of missed")
struct MissedDefinitionTests {

    private let calendar = Fixture.calendar()

    private func resolved(day: Date, hour: Int, state: DoseState) -> ResolvedDose {
        let at = calendar.date(byAdding: .hour, value: hour, to: calendar.startOfDay(for: day))!
        return ResolvedDose(
            dose: Dose(medicationID: "m", scheduledAt: at, state: state),
            medication: Fixture.medication(schedule: Fixture.schedule(start: Fixture.date(2026, 1, 1)))
        )
    }

    @Test("An overdue dose that can still be taken is late, not missed")
    func actionableOverdueIsNotMissed() {
        // Overdue but scheduled today: still actionable, so not missed.
        let dose = resolved(day: .now, hour: 8, state: .overdue)
        #expect(!dose.isMissed,
                "Counting a still-takable dose as missed is how panic starts")
    }

    @Test("Yesterday's unlogged overdue dose is missed")
    func expiredOverdueIsMissed() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: .now)!
        let dose = resolved(day: yesterday, hour: 8, state: .overdue)
        #expect(dose.isMissed)
    }

    @Test("Logged outcomes keep their own truth")
    func loggedStates() {
        #expect(resolved(day: .now, hour: 8, state: .logged(.missed)).isMissed)
        #expect(!resolved(day: .now, hour: 8, state: .logged(.taken)).isMissed)
        #expect(!resolved(day: .now, hour: 8, state: .logged(.skipped)).isMissed)
    }
}
