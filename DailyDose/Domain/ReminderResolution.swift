import Foundation

/// Which dose a delivered reminder refers to.
///
/// Repeating triggers carry only a time of day — the trigger itself has no
/// notion of *which* day it fired on. The delivery date does. Resolving
/// against the moment the banner was tapped instead corrupts the record in
/// both directions: a stale Monday banner tapped on Tuesday logs Tuesday's
/// dose (Monday's is later swept to missed), and a banner tapped seconds
/// before the scheduled instant resolves to *yesterday's* dose because the
/// occurrence upper bound is exclusive.
///
/// Pure, because the difference between "the dose the banner meant" and
/// "the dose that happened to be nearest when you tapped" is the honest
/// record this app exists to keep.
enum ReminderResolution {

    /// The most recent occurrence of `time` on or shortly before
    /// `deliveredAt`. The 90-second tolerance covers the gap between a
    /// trigger's fire instant and the system's recorded delivery date.
    static func resolve(
        schedule: DoseSchedule,
        time: TimeOfDay,
        deliveredAt: Date,
        calendar: Calendar = .current
    ) -> Date? {
        // Look back far enough to cover sparse schedules (monthly, every 90
        // days) without scanning forever.
        guard let from = calendar.date(byAdding: .day, value: -45, to: deliveredAt) else {
            return nil
        }
        return schedule
            .occurrences(from: from, to: deliveredAt.addingTimeInterval(90), calendar: calendar)
            .last { TimeOfDay(from: $0, calendar: calendar) == time }
    }
}
