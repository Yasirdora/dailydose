import Foundation

/// How much a medication is allowed to interrupt.
///
/// Not everything in a medication list carries the same weight. A daily vitamin
/// and a heart medication are not the same event, and delivering them with the
/// same urgency is what teaches people to swipe both away without looking —
/// the habituation that makes the reminder that *mattered* fail too.
enum MedicationImportance: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Arrives silently in Notification Centre. For supplements and anything
    /// where a missed dose is genuinely fine.
    case gentle
    /// The default. Sound, and breaks through Focus modes.
    case standard
    /// Everything `standard` does, plus it still follows up during quiet hours.
    /// For medication where a missed dose actually matters.
    case important

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gentle: String(localized: "Gentle")
        case .standard: String(localized: "Standard")
        case .important: String(localized: "Important")
        }
    }

    var explanation: String {
        switch self {
        case .gentle:
            String(localized: "Arrives quietly, without a sound. Good for vitamins and supplements.")
        case .standard:
            String(localized: "Plays a sound and breaks through Focus modes.")
        case .important:
            String(localized: "Like Standard, and still follows up during quiet hours.")
        }
    }

    var systemImage: String {
        switch self {
        case .gentle: "bell.slash"
        case .standard: "bell"
        case .important: "bell.badge"
        }
    }

    /// Whether a reminder at this level should try to break through Focus.
    ///
    /// Deliberately capped at "time sensitive". Apple's *Critical Alerts* —
    /// which also override the mute switch — require an entitlement granted
    /// only where a missed alert is clinically dangerous, and a general-purpose
    /// medication reminder does not qualify. Claiming otherwise in the UI would
    /// be a promise the app cannot keep.
    var breaksThroughFocus: Bool { self != .gentle }

    var playsSound: Bool { self != .gentle }

    /// The tone this level actually gets.
    ///
    /// `.gentle` is silent whatever the user picked — that is the entire point
    /// of the level, and resolving it here means the rule lives in exactly one
    /// place instead of being re-derived at every call site.
    func resolvedSound(preferred: NotificationSound) -> NotificationSound {
        playsSound ? preferred : .none
    }
}

/// How often, how loudly, and when the app is allowed to speak.
///
/// ## Why these controls exist
///
/// The evidence on medication reminders is uncomfortable. The REMIND trial
/// (JAMA Internal Medicine, ~53,000 patients) found that reminder devices alone
/// produced **no measurable adherence improvement** — roughly 15% of people hit
/// optimal adherence whether or not they had one. What *did* work, in a later
/// randomised trial of a reminder app, was the combination of reminder plus
/// frictionless logging plus visible adherence feedback.
///
/// The lesson is not "send more reminders". It is that a reminder's value comes
/// from the action attached to it, and that every low-value notification spends
/// the same attention budget as a high-value one. So the design here is
/// deliberately conservative: one notification per moment, actions attached,
/// and an explicit ceiling on how much the app may escalate.
struct NotificationPreferences: Codable, Equatable, Sendable {

    // MARK: Dose reminders

    var doseRemindersEnabled = true

    /// The tone for dose reminders and their follow-ups.
    var doseSound: NotificationSound = .default

    /// Collapses medications that share a dose time into a single notification.
    ///
    /// This is the largest single reduction in notification volume available.
    /// Three medications at 08:00 previously produced three separate alerts
    /// arriving in the same second — the pile-up that trains people to clear
    /// the stack without reading it.
    var bundleSimultaneousDoses = true

    // MARK: Follow-up

    /// A second nudge if a dose is still unlogged.
    ///
    /// On by default because it is the one escalation with a plausible case:
    /// it fires only when the user demonstrably did not act. It is also the
    /// first thing to switch off if the app starts feeling naggy, which is why
    /// it gets its own control rather than being buried in behaviour.
    var followUpEnabled = true
    var followUpDelay: FollowUpDelay = .thirty

    enum FollowUpDelay: Int, Codable, CaseIterable, Identifiable, Sendable {
        case ten = 10, fifteen = 15, thirty = 30, sixty = 60

        var id: Int { rawValue }
        var interval: TimeInterval { TimeInterval(rawValue * 60) }
        var title: String { String(localized: "\(rawValue) minutes") }
    }

    // MARK: Quiet hours

    /// Overnight, the app stops escalating.
    ///
    /// Scheduled dose reminders still arrive — the user chose those times and
    /// suppressing them would break the app's core promise. What quiet hours
    /// suppress is everything the *app* decided to send: follow-ups and refill
    /// alerts. A 3 a.m. "you didn't log your 2:30 dose" is pure noise, and it
    /// is exactly the kind of notification that gets a whole app muted.
    var quietHoursEnabled = true
    var quietHoursStart = TimeOfDay(hour: 22, minute: 0) ?? .morning
    var quietHoursEnd = TimeOfDay(hour: 7, minute: 0) ?? .morning

    // MARK: Refill

    var refillAlertsEnabled = true
    var refillAlertTime = TimeOfDay(hour: 9, minute: 0) ?? .morning

    /// Refills default to silent. Supply is never urgent enough to make a
    /// noise, and a sound here spends attention the dose reminders need.
    var refillSound: NotificationSound = .none

    static let `default` = NotificationPreferences()

    // MARK: - Quiet-hours evaluation

    /// Whether `date` falls inside the quiet window, handling the overnight
    /// wrap (22:00 → 07:00 spans midnight, so a simple range comparison is
    /// wrong for exactly the hours that matter most).
    func isQuiet(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let minutes = TimeOfDay(from: date, calendar: calendar).minutesSinceMidnight
        let start = quietHoursStart.minutesSinceMidnight
        let end = quietHoursEnd.minutesSinceMidnight

        if start == end { return false }          // a zero-length window is "off"
        if start < end { return minutes >= start && minutes < end }
        return minutes >= start || minutes < end  // wraps past midnight
    }

    /// Human-readable window, e.g. "22:00 – 07:00".
    var quietHoursSummary: String {
        guard quietHoursEnabled else { return String(localized: "Off") }
        return "\(quietHoursStart.formatted()) – \(quietHoursEnd.formatted())"
    }

    // MARK: - Persistence

    private static let storageKey = "notificationPreferences.v1"

    static func load(from defaults: UserDefaults = .standard) -> NotificationPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(NotificationPreferences.self, from: data)
        else { return .default }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// Observable wrapper so SwiftUI can bind directly to the preferences and every
/// change is persisted and rescheduled without the view having to remember to.
@MainActor
@Observable
final class NotificationSettingsStore {
    private let defaults: UserDefaults
    private let onChange: (NotificationPreferences) -> Void

    var preferences: NotificationPreferences {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save(to: defaults)
            onChange(preferences)
        }
    }

    init(defaults: UserDefaults = .standard, onChange: @escaping (NotificationPreferences) -> Void) {
        self.defaults = defaults
        self.onChange = onChange
        self.preferences = NotificationPreferences.load(from: defaults)
    }
}
