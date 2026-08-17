import Foundation

/// The sound a reminder makes.
///
/// ## Why the app ships its own sounds
///
/// iOS does not let a third-party app reference the system's own notification
/// tones — "Note", "Chord" and the rest are private to Apple. Every app with a
/// sound picker, WhatsApp included, bundles its own audio files and gives them
/// familiar-sounding names. So these are ours.
///
/// ## Why these particular sounds
///
/// A person taking one medication four times a day hears their reminder tone
/// roughly **1,400 times a year**. That is more than almost any other sound in
/// their life, and it makes the design brief unusual:
///
/// * **Calm, not alarming.** An alarm-like tone raises stress and gets silenced.
///   A reminder that has been silenced is worse than no reminder at all.
/// * **Short.** Under two seconds. Anything longer outstays its welcome by the
///   hundredth hearing.
/// * **Consonant.** Every tone here is built on musical intervals with
///   inharmonic partials — struck metal and wood, not synthesiser beeps.
///   Consonance is what lets a sound survive repetition.
/// * **Headroom.** Peaks are normalised to 0.72, not 1.0, so nothing clips
///   through the system mixer.
///
/// ## Platform requirements these files satisfy
///
/// Custom notification sounds must be under 30 seconds and encoded as Linear
/// PCM, MA4, µLaw or aLaw in an `.aiff`, `.wav` or `.caf` container, sitting in
/// the app bundle (or `Library/Sounds`). These are mono 44.1 kHz 16-bit PCM
/// WAVs of 1–1.8 seconds.
enum NotificationSound: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Silent. The notification still appears — it just doesn't speak.
    case none
    /// Two soft bell strikes, a rising perfect fifth. The default.
    case chime
    /// One warm wooden tone. The quietest option that still speaks.
    case marimba
    /// Three ascending notes — reads as "something to do", not "something wrong".
    case rise
    /// A bright single strike, crystalline and brief.
    case glass
    /// A soft double-tap. Slightly more insistent, for medication that matters.
    case pulse

    var id: String { rawValue }

    static let `default` = NotificationSound.chime

    var title: String {
        switch self {
        case .none: String(localized: "None", comment: "Notification sound")
        case .chime: String(localized: "Chime", comment: "Notification sound")
        case .marimba: String(localized: "Marimba", comment: "Notification sound")
        case .rise: String(localized: "Rise", comment: "Notification sound")
        case .glass: String(localized: "Glass", comment: "Notification sound")
        case .pulse: String(localized: "Pulse", comment: "Notification sound")
        }
    }

    var subtitle: String? {
        switch self {
        case .none: String(localized: "Silent — the reminder still appears")
        case .chime: String(localized: "Two soft bells")
        case .marimba: String(localized: "One warm wooden note")
        case .rise: String(localized: "Three rising notes")
        case .glass: String(localized: "A bright single strike")
        case .pulse: String(localized: "A gentle double tap")
        }
    }

    /// The bundled file, or `nil` for silence.
    ///
    /// `UNNotificationSound(named:)` resolves this against the app bundle, so
    /// the filename must match exactly — including the extension.
    var fileName: String? {
        self == .none ? nil : "\(rawValue).wav"
    }

    /// Resource name for in-app auditioning, where the extension is separate.
    var resourceName: String? { self == .none ? nil : rawValue }
}
