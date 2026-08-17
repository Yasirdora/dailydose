import Foundation

/// The one set of adherence band boundaries: 90%+ excellent, 60–89% fair,
/// below 60% off track.
///
/// Colour (`Theme.adherenceColor`), print colour (the doctor report) and
/// words (`Summary.verdict`) all read from here, so a "good" score is the
/// same score on screen, on paper and in prose. The boundaries live in the
/// domain rather than the design system because they are a clinical
/// communication decision, not a paint decision. 60/90 over the report's
/// old 70/90: a ramp that calls 65% "missed-red" punishes exactly the
/// people the app exists to encourage.
enum AdherenceBand: Sendable {
    case excellent, fair, offTrack

    static func band(percent: Int) -> AdherenceBand {
        switch percent {
        case 90...: .excellent
        case 60..<90: .fair
        default: .offTrack
        }
    }
}

/// Adherence over a window, plus the per-day breakdown the chart draws.
///
/// One rule underpins the whole file: **everything is measured by the day the
/// dose was *scheduled* for, never by the day it happened to be written to
/// disk.** The old code mixed the two — the hero ring filtered on `loggedAt`
/// while the bars beneath it filtered on `scheduledAt` — so the headline number
/// and the chart could disagree, and a batch of backfilled misses from last
/// week would all pile onto today.
enum AdherenceCalculator {

    struct Summary: Equatable, Sendable {
        var taken = 0
        var skipped = 0
        var missed = 0

        var total: Int { taken + skipped + missed }
        /// `nil` when there is nothing to measure. Rendering "0%" for a user who
        /// has simply not started yet is discouraging and untrue.
        var percent: Int? {
            guard total > 0 else { return nil }
            return Int((100.0 * Double(taken) / Double(total)).rounded())
        }

        /// Fewer logged doses than this make a percentage noise, not signal:
        /// one taken dose out of one renders as a triumphant 100% ring, and
        /// one missed out of one as a 0% alarm. Below the threshold, surfaces
        /// show the counts and a dash instead of a verdict.
        static let minimumTrendSample = 5
        var isTrendMeaningful: Bool { total >= Self.minimumTrendSample }
    }

    struct DayBucket: Identifiable, Equatable, Sendable {
        let day: Date
        var taken = 0
        var total = 0

        /// Stable identity so SwiftUI Charts can diff across recomputation.
        /// A fresh `UUID()` here — which is what the old code used — defeats
        /// diffing entirely and re-animates every bar on any state change.
        var id: Date { day }
        var fraction: Double { total > 0 ? Double(taken) / Double(total) : 0 }
    }

    struct Record: Equatable, Sendable {
        let medicationID: String
        let scheduledAt: Date
        let status: DoseStatus
    }

    /// Totals for the `days` window ending at `now`.
    static func summary(
        records: [Record],
        days: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> Summary {
        var summary = Summary()
        for record in inWindow(records, days: days, now: now, calendar: calendar) {
            switch record.status {
            case .taken: summary.taken += 1
            case .skipped: summary.skipped += 1
            case .missed: summary.missed += 1
            }
        }
        return summary
    }

    /// One bucket per day, oldest first, including days with nothing logged so
    /// the chart shows a continuous timeline rather than a ragged one.
    static func dailyBuckets(
        records: [Record],
        days: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> [DayBucket] {
        var buckets: [Date: DayBucket] = [:]
        let today = calendar.startOfDay(for: now)

        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            buckets[day] = DayBucket(day: day)
        }
        for record in inWindow(records, days: days, now: now, calendar: calendar) {
            let day = calendar.startOfDay(for: record.scheduledAt)
            guard var bucket = buckets[day] else { continue }
            bucket.total += 1
            if record.status == .taken { bucket.taken += 1 }
            buckets[day] = bucket
        }
        return buckets.values.sorted { $0.day < $1.day }
    }

    /// Per-medication summaries, worst adherence first — the one that needs
    /// attention should not be buried at the bottom of the list.
    static func byMedication(
        records: [Record],
        days: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> [(medicationID: String, summary: Summary)] {
        var grouped: [String: Summary] = [:]
        for record in inWindow(records, days: days, now: now, calendar: calendar) {
            var summary = grouped[record.medicationID] ?? Summary()
            switch record.status {
            case .taken: summary.taken += 1
            case .skipped: summary.skipped += 1
            case .missed: summary.missed += 1
            }
            grouped[record.medicationID] = summary
        }
        return grouped
            .map { (medicationID: $0.key, summary: $0.value) }
            .sorted {
                ($0.summary.percent ?? 0, $0.medicationID) < ($1.summary.percent ?? 0, $1.medicationID)
            }
    }

    private static func inWindow(
        _ records: [Record],
        days: Int,
        now: Date,
        calendar: Calendar
    ) -> [Record] {
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        return records.filter { $0.scheduledAt >= cutoff && $0.scheduledAt <= now }
    }
}

extension AdherenceCalculator.Summary {
    /// Plain-language verdict. Deliberately avoids congratulating someone at
    /// 20% and avoids scolding anyone: the app's job is to help, not to grade.
    var verdict: String {
        guard let percent else {
            return String(localized: "Log your first doses and the story begins.")
        }
        switch AdherenceBand.band(percent: percent) {
        case .excellent: return String(localized: "Excellent — barely a dose missed.")
        case .fair: return String(localized: "Good — most doses are taken.")
        case .offTrack: return String(localized: "Off track — let's tighten up the reminders.")
        }
    }
}
