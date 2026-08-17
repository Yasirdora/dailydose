import Foundation

/// How long a dose stays actionable before the app calls it missed.
///
/// This used to be a hardcoded two hours, which meant a single constant
/// silently decided what "missed" means — and therefore decided the adherence
/// percentage the entire History tab is built around. Two hours is right for
/// some people and wrong for others: a strict cardiac regimen wants a tight
/// window, while someone taking a vitamin whenever they get to it does not want
/// a red "Missed" every afternoon.
///
/// It is a genuine preference, not a tuning constant, so it belongs to the user.
enum DoseWindow: String, Codable, CaseIterable, Identifiable, Sendable {
    case strict         // 1 hour
    case standard       // 2 hours — the default
    case relaxed        // 4 hours
    case untilEndOfDay

    var id: String { rawValue }

    static let `default` = DoseWindow.standard

    /// `nil` for `.untilEndOfDay`, which is a calendar question rather than a
    /// duration — see `deadline(for:calendar:)`.
    var interval: TimeInterval? {
        switch self {
        case .strict: 1 * 3600
        case .standard: 2 * 3600
        case .relaxed: 4 * 3600
        case .untilEndOfDay: nil
        }
    }

    var title: String {
        switch self {
        case .strict: String(localized: "1 hour")
        case .standard: String(localized: "2 hours")
        case .relaxed: String(localized: "4 hours")
        case .untilEndOfDay: String(localized: "Until end of day")
        }
    }

    var explanation: String {
        switch self {
        case .strict:
            String(localized: "Strict — best for medication that has to be taken on time.")
        case .standard:
            String(localized: "Balanced. Suits most medication.")
        case .relaxed:
            String(localized: "Relaxed — room for a day that doesn't go to plan.")
        case .untilEndOfDay:
            String(localized: "A dose only counts as missed once the day is over.")
        }
    }

    /// The instant after which an unlogged dose counts as missed.
    ///
    /// `.untilEndOfDay` resolves against the calendar rather than by adding
    /// seconds, so a dose at 23:00 gets the last hour of its own day — not an
    /// arbitrary slice of tomorrow.
    func deadline(for scheduledAt: Date, calendar: Calendar = .current) -> Date {
        if let interval { return scheduledAt.addingTimeInterval(interval) }
        let startOfNextDay = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: scheduledAt)
        ) ?? scheduledAt.addingTimeInterval(4 * 3600)
        // A dose scheduled *at* midnight would otherwise get a zero-length
        // window; give it the full day it belongs to.
        return max(startOfNextDay, scheduledAt.addingTimeInterval(60))
    }
}

/// Settings that change how the app interprets what the user does, as opposed
/// to how loudly it speaks (`NotificationPreferences`).
///
/// Kept separate on purpose: the notification planner and the dose calculator
/// are different owners with different reasons to change, and folding them into
/// one object would mean every notification tweak invalidated dose logic.
struct TrackingPreferences: Codable, Equatable, Sendable {
    var doseWindow: DoseWindow = .default

    static let `default` = TrackingPreferences()

    // MARK: - Persistence

    private static let storageKey = "trackingPreferences.v1"

    static func load(from defaults: UserDefaults = .standard) -> TrackingPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(TrackingPreferences.self, from: data)
        else { return .default }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
