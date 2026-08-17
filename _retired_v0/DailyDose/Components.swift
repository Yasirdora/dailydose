import SwiftUI

/// Two-tone capsule glyph in the spirit of Apple Health's medication icons.
struct PillGlyph: View {
    let color: Color
    var size: CGFloat = 44

    var body: some View {
        Capsule(style: .continuous)
            .fill(color.opacity(0.28))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(color.gradient)
                    .frame(width: size * 0.52)
            }
            .clipShape(Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(color.opacity(0.35), lineWidth: 1)
            }
            .frame(width: size, height: size * 0.46)
            .rotationEffect(.degrees(-28))
            .frame(width: size * 0.9, height: size * 0.9)
            .accessibilityHidden(true)
    }
}

/// Circular progress ring with a rounded stroke and an animated numeric center.
struct ProgressRing: View {
    let progress: Double // 0…1
    var size: CGFloat = 56
    var lineWidth: CGFloat = 7
    var tint: Color = MedPalette.accent
    var centerLabel: String?

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.6), value: progress)
            if let centerLabel {
                Text(centerLabel)
                    .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.4), value: centerLabel)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Progress \(Int(progress * 100)) percent")
    }
}

/// Small rounded status pill ("Due now", "Taken", …).
struct StatusChip: View {
    let text: String
    let color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
    }
}

/// Liquid Glass on iOS 26+, material card on earlier systems.
/// Convention (borrowed from Apple's own apps): glass lives on floating chrome
/// and cards — `interactive: true` only when the surface is tappable.
struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 24
    var interactive = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular,
                                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension View {
    func cardStyle(cornerRadius: CGFloat = 24, interactive: Bool = false) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius, interactive: interactive))
    }

    /// Floating circular glass button — camera overlays and full-bleed sheets.
    @ViewBuilder
    func glassCircleButton() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self.background(.regularMaterial, in: Circle())
        }
    }

    /// iOS 26 glassProminent primary button, falling back to borderedProminent.
    @ViewBuilder
    func prominentButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

/// Standard sheet close affordance — a plain X in the trailing toolbar slot,
/// matching Apple's own sheets (Maps, Settings panes).
struct SheetCloseButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
        }
        .accessibilityLabel("Close")
    }
}

/// Lightweight glass toast for momentary feedback ("Taken ✓").
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
    }
}

/// Named haptics — one vocabulary across the app.
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func light()   { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium()  { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func select()  { UISelectionFeedbackGenerator().selectionChanged() }
}

/// Mini day-progress ring — the app's adherence language:
/// bare gray track = nothing taken, orange arc = some taken, green = all taken.
/// Shared by the week strip and the calendar sheet.
struct DayRing: View {
    let taken: Int
    let total: Int
    var size: CGFloat = 30
    var lineWidth: CGFloat = 3.5

    private var progress: Double {
        guard total > 0 else { return 0 }
        return Double(taken) / Double(total)
    }

    private var arcColor: Color? {
        guard total > 0, taken > 0 else { return nil }
        return taken == total ? .green : .orange
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.22), lineWidth: lineWidth)
            if let arcColor {
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(arcColor.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(duration: 0.4), value: progress)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(taken) of \(total) doses taken")
    }
}
