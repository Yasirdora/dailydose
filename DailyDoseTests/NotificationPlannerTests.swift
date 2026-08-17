import Foundation
import Testing
@testable import DailyDose

/// The regression suite for the silent notification failures: the 64-request
/// ceiling, the 20-notification cap on projected schedules, and reminders that
/// simply stopped after a few days.
@Suite("Notification planner")
struct NotificationPlannerTests {

    let calendar = Fixture.calendar()
    let now = Fixture.date(2026, 8, 12, 7)

    private func plan(
        _ medications: [MedicationSnapshot],
        budget: NotificationPlanner.Budget = .default,
        events: LoggedEventIndex = .empty
    ) -> NotificationPlanner.Plan {
        NotificationPlanner.plan(
            medications: medications, events: events, now: now,
            budget: budget, calendar: calendar
        )
    }

    private func doseNotifications(_ plan: NotificationPlanner.Plan) -> [NotificationPlanner.PlannedNotification] {
        plan.notifications.filter {
            switch $0.category {
            case .dose, .doseBundle: true
            default: false
            }
        }
    }

    // MARK: - The 7× saving

    @Test("A daily schedule costs one request per dose time, not seven")
    func dailyUsesDailyTriggers() {
        // The old planner emitted one weekly trigger per weekday per time, so a
        // 4×-daily medication consumed 28 of the 64 available slots. Three such
        // medications overflowed and iOS silently dropped the excess.
        let medication = Fixture.medication(schedule: Fixture.schedule(
            kind: .daily,
            times: [Fixture.time(8), Fixture.time(13), Fixture.time(18), Fixture.time(22)],
            start: Fixture.date(2026, 8, 1)
        ))

        let doses = doseNotifications(plan([medication]))

        #expect(doses.count == 4, "Four dose times, four requests — not 28")
        #expect(doses.allSatisfy {
            if case .daily = $0.trigger { return true }
            return false
        })
    }

    @Test("Seven chosen weekdays are treated as a daily schedule")
    func allSevenWeekdaysCollapseToDaily() {
        let medication = Fixture.medication(schedule: Fixture.schedule(
            kind: .weekdays, times: [Fixture.time(8)],
            start: Fixture.date(2026, 8, 1), weekdays: Set(1...7)
        ))
        let doses = doseNotifications(plan([medication]))

        #expect(doses.count == 1)
        #expect(doses[0].trigger == .daily(Fixture.time(8)))
    }

    @Test("A subset of weekdays uses one weekly trigger per day")
    func weekdaySubsetUsesWeeklyTriggers() {
        let medication = Fixture.medication(schedule: Fixture.schedule(
            kind: .weekdays, times: [Fixture.time(8)],
            start: Fixture.date(2026, 8, 1), weekdays: [2, 4, 6]
        ))
        let doses = doseNotifications(plan([medication]))

        #expect(doses.count == 3)
        #expect(doses.allSatisfy {
            if case .weekly = $0.trigger { return true }
            return false
        })
    }

    // MARK: - Budget

    @Test("The plan never exceeds the system limit")
    func planStaysWithinSystemLimit() {
        // Ten medications, four doses a day each — comfortably past 64 under
        // the old scheme.
        let medications = (0..<10).map { i in
            Fixture.medication(
                id: "med-\(i)", name: "Med \(i)",
                schedule: Fixture.schedule(
                    kind: .daily,
                    times: [Fixture.time(8), Fixture.time(12), Fixture.time(16), Fixture.time(20)],
                    start: Fixture.date(2026, 8, 1)
                )
            )
        }

        let result = plan(medications)
        #expect(result.notifications.count <= NotificationPlanner.systemLimit)
    }

    @Test("Dose reminders stay inside their own allowance")
    func dosesRespectTheirBudget() {
        let medications = (0..<30).map { i in
            Fixture.medication(
                id: "med-\(i)", name: "Med \(i)",
                schedule: Fixture.schedule(
                    kind: .daily, times: [Fixture.time(8), Fixture.time(20)],
                    start: Fixture.date(2026, 8, 1)
                )
            )
        }
        let budget = NotificationPlanner.Budget(doses: 20, followUps: 4, refills: 2)
        let result = plan(medications, budget: budget)

        #expect(doseNotifications(result).count <= budget.doses)
    }

    @Test("Medications that don't fit are reported, not silently dropped")
    func overflowIsReported() {
        // Distinct times on purpose: medications sharing an instant now collapse
        // into one bundled alert, so they would no longer overflow at all —
        // which is the point of bundling, but not what this test is checking.
        let medications = (0..<12).map { i in
            Fixture.medication(
                id: "med-\(i)", name: "Med \(i)",
                schedule: Fixture.schedule(
                    kind: .everyXDays, times: [Fixture.time(6 + i)],
                    start: Fixture.date(2026, 8, 1), intervalDays: 2
                )
            )
        }
        let result = plan(medications, budget: NotificationPlanner.Budget(doses: 4, followUps: 0, refills: 0))

        #expect(!result.deferredMedicationIDs.isEmpty,
                "An unschedulable medication must be visible to the user")
    }

    @Test("Cheap schedules are never crowded out by expensive ones")
    func cheapSchedulesWinFirst() {
        let expensive = Fixture.medication(
            id: "expensive",
            schedule: Fixture.schedule(
                kind: .weekdays,
                times: [Fixture.time(8), Fixture.time(12), Fixture.time(16), Fixture.time(20)],
                start: Fixture.date(2026, 8, 1), weekdays: [1, 3, 5, 7]
            )
        )
        let cheap = Fixture.medication(
            id: "cheap",
            schedule: Fixture.schedule(kind: .daily, times: [Fixture.time(9)], start: Fixture.date(2026, 8, 1))
        )

        let result = plan([expensive, cheap], budget: NotificationPlanner.Budget(doses: 8, followUps: 0, refills: 0))
        let scheduledIDs = Set(doseNotifications(result).compactMap { notification -> String? in
            guard case .dose(let id, _) = notification.category else { return nil }
            return id
        })

        #expect(scheduledIDs.contains("cheap"),
                "A one-a-day medication must not lose its slot to a 16-request schedule")
    }

    // MARK: - Finite courses

    @Test("A course with an end date never uses a repeating trigger")
    func finiteCoursesUseOneShots() {
        // A repeating weekly trigger cannot express "stop on the 19th", so the
        // reminder would keep firing long after the prescription ended.
        let medication = Fixture.medication(schedule: Fixture.schedule(
            kind: .daily, times: [Fixture.time(8)],
            start: Fixture.date(2026, 8, 12), end: Fixture.date(2026, 8, 19)
        ))
        let doses = doseNotifications(plan([medication]))

        #expect(!doses.isEmpty)
        #expect(doses.allSatisfy {
            if case .once = $0.trigger { return true }
            return false
        })
        #expect(doses.allSatisfy { ($0.nextFireDate ?? .distantFuture) <= Fixture.date(2026, 8, 19, 23, 59) },
                "Nothing may be scheduled past the final day of the course")
    }

    @Test("A short course is covered end to end")
    func shortCourseIsFullyCovered() {
        // The old planner capped projections at 20 requests in iteration order,
        // so a 4×-daily course ran out of reminders after five days.
        let medication = Fixture.medication(schedule: Fixture.schedule(
            kind: .daily,
            times: [Fixture.time(8), Fixture.time(12), Fixture.time(16), Fixture.time(20)],
            start: Fixture.date(2026, 8, 12), end: Fixture.date(2026, 8, 18)
        ))
        let doses = doseNotifications(plan([medication]))
        let lastDay = doses.compactMap(\.nextFireDate).max()

        #expect(lastDay != nil)
        #expect(calendar.isDate(lastDay!, inSameDayAs: Fixture.date(2026, 8, 18)),
                "A seven-day course must be reminded on all seven days")
    }

    @Test("Interval and monthly schedules are projected, nearest first")
    func projectedSchedulesAreOrdered() {
        let medication = Fixture.medication(schedule: Fixture.schedule(
            kind: .everyXDays, times: [Fixture.time(8)],
            start: Fixture.date(2026, 8, 12), intervalDays: 21
        ))
        let dates = doseNotifications(plan([medication])).compactMap(\.nextFireDate)

        #expect(!dates.isEmpty)
        #expect(dates == dates.sorted())
        #expect(dates.allSatisfy { $0 > now })
    }

    // MARK: - Follow-ups

    @Test("A follow-up lands 30 minutes after an unlogged dose")
    func followUpTiming() {
        let medication = Fixture.medication(schedule: Fixture.schedule(
            kind: .daily, times: [Fixture.time(8)], start: Fixture.date(2026, 8, 1)
        ))
        let followUps = plan([medication]).notifications.filter {
            if case .followUp = $0.category { return true }
            return false
        }

        #expect(!followUps.isEmpty)
        #expect(followUps.first?.nextFireDate == Fixture.date(2026, 8, 12, 8, 30))
    }

    @Test("No follow-up is planned for a dose already logged")
    func noFollowUpForLoggedDose() {
        let medication = Fixture.medication(schedule: Fixture.schedule(
            kind: .daily, times: [Fixture.time(8)], start: Fixture.date(2026, 8, 1)
        ))
        let events = LoggedEventIndex([
            (medicationID: "med-1", scheduledAt: Fixture.date(2026, 8, 12, 8), status: .taken)
        ])
        let followUps = plan([medication], events: events).notifications.filter {
            if case .followUp(_, let at) = $0.category { return at == Fixture.date(2026, 8, 12, 8) }
            return false
        }
        #expect(followUps.isEmpty)
    }

    // MARK: - Refills

    @Test("Refill alerts go to the lowest supply first")
    func refillsPrioritiseLowestSupply() {
        let medications = [
            Fixture.medication(id: "plenty", schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1)), pills: 9, threshold: 10),
            Fixture.medication(id: "empty", schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1)), pills: 0, threshold: 10),
            Fixture.medication(id: "low", schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1)), pills: 3, threshold: 10),
        ]
        let refills = plan(medications, budget: NotificationPlanner.Budget(doses: 20, followUps: 0, refills: 2))
            .notifications
            .compactMap { notification -> String? in
                guard case .refill(let id) = notification.category else { return nil }
                return id
            }

        #expect(refills == ["empty", "low"])
    }

    @Test("Refill alerts run out of budget without starving dose reminders")
    func refillsDoNotStealDoseSlots() {
        // Six medications on six different times, so each keeps its own alert —
        // this test is about budget separation, not bundling.
        let medications = (0..<6).map { i in
            Fixture.medication(
                id: "med-\(i)",
                schedule: Fixture.schedule(kind: .daily, times: [Fixture.time(8 + i)], start: Fixture.date(2026, 8, 1)),
                pills: 1, threshold: 10
            )
        }
        let result = plan(medications, budget: NotificationPlanner.Budget(doses: 6, followUps: 0, refills: 2))

        #expect(doseNotifications(result).count == 6, "Every medication keeps its dose reminder")
        #expect(result.notifications.filter {
            if case .refill = $0.category { return true }
            return false
        }.count == 2)
    }

    // MARK: - General invariants

    @Test("Identifiers are unique and ASCII")
    func identifiersAreUniqueAndSafe() {
        let medications = (0..<5).map { i in
            Fixture.medication(
                id: "med-\(i)",
                schedule: Fixture.schedule(
                    kind: .daily, times: [Fixture.time(8), Fixture.time(20)],
                    start: Fixture.date(2026, 8, 1)
                ),
                pills: 2, threshold: 5
            )
        }
        let result = plan(medications)
        let ids = result.notifications.map(\.id)

        #expect(Set(ids).count == ids.count, "A duplicate id silently replaces another reminder")
        #expect(ids.allSatisfy { $0.allSatisfy(\.isASCII) })
    }

    @Test("Planning is deterministic")
    func planningIsDeterministic() {
        let medications = (0..<8).map { i in
            Fixture.medication(
                id: "med-\(i)",
                schedule: Fixture.schedule(
                    kind: i.isMultiple(of: 2) ? .daily : .everyXDays,
                    times: [Fixture.time(8)],
                    start: Fixture.date(2026, 8, 1), intervalDays: 3
                )
            )
        }
        #expect(plan(medications).notifications.map(\.id) == plan(medications).notifications.map(\.id))
    }

    @Test("Medications with no times are never scheduled")
    func unscheduledMedicationsAreIgnored() {
        let medication = Fixture.medication(schedule: Fixture.schedule(
            times: [], start: Fixture.date(2026, 8, 1)
        ))
        #expect(plan([medication]).notifications.isEmpty)
    }

    @Test("Paused medications are never scheduled")
    func pausedMedicationsAreIgnored() {
        let medication = Fixture.medication(
            schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1)),
            isActive: false, pills: 1, threshold: 5
        )
        #expect(plan([medication]).notifications.isEmpty)
    }
}
