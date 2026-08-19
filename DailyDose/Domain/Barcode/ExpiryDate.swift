import Foundation

/// The date a pack stops being safe to use, as its own barcode encoded it.
///
/// The single most valuable thing a medicine barcode gives us: it is inside the
/// code, it needs no database, no licence and no network, and it is true in
/// every market. Everything below exists to read six digits without ever
/// showing the user a date the pack did not mean.
struct ExpiryDate: Equatable, Sendable {

    /// The last day the pack is good for, at the start of that day.
    ///
    /// Start of day rather than end: every comparison in this app is "which
    /// day is this?", and an instant at 23:59:59 is the same answer with a
    /// rounding hazard attached.
    let day: Date

    /// The code said `DD = 00` and we resolved it to the month's last day.
    let isEndOfMonth: Bool

    /// The code did something its own syntax forbids.
    ///
    /// GS1 healthcare has prohibited `DD = 00` since 1 January 2025; German PPN
    /// syntax still permits it. So this is recorded, never a rejection — the
    /// resolved date is unambiguous either way, and packs printed before the
    /// ban are still on shelves and still in people's cupboards.
    let isNonConformant: Bool

    /// How a two-digit year is to be read, which is not the same question in
    /// the two syntaxes.
    enum Encoding: Sendable {
        /// GS1. See `resolveYear` for why this is not GS1's own window.
        case gs1
        /// IFA: PPN dates are always 21st century, full stop.
        case ppn
    }

    /// Reads a `YYMMDD` field.
    ///
    /// `reference` is the "today" the century window is measured from, and is
    /// a parameter rather than `Date.now` so the behaviour can be pinned in a
    /// test instead of drifting with the wall clock.
    static func parse(
        _ yymmdd: String,
        encoding: Encoding,
        reference: Date,
        calendar: Calendar
    ) -> ExpiryDate? {
        guard yymmdd.count == 6, yymmdd.isASCIIDigits,
              let yy = Int(yymmdd.prefix(2)),
              let month = Int(yymmdd.dropFirst(2).prefix(2)),
              let dayOfMonth = Int(yymmdd.suffix(2)),
              (1...12).contains(month)
        else { return nil }

        let year = resolveYear(yy, encoding: encoding, reference: reference, calendar: calendar)

        // `DD = 00` is "the end of that month" in both syntaxes. Only GS1 has
        // outlawed it, so only GS1 gets the non-conformance flag.
        if dayOfMonth == 0 {
            guard let lastDay = lastDayOfMonth(year: year, month: month, calendar: calendar) else { return nil }
            return ExpiryDate(day: lastDay, isEndOfMonth: true, isNonConformant: encoding == .gs1)
        }

        guard let day = realDate(year: year, month: month, day: dayOfMonth, calendar: calendar) else { return nil }
        return ExpiryDate(day: day, isEndOfMonth: false, isNonConformant: false)
    }

    // MARK: - Century

    /// Turns `YY` into a year.
    ///
    /// PPN is stated: 21st century, always.
    ///
    /// GS1 specifies a ±50-year sliding window, which we deliberately do not
    /// implement. A medicine's shelf life does not reach a decade, so the
    /// window here is biased forward — two years back, ninety-seven forward —
    /// on the reasoning that a box in someone's hand is far more likely to be
    /// expiring soon than to have expired in the last century.
    ///
    /// The cost of that bias is at the other end: a pack more than two years
    /// past its date reads as roughly a century in the future rather than
    /// slightly in the past. Any hundred-year window has to break somewhere,
    /// and this is where we chose to put the seam.
    private static func resolveYear(
        _ yy: Int, encoding: Encoding, reference: Date, calendar: Calendar
    ) -> Int {
        switch encoding {
        case .ppn:
            return 2000 + yy
        case .gs1:
            let lowerBound = calendar.component(.year, from: reference) - 2
            return lowerBound + ((yy - lowerBound % 100) + 100) % 100
        }
    }

    // MARK: - Calendar

    private static func lastDayOfMonth(year: Int, month: Int, calendar: Calendar) -> Date? {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let length = calendar.range(of: .day, in: .month, for: first)?.count
        else { return nil }
        return realDate(year: year, month: month, day: length, calendar: calendar)
    }

    /// A date only if that day genuinely exists.
    ///
    /// `Calendar` happily rolls 30 February into 2 March, which would turn a
    /// misread into a plausible-looking expiry date. Reading the components
    /// back and insisting they match is what stops that.
    private static func realDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard parts.year == year, parts.month == month, parts.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }
}
