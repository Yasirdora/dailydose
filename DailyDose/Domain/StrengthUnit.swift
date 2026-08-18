import Foundation

/// The unit a strength is measured in — mg, mcg, g, mL, %, IU.
///
/// These six cover real prescriptions. `L` is bulk packaging, not a
/// strength, and offering µg next to mcg invites a dangerous slip — so the
/// list stays short on purpose. A wrong unit picked from a long dropdown is
/// worse than none at all.
///
/// Stored raw so a future unit can be added without a migration; unknown
/// values — newer builds, backups — read as unspecified, never as a crash.
enum StrengthUnit: String, CaseIterable, Identifiable, Sendable {
    case mg, mcg, g, mL, percent, iu

    var id: String { rawValue }

    /// Exactly as printed on the label: "mcg" not "µg", "mL" capitalised,
    /// "IU" all caps.
    var displayName: String {
        switch self {
        case .mg: "mg"
        case .mcg: "mcg"
        case .g: "g"
        case .mL: "mL"
        case .percent: "%"
        case .iu: "IU"
        }
    }

    /// Tolerant reader for every spelling a pharmacy label or an older
    /// backup might carry. Word-boundary matched by callers; the mapping
    /// itself is case-insensitive. Unknown spellings read as nil.
    static func named(_ raw: String) -> StrengthUnit? {
        switch raw.lowercased() {
        case "mg", "milligram", "milligrams": .mg
        case "mcg", "µg", "μg", "microgram", "micrograms": .mcg
        case "g", "gram", "grams": .g
        case "ml", "millilitre", "millilitres", "milliliter", "milliliters": .mL
        case "%", "percent": .percent
        case "iu": .iu
        default: nil
        }
    }
}
