import Foundation
import Observation

/// Everything the Today screen needs, computed once per change.
///
/// The old view recomputed the full dose list inside six separate computed
/// properties, each of which SwiftUI re-evaluated on every render — and each of
/// which walked the whole event history. This builds the day in a single pass
/// and hands the view finished answers.
@MainActor
@Observable
final class TodayModel {

    private let store: DoseStore
    private let calendar: Calendar

    private(set) var day = DayPlan.empty
    /// Three weeks — previous, current, next — so the week strip can page
    /// sideways with native physics and never hit a hard edge. Index 1 is
    /// always the week containing `selectedDay`.
    private(set) var weekWindow: [[WeekDay]] = []
    private(set) var tomorrow: [ResolvedDose] = []
    private(set) var lowSupply: [MedicationSnapshot] = []
    private(set) var isEmpty = true

    var selectedDay: Date = .now { didSet { rebuildIfDayChanged(oldValue) } }
    var now: Date = .now

    init(store: DoseStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    var isToday: Bool { calendar.isDateInToday(selectedDay) }

    /// The user's missed-dose window, exposed so views can tag doses with the
    /// same boundary the engine uses.
    var window: DoseWindow { store.doseWindow }

    // MARK: - Rebuilding

    /// Recomputes the whole screen. Cheap enough to call on every tick because
    /// the event index is fetched for a bounded window and consulted in O(1).
    ///
    /// Follows the clock across midnight: if the user was looking at "today"
    /// and the day has since turned, the screen turns with it. A user who
    /// logged their 23:55 bedtime dose and picks the phone up at 00:10 must
    /// see *today's* doses — logging against yesterday's card would write a
    /// record for a day that no longer exists. A deliberately chosen past or
    /// future day is never yanked away.
    func rebuild(now: Date = .now) {
        if calendar.isDate(selectedDay, inSameDayAs: self.now),
           !calendar.isDate(selectedDay, inSameDayAs: now) {
            selectedDay = now
        }
        self.now = now
        let snapshots = store.snapshots()
        isEmpty = snapshots.isEmpty

        // One fetch covers the selected day, the three paged weeks and
        // tomorrow — the pager renders the neighbours before a swipe starts,
        // so their data must already be here.
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: selectedDay)?.start ?? selectedDay
        let pagerStart = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
        let lowerBound = min(calendar.startOfDay(for: selectedDay), pagerStart)
        let upperBound = calendar.date(
            byAdding: .day, value: 2,
            to: max(calendar.startOfDay(for: selectedDay),
                    calendar.date(byAdding: .day, value: 21, to: pagerStart) ?? pagerStart)
        ) ?? selectedDay
        let events = store.loggedEvents(from: lowerBound, to: upperBound)

        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })

        func resolve(_ doses: [Dose]) -> [ResolvedDose] {
            doses.compactMap { dose in
                byID[dose.medicationID].map { ResolvedDose(dose: dose, medication: $0) }
            }
        }

        let window = store.doseWindow
        let todaysDoses = resolve(
            DoseCalculator.doses(on: selectedDay, medications: snapshots,
                                 events: events, now: now, window: window, calendar: calendar)
        )
        day = DayPlan(doses: todaysDoses)

        // Previous, current and next week. A side page marks the day that
        // *would* be selected if the swipe landed there — the same weekday —
        // so the selection ring travels with the gesture instead of popping
        // in afterwards. Landing on a side page shifts `selectedDay` by a
        // week, which rebuilds this window and recentres the pager.
        weekWindow = (-1...1).map { page in
            guard let base = calendar.date(byAdding: .day, value: 7 * page, to: weekStart),
                  let selectedInPage = calendar.date(byAdding: .day, value: 7 * page, to: selectedDay)
            else { return [] }
            return (0..<7).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: base) else { return nil }
                return WeekDay(
                    date: date,
                    progress: DoseCalculator.progress(on: date, medications: snapshots,
                                                      events: events, now: now,
                                                      window: window, calendar: calendar),
                    isToday: calendar.isDateInToday(date),
                    isSelected: calendar.isDate(date, inSameDayAs: selectedInPage),
                    isFuture: calendar.startOfDay(for: date) > calendar.startOfDay(for: now)
                )
            }
        }

        if let tomorrowDate = calendar.date(byAdding: .day, value: 1, to: now), isToday {
            tomorrow = resolve(
                DoseCalculator.doses(on: tomorrowDate, medications: snapshots,
                                     events: events, now: now, window: window, calendar: calendar)
            )
        } else {
            tomorrow = []
        }

        lowSupply = snapshots.filter { $0.isActive && $0.isLowOnSupply }
    }

    private func rebuildIfDayChanged(_ oldValue: Date) {
        guard !calendar.isDate(oldValue, inSameDayAs: selectedDay) else { return }
        // Rebuild against the model's own clock, not a fresh `now`: a didSet
        // fired by the midnight rollover would otherwise re-enter rebuild with
        // a different timebase and re-advance the day it just advanced.
        rebuild(now: now)
    }

    // MARK: - Actions

    func log(_ dose: ResolvedDose, as status: DoseStatus, at loggedAt: Date? = nil) {
        store.log(medicationID: dose.medication.id, scheduledAt: dose.scheduledAt,
                  status: status, loggedAt: loggedAt ?? .now)
        // Fresh clock, not self.now — a stale `now` once meant midnight never
        // turned the page after a late-evening log.
        rebuild()
    }

    func undo(_ dose: ResolvedDose) {
        store.undoLog(medicationID: dose.medication.id, scheduledAt: dose.scheduledAt)
        rebuild()
    }

    func goToToday() {
        selectedDay = .now
        rebuild()
    }

    // MARK: - Copy

    var greeting: String {
        switch calendar.component(.hour, from: now) {
        case 5..<12: String(localized: "Good morning")
        case 12..<17: String(localized: "Good afternoon")
        case 17..<22: String(localized: "Good evening")
        default: String(localized: "Good night")
        }
    }

    /// "12 August · 2 left" — the date plus the only number that matters.
    var subtitle: String {
        let date = selectedDay.formatted(.dateTime.month(.wide).day())
        guard isToday, !day.doses.isEmpty else { return date }
        let remaining = day.pending.count
        return remaining == 0
            ? "\(date) · \(String(localized: "all done"))"
            : "\(date) · \(String(localized: "\(remaining) left"))"
    }
}

// MARK: - Value types

/// A dose paired with the medication it belongs to, so views never look one up.
struct ResolvedDose: Identifiable, Equatable {
    let dose: Dose
    let medication: MedicationSnapshot

    var id: String { dose.id }
    var scheduledAt: Date { dose.scheduledAt }
    var state: DoseState { dose.state }
    var color: MedicationColor { MedicationColor.named(medication.colorName) }

    /// Only a dose that can still be acted on *today* gets the loud buttons.
    /// Yesterday's overdue dose is history, not a call to action.
    func needsAction(calendar: Calendar = .current) -> Bool {
        switch state {
        case .due: true
        case .overdue: calendar.isDateInToday(scheduledAt)
        default: false
        }
    }

    /// The screen's single definition of "missed": logged as missed, or
    /// overdue with a window that has already closed. A dose that can still
    /// be taken is late, never missed — the day those two words blur is the
    /// day the record stops being honest. Three call sites used to each
    /// invent their own version of this; they now share this one.
    var isMissed: Bool {
        state == .logged(.missed) || (state == .overdue && !needsAction())
    }
}

struct DayPlan: Equatable {
    var doses: [ResolvedDose]

    static let empty = DayPlan(doses: [])

    var pending: [ResolvedDose] {
        doses.filter { !$0.state.isLogged }
    }

    var logged: [ResolvedDose] {
        doses.filter(\.state.isLogged)
    }

    /// Actionable first, then chronological — so the thing to do now is at the
    /// top, even if it's overdue and its time has passed.
    var sortedPending: [ResolvedDose] {
        pending.sorted { lhs, rhs in
            if lhs.state.isActionable != rhs.state.isActionable {
                return lhs.state.isActionable
            }
            return lhs.scheduledAt < rhs.scheduledAt
        }
    }

    var takenCount: Int {
        doses.filter { $0.state == .logged(.taken) }.count
    }

    var isComplete: Bool { !doses.isEmpty && pending.isEmpty }

    /// One card per medication, in first-appearance order, each holding the
    /// whole day chronologically. The list speaks in medications; each card's
    /// timeline tells the day's truth per dose.
    var cards: [MedicationDayCard] {
        var order: [String] = []
        var byMedication: [String: [ResolvedDose]] = [:]
        for dose in doses {
            if byMedication[dose.medication.id] == nil {
                order.append(dose.medication.id)
                byMedication[dose.medication.id] = []
            }
            byMedication[dose.medication.id]?.append(dose)
        }
        return order.compactMap { id in
            guard let list = byMedication[id], let medication = list.first?.medication else { return nil }
            return MedicationDayCard(
                medication: medication,
                doses: list.sorted { $0.scheduledAt < $1.scheduledAt }
            )
        }
    }
}

/// One medication, one card: the whole day as a timeline.
///
/// A 4×-daily medicine used to be four cards — or worse, a stack whose
/// collapsed face could say "Taken" over a dose that was never taken. Now the
/// medication appears exactly once, and a chip per scheduled time carries the
/// truth: taken, skipped, missed, due, or still to come.
struct MedicationDayCard: Identifiable, Equatable {
    let medication: MedicationSnapshot
    /// The day's doses, earliest first.
    let doses: [ResolvedDose]

    var id: String { medication.id }

    /// The first dose that can still be acted on, if any.
    var actionable: ResolvedDose? { doses.first { $0.needsAction() } }

    /// Logged-missed, plus doses whose window closed unlogged on a day that
    /// is no longer today — both are missed, and pretending otherwise is the
    /// one lie this screen must never tell.
    func isMissed(_ dose: ResolvedDose) -> Bool {
        dose.isMissed
    }

    /// Which section of the day this card belongs to. A card lives in exactly
    /// one section, chosen by what deserves attention most: something to do
    /// now outranks something later, which outranks something that went
    /// wrong, which outranks a settled record.
    var tier: Int {
        if actionable != nil { return 0 }
        if doses.contains(where: { $0.state == .upcoming }) { return 1 }
        if doses.contains(where: isMissed) { return 2 }
        return 3
    }

    /// Ordering inside a section: the earliest moment that earned the tier.
    var sortDate: Date {
        switch tier {
        case 0: actionable?.scheduledAt ?? .distantPast
        case 1: doses.first { $0.state == .upcoming }?.scheduledAt ?? .distantPast
        case 2: doses.first(where: isMissed)?.scheduledAt ?? .distantPast
        default: doses.first?.scheduledAt ?? .distantPast
        }
    }
}

struct WeekDay: Identifiable, Equatable {
    let date: Date
    let progress: DayProgress
    let isToday: Bool
    let isSelected: Bool
    /// A day that hasn't happened yet. The strip dims it: an empty ring and
    /// "0 of 3 taken" would read as a fully-missed day, and a future day can
    /// never be missed.
    let isFuture: Bool

    var id: Date { date }
}
