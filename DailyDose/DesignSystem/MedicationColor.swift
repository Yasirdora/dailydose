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

    /// WCAG relative luminance of raw sRGB components.
    static func luminance(r: Double, g: Double, b: Double) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// The components actually drawn for a given trait combination — the same
    /// adaptation `color` performs, exposed so the glyph colour and the test
    /// suite measure the rendered swatch, not the raw one.
    func resolvedComponents(
        style: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast
    ) -> (r: Double, g: Double, b: Double) {
        var (r, g, b) = base
        if style == .dark {
            // Lift toward white so saturated colours stay legible on black.
            r += (1 - r) * 0.12; g += (1 - g) * 0.12; b += (1 - b) * 0.12
        }
        if contrast == .high {
            // Deepen in light mode, brighten further in dark, so the tile
            // separates cleanly from the card behind it.
            let factor = style == .dark ? 1.18 : 0.78
            r = min(max(r * factor, 0), 1)
            g = min(max(g * factor, 0), 1)
            b = min(max(b * factor, 0), 1)
        }
        return (r, g, b)
    }

    /// Luminance of the raw swatch. Kept for the test suite.
    var relativeLuminance: Double {
        let c = base
        return Self.luminance(r: c.r, g: c.g, b: c.b)
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

    /// Whether the dark glyph outperforms white on a swatch of this luminance.
    static func usesDarkGlyph(luminance l: Double) -> Bool {
        l > glyphLuminanceThreshold
    }

    /// Whether the rendered swatch takes the dark glyph for these traits.
    /// Internal so the test suite can assert the choice per trait combination.
    func usesDarkGlyph(style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast) -> Bool {
        let c = resolvedComponents(style: style, contrast: contrast)
        return Self.usesDarkGlyph(luminance: Self.luminance(r: c.r, g: c.g, b: c.b))
    }

    /// The glyph colour that meets contrast on the swatch as it is actually
    /// drawn — resolved per traits, because dark mode and high-contrast change
    /// the swatch's luminance. Measured from `base` instead, white-on-navy in
    /// high-contrast dark mode falls to ~2.5:1, below the 3:1 non-text minimum,
    /// in the very setting a low-vision user enabled to get *more* contrast.
    var onColor: Color {
        Color(uiColor: UIColor { traits in
            let c = self.resolvedComponents(
                style: traits.userInterfaceStyle,
                contrast: traits.accessibilityContrast
            )
            let l = Self.luminance(r: c.r, g: c.g, b: c.b)
            return Self.usesDarkGlyph(luminance: l) ? UIColor(white: 0.12, alpha: 1) : .white
        })
    }

    /// Contrast ratio between the rendered swatch and the glyph drawn on it,
    /// for one trait combination.
    func glyphContrastRatio(
        style: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast
    ) -> Double {
        let c = resolvedComponents(style: style, contrast: contrast)
        let l = Self.luminance(r: c.r, g: c.g, b: c.b)
        let glyph = Self.usesDarkGlyph(luminance: l) ? 0.0144 : 1.0
        let hi = max(l, glyph)
        let lo = min(l, glyph)
        return (hi + 0.05) / (lo + 0.05)
    }

    var color: Color {
        Color(uiColor: UIColor { traits in
            let c = self.resolvedComponents(
                style: traits.userInterfaceStyle,
                contrast: traits.accessibilityContrast
            )
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
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
    /// Band boundaries come from `AdherenceBand` — the one source of truth.
    static func adherenceColor(percent: Int?) -> Color {
        guard let percent else { return .secondary }
        switch AdherenceBand.band(percent: percent) {
        case .excellent: return taken
        case .fair: return due
        case .offTrack: return missed
        }
    }

    /// Fixed-sRGB variant of the ramp for the printed report. The PDF is
    /// always ink on white paper, so it must not follow the device into dark
    /// mode — but it reads the same bands, so screen and paper never disagree.
    static func adherencePrintColor(percent: Int?) -> Color {
        guard let percent else { return Color.gray }
        switch AdherenceBand.band(percent: percent) {
        case .excellent: return Color(red: 0.2, green: 0.75, blue: 0.45)
        case .fair: return Color(red: 0.95, green: 0.62, blue: 0.15)
        case .offTrack: return Color(red: 0.9, green: 0.3, blue: 0.25)
        }
    }
}
