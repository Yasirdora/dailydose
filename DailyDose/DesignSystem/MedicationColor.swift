import SwiftUI

/// The medication colour palette, matched to Apple Health's.
///
/// Every colour is dynamic — deep and saturated in light mode, lifted toward
/// white at night so it stays luminous on black, and pushed to a high-contrast
/// variant when the user has asked for one.
///
/// Crucially, each swatch also declares the *foreground* colour that belongs on
/// top of it. The old palette painted a white glyph on every tile, which fell
/// below the 3:1 non-text contrast minimum on yellow, mint, sky, olive and
/// brown — five of the twelve. Apple Health uses a dark glyph on its light
/// chips for exactly this reason.
enum MedicationColor: String, CaseIterable, Identifiable, Sendable {
    case navy, charcoal, yellow, coral, olive, mint
    case sky, purple, mauve, pink, red, brown

    var id: String { rawValue }

    static let `default` = MedicationColor.navy

    /// Resolves a stored key, tolerating values written by older builds.
    static func named(_ name: String) -> MedicationColor {
        if let exact = MedicationColor(rawValue: name) { return exact }
        // Keys used before the palette was aligned with Apple Health.
        let legacy: [String: MedicationColor] = [
            "teal": .mint, "blue": .navy, "plum": .red, "amber": .brown,
            "green": .mint, "gray": .charcoal, "accent": .navy,
        ]
        return legacy[name] ?? .default
    }

    var displayName: String {
        switch self {
        case .navy: String(localized: "Navy", comment: "Medication colour")
        case .charcoal: String(localized: "Charcoal", comment: "Medication colour")
        case .yellow: String(localized: "Yellow", comment: "Medication colour")
        case .coral: String(localized: "Coral", comment: "Medication colour")
        case .olive: String(localized: "Olive", comment: "Medication colour")
        case .mint: String(localized: "Mint", comment: "Medication colour")
        case .sky: String(localized: "Sky", comment: "Medication colour")
        case .purple: String(localized: "Purple", comment: "Medication colour")
        case .mauve: String(localized: "Mauve", comment: "Medication colour")
        case .pink: String(localized: "Pink", comment: "Medication colour")
        case .red: String(localized: "Red", comment: "Medication colour")
        case .brown: String(localized: "Brown", comment: "Medication colour")
        }
    }

    /// sRGB components sampled from Apple Health's picker.
    private var base: (r: Double, g: Double, b: Double) {
        switch self {
        case .navy: (0.314, 0.506, 0.647)
        case .charcoal: (0.376, 0.373, 0.384)
        case .yellow: (0.965, 0.808, 0.275)
        case .coral: (0.933, 0.545, 0.424)
        case .olive: (0.690, 0.749, 0.408)
        case .mint: (0.510, 0.867, 0.675)
        case .sky: (0.525, 0.757, 0.918)
        case .purple: (0.576, 0.392, 0.867)
        case .mauve: (0.600, 0.498, 0.667)
        case .pink: (0.929, 0.467, 0.639)
        case .red: (0.757, 0.267, 0.216)
        case .brown: (0.851, 0.745, 0.620)
        }
    }

    /// WCAG relative luminance. Internal rather than private so the test suite
    /// can assert the real contrast ratio of every swatch.
    var relativeLuminance: Double {
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let c = base
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    /// The glyph colour that actually meets contrast on this swatch, chosen by
    /// luminance rather than by assumption.
    ///
    /// The threshold is the crossover point where white-on-swatch and
    /// dark-on-swatch give equal WCAG contrast: solving
    /// `1.05 / (L + 0.05) == (L + 0.05) / (L_dark + 0.05)` for `L_dark ≈ 0.0144`
    /// gives `L ≈ 0.21`. Picking it by eye is how coral (2.46:1) and pink
    /// (2.70:1) ended up below the 3:1 non-text minimum; measured, the worst
    /// case across the whole palette is 4.1:1.
    static let glyphLuminanceThreshold = 0.21

    var onColor: Color {
        relativeLuminance > Self.glyphLuminanceThreshold ? Color(white: 0.12) : .white
    }

    /// Contrast ratio between this swatch and the glyph drawn on it.
    var glyphContrastRatio: Double {
        let glyph = relativeLuminance > Self.glyphLuminanceThreshold
            ? 0.0144   // Color(white: 0.12)
            : 1.0      // .white
        let hi = max(relativeLuminance, glyph)
        let lo = min(relativeLuminance, glyph)
        return (hi + 0.05) / (lo + 0.05)
    }

    var color: Color {
        Color(uiColor: UIColor { traits in
            var (r, g, b) = self.base
            if traits.userInterfaceStyle == .dark {
                // Lift toward white so saturated colours stay legible on black.
                r += (1 - r) * 0.12; g += (1 - g) * 0.12; b += (1 - b) * 0.12
            }
            if traits.accessibilityContrast == .high {
                // Deepen in light mode, brighten further in dark, so the tile
                // separates cleanly from the card behind it.
                let factor = traits.userInterfaceStyle == .dark ? 1.18 : 0.78
                r = min(max(r * factor, 0), 1)
                g = min(max(g * factor, 0), 1)
                b = min(max(b * factor, 0), 1)
            }
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
    }
}

/// App-wide semantic colours. Everything routes through the asset catalog's
/// `AccentColor` so light, dark and tinted appearances stay consistent for free.
enum Theme {
    static let accent = Color.accentColor

    /// Status colours, used for dose state everywhere in the app. Defined once
    /// so "taken green" is the same green in the card, the ring and the chart.
    static let taken = Color.green
    static let due = Color.orange
    static let missed = Color.red
    static let skipped = Color.secondary

    static func statusColor(_ status: DoseStatus) -> Color {
        switch status {
        case .taken: taken
        case .skipped: skipped
        case .missed: missed
        }
    }

    /// The adherence colour ramp, shared by every ring and percentage label.
    static func adherenceColor(percent: Int?) -> Color {
        guard let percent else { return .secondary }
        switch percent {
        case 90...: return taken
        case 60..<90: return due
        default: return missed
        }
    }
}
