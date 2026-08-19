import Foundation

/// A wall-clock time of day, independent of any calendar date.
///
/// Replaces the `"HH:mm"` strings the app used to pass around. Those strings
/// were parsed in five different places, sorted lexically, compared for
/// equality by hand, and formatted through a `DateFormatter` with no fixed
/// locale — which quietly produced different results on non-Gregorian
/// calendars. Making it a type removes all of that at once:
///
/// * `Comparable` gives correct ordering without lexical sorting.
/// * `Hashable` makes duplicate dose times impossible to store (we keep a Set).
/// * One parser, one formatter, one source of truth.
struct TimeOfDay: Hashable, Comparable, Codable, Sendable, Identifiable {
    let hour: Int      // 0…23
    let minute: Int    // 0…59

    var id: String { rawValue }

    /// Fails rather than clamping: an out-of-range time is corrupt data, and
    /// silently turning 25:00 into 23:59 would hide the corruption.
    init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// Parses `"HH:mm"`. Tolerates a missing leading zero (`"8:00"`).
    init?(_ string: String) {
        let parts = string.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        self.init(hour: h, minute: m)
    }

    /// Round-trips through `init?(_:)`. Always zero-padded, always ASCII —
    /// safe to use in persistent identifiers.
    var rawValue: String { String(format: "%02d:%02d", hour, minute) }

    /// Minutes since midnight — the natural ordering key.
    var minutesSinceMidnight: Int { hour * 60 + minute }

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }

    // MARK: - Calendar bridging

    /// Resolves this time on a given day.
    ///
    /// Returns `nil` on the spring-forward DST gap, where the wall-clock time
    /// genuinely does not exist. Callers decide what that means for them —
    /// `DoseSchedule` shifts the dose forward to the first valid instant, which
    /// is what a person would do with a physical pillbox.
    func date(on day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }

    init(from date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        self.hour = c.hour ?? 0
        self.minute = c.minute ?? 0
    }

    /// Localised for display ("8:00 AM" / "08:00"), respecting the user's
    /// 12/24-hour preference. Built from a fixed reference date so the result
    /// never depends on today's date or time zone.
    func formatted(locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let components = DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)
        guard let date = calendar.date(from: components) else { return rawValue }
        return date.formatted(.dateTime.hour().minute().locale(locale))
    }
}

extension TimeOfDay {
    /// Suggested clock times for a given number of doses per day, spread across
    /// waking hours. Index 0 is unused so the array reads as "times for N doses".
    static func suggested(forDosesPerDay count: Int) -> [TimeOfDay] {
        let table: [[(Int, Int)]] = [
            [],
            [(8, 0)],
            [(8, 0), (20, 0)],
            [(8, 0), (14, 0), (20, 0)],
            [(8, 0), (13, 0), (18, 0), (22, 0)],
        ]
        let clamped = min(max(count, 1), table.count - 1)
        return table[clamped].compactMap { TimeOfDay(hour: $0.0, minute: $0.1) }
    }

    static let morning = TimeOfDay(hour: 8, minute: 0)!
}
