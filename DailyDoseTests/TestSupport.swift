import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import DailyDose

/// Shared fixtures.
///
/// Every test pins its own calendar and time zone. Scheduling bugs are almost
/// always timezone bugs wearing a disguise, and a suite that silently inherits
/// the machine's locale can pass in Cupertino and fail in Berlin.
enum Fixture {

    static func calendar(
        timeZone: String = "Europe/Berlin",
        firstWeekday: Int = 2   // Monday, as in most of Europe
    ) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0,
        calendar: Calendar = Fixture.calendar()
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    static func time(_ hour: Int, _ minute: Int = 0) -> TimeOfDay {
        TimeOfDay(hour: hour, minute: minute)!
    }

    static func schedule(
        kind: ScheduleKind = .daily,
        times: Set<TimeOfDay> = [Fixture.time(8)],
        start: Date,
        weekdays: Set<Int> = Set(1...7),
        intervalDays: Int = 1,
        dayOfMonth: Int? = nil,
        intervalHours: Int = 8,
        cycleOnDays: Int = 21,
        cycleOffDays: Int = 7,
        end: Date? = nil
    ) -> DoseSchedule {
        DoseSchedule(
            kind: kind, times: times, startDate: start,
            weekdays: weekdays, intervalDays: intervalDays,
            dayOfMonth: dayOfMonth,
            intervalHours: intervalHours,
            cycleOnDays: cycleOnDays, cycleOffDays: cycleOffDays,
            endDate: end
        )
    }

    static func medication(
        id: String = "med-1",
        name: String = "Metformin",
        schedule: DoseSchedule,
        isActive: Bool = true,
        pills: Int? = nil,
        threshold: Int? = nil,
        createdAt: Date = .distantPast
    ) -> MedicationSnapshot {
        MedicationSnapshot(
            id: id, name: name, doseDetail: "500 mg", notes: "",
            colorName: MedicationColor.navy.rawValue,
            isActive: isActive, schedule: schedule,
            pillsRemaining: pills, refillThreshold: threshold,
            createdAt: createdAt
        )
    }
}

/// A notification centre that does nothing — store tests never touch the
/// system, they only need the dependency filled.
struct NullScheduler: NotificationScheduling {
    func apply(_ plan: NotificationPlanner.Plan) async -> [String] { [] }
    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization() async -> Bool { true }
}
