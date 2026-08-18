import SwiftUI

// MARK: - Medication tile

/// The colour-identity tile that represents a medication everywhere.
///
/// Sized with `@ScaledMetric`, so it grows with Dynamic Type instead of leaving
/// a 48pt square next to 40pt text at accessibility sizes.
struct MedicationTile: View {
    let color: MedicationColor
    /// Nil when the user never said what form it is — the tile then shows a
    /// neutral medical glyph instead of claiming pill.
    var form: MedicationForm? = nil
    var size: CGFloat = 48
    var badge: Badge?

    enum Badge: Equatable {
        case taken, missed, needsSetup

        var systemImage: String {
            switch self {
            case .taken: "checkmark.circle.fill"
            case .missed: "exclamationmark.circle.fill"
            case .needsSetup: "clock.badge.questionmark.fill"
            }
        }

        var tint: Color {
            switch self {
            case .taken: Theme.taken
            case .missed: Theme.missed
            case .needsSetup: Theme.due
            }
        }
    }

    @ScaledMetric(relativeTo: .headline) private var scale: CGFloat = 1

    private var resolved: CGFloat { size * scale }

    var body: some View {
        RoundedRectangle(cornerRadius: resolved * 0.27, style: .continuous)
            .fill(color.color.gradient)
            .frame(width: resolved, height: resolved)
            .overlay {
                // Unspecified form gets the neutral medical case, not an
                // assumed pill — an honest "you haven't told me yet".
                Image(systemName: form?.systemImage ?? "cross.case.fill")
                    .font(.system(size: resolved * 0.38))
                    // Contrast-correct against this specific swatch, not
                    // assumed white.
                    .foregroundStyle(color.onColor)
            }
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(systemName: badge.systemImage)
                        .font(.system(size: resolved * 0.32))
                        .foregroundStyle(badge.tint, Color(.systemBackground))
                        .offset(x: resolved * 0.08, y: resolved * 0.08)
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Rings

/// The app's adherence language: an empty track means nothing taken, an orange
/// arc means partial, a full green ring means done.
struct DayRing: View {
    let progress: DayProgress
    var size: CGFloat = 34
    var lineWidth: CGFloat = 4

    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1

    private var arcColor: Color? {
        guard progress.total > 0, progress.taken > 0 else { return nil }
        return progress.isComplete ? Theme.taken : Theme.due
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.22), lineWidth: lineWidth * scale)
            if let arcColor {
                Circle()
                    .trim(from: 0, to: max(0.02, progress.fraction))
                    .stroke(arcColor.gradient,
                            style: StrokeStyle(lineWidth: lineWidth * scale, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size * scale, height: size * scale)
        .animation(.smooth(duration: 0.35), value: progress)
        .accessibilityHidden(true)
    }
}

struct ProgressRing: View {
    let percent: Int?
    var size: CGFloat = 120
    var lineWidth: CGFloat = 14

    @ScaledMetric(relativeTo: .largeTitle) private var scale: CGFloat = 1

    private var tint: Color { Theme.adherenceColor(percent: percent) }
    private var fraction: Double { Double(percent ?? 0) / 100 }

    var body: some View {
        let resolved = size * scale
        ZStack {
            Circle().stroke(tint.opacity(0.16), lineWidth: lineWidth * scale)
            Circle()
                .trim(from: 0, to: max(0.001, min(fraction, 1)))
                .stroke(tint.gradient,
                        style: StrokeStyle(lineWidth: lineWidth * scale, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(percent.map { "\($0)%" } ?? "—")
                .font(.system(size: resolved * 0.24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: resolved, height: resolved)
        .animation(.smooth(duration: 0.5), value: percent)
        .accessibilityElement()
        .accessibilityLabel(
            percent.map { String(localized: "\($0) percent of doses taken") }
                ?? String(localized: "No doses logged yet")
        )
    }
}

// MARK: - Status chip

struct StatusChip: View {
    let text: String
    let color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        // Footnote, not caption: status is information people act on, and
        // 12pt fails older eyes. Matches the dose-timeline chips.
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color.opacity(0.14), in: .capsule)
        .foregroundStyle(color)
    }
}

// MARK: - Surfaces

/// One card surface for the whole app — the same solid grouped background
/// the Meds tab uses.
///
/// This used to be per-card Liquid Glass on iOS 26. Beautiful in isolation,
/// fragile in a scrolling list: without a `GlassEffectContainer` every card
/// ran its own glass pass, and cards visibly flickered on scroll, expand and
/// sheet recede — the "glitchy cards". Solid colour is what Apple Health
/// itself uses for dense lists, and it never glitches. Glass stays where it
/// belongs: the tab bar and toolbar controls.
struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        content.background(
            Color(.secondarySystemGroupedBackground),
            in: .rect(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

extension View {
    /// One card surface for the whole app. (An `interactive:` parameter used
    /// to be accepted here and silently ignored — a parameter that does
    /// nothing is a promise the code can't keep.)
    func cardStyle(cornerRadius: CGFloat = 22) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }

    /// The app's primary button treatment, one call site for the whole app.
    @ViewBuilder
    func prominentButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }

    /// The quiet counterpart to `prominentButton()`: frosted glass on iOS 26,
    /// a bordered capsule before that. For actions that must be reachable but
    /// never compete with the primary outcome — Skip, Undo, Done.
    @ViewBuilder
    func secondaryButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }

    /// The "add" action, identical wherever it appears.
    ///
    /// Green glass — the owner's explicit choice. Green also means "taken" in
    /// this app, so the two never sit side by side: this button only lives in
    /// toolbars, never on a dose card.
    @ViewBuilder
    func addButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(Theme.taken)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Theme.taken)
        }
    }

    /// Announces a message to VoiceOver.
    ///
    /// Toasts used to be the only confirmation that an action worked, and they
    /// were purely visual — a VoiceOver user tapped "Taken" and got silence.
    func announce(_ message: String?) -> some View {
        onChange(of: message) { _, new in
            guard let new else { return }
            AccessibilityNotification.Announcement(new).post()
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    let message: String
    var systemImage: String = "checkmark"

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .cardStyle(cornerRadius: 18)
            .padding(.top, 10)
            .allowsHitTesting(false)
            // The announcement carries this to VoiceOver; showing it twice
            // would be redundant.
            .accessibilityHidden(true)
    }
}

/// Presents transient confirmations and announces them.
struct ToastPresenter: ViewModifier {
    @Binding var toast: Toast?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast {
                    ToastView(message: toast.message, systemImage: toast.systemImage)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .animation(.smooth(duration: 0.3), value: toast)
            .announce(toast?.message)
            .task(id: toast) {
                guard toast != nil else { return }
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                toast = nil
            }
    }
}

struct Toast: Equatable {
    let message: String
    var systemImage: String = "checkmark"
}

extension View {
    func toast(_ toast: Binding<Toast?>) -> some View {
        modifier(ToastPresenter(toast: toast))
    }
}

// MARK: - Sheet chrome

struct SheetCloseButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Zero custom drawing. iOS 26 renders cancellation-action buttons as
        // the system's own frosted orb — resting, pressed and animated
        // exactly like Apple Health, because it IS the same chrome. Every
        // hand-built attempt fights the toolbar's automatic glass treatment
        // and blooms on press.
        Button(String(localized: "Close"), systemImage: "xmark") {
            dismiss()
        }
    }
}

// MARK: - Section header

struct SectionLabel: View {
    let title: String
    var detail: String?
    var detailColor: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(detailColor)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Haptics

/// One haptic vocabulary for the whole app.
///
/// Generators are cached and prepared, because a freshly-created generator
/// often drops or delays its first tap — which is exactly the tap that matters
/// when someone confirms a dose.
@MainActor
enum Haptics {
    private static let notification = UINotificationFeedbackGenerator()
    private static let selection = UISelectionFeedbackGenerator()
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)

    static func prepare() {
        notification.prepare()
        selection.prepare()
        light.prepare()
    }

    static func success() { notification.notificationOccurred(.success) }
    static func warning() { notification.notificationOccurred(.warning) }
    static func error() { notification.notificationOccurred(.error) }
    static func select() { selection.selectionChanged() }
    static func tap() { light.impactOccurred() }
    static func impact() { medium.impactOccurred() }
}
