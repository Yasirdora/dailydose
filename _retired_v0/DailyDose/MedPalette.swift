import SwiftUI
import UIKit

/// Shared color helpers — the house accent plus Apple Health's 12 medication colors.
/// Every palette color is dynamic: deep and saturated in light mode, lifted toward
/// white in dark mode so it stays luminous on black (the way Apple Health brightens
/// its colors at night).
enum MedPalette {
    /// Apple Health's medication palette, in the order Health presents it.
    static let names = ["navy", "charcoal", "yellow", "coral", "olive", "mint",
                        "sky", "purple", "mauve", "pink", "red", "brown"]

    private static let light: [String: (CGFloat, CGFloat, CGFloat)] = [
        // Sampled pixel-for-pixel from Apple Health's color picker.
        "navy":     (0.314, 0.506, 0.647),
        "charcoal": (0.376, 0.373, 0.384),
        "yellow":   (0.965, 0.808, 0.275),
        "coral":    (0.933, 0.545, 0.424),
        "olive":    (0.690, 0.749, 0.408),
        "mint":     (0.510, 0.867, 0.675),
        "sky":      (0.525, 0.757, 0.918),
        "purple":   (0.576, 0.392, 0.867),
        "mauve":    (0.600, 0.498, 0.667),
        "pink":     (0.929, 0.467, 0.639),
        "red":      (0.757, 0.267, 0.216),
        "brown":    (0.851, 0.745, 0.620),
    ]

    /// Older builds stored these color keys — map them onto the new palette
    /// so existing meds keep a sensible color.
    private static let legacy: [String: String] = [
        "teal": "accent", "blue": "navy", "plum": "red", "amber": "brown",
        "purple": "purple", "green": "mint", "red": "red", "gray": "charcoal"
    ]

    static func color(for name: String) -> Color {
        Color(uiColor: UIColor { traits in
            let base = lightRGB(for: name)
            let rgb = traits.userInterfaceStyle == .dark ? lifted(base) : base
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }

    /// The house accent — Kimi smiley blue #027AFF.
    static var accent: Color { color(for: "accent") }

    private static func lightRGB(for name: String) -> (CGFloat, CGFloat, CGFloat) {
        if name == "accent" { return (0.01, 0.48, 1.00) }
        if let rgb = light[name] { return rgb }
        if let mapped = legacy[name] { return lightRGB(for: mapped) }
        return (0.01, 0.48, 1.00) // unknown key → house blue
    }

    private static func lifted(_ rgb: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
        (rgb.0 + (1 - rgb.0) * 0.12,
         rgb.1 + (1 - rgb.1) * 0.12,
         rgb.2 + (1 - rgb.2) * 0.12)
    }
}
