import Foundation

/// The physical form of a medication — pill, injection, liquid, and so on.
///
/// Form is identity, not decoration: it chooses the glyph on every tile, the
/// unit the supply counter speaks in ("3 puffs", not "3 pills"), and the
/// honesty of refill forecasting — an inhaler that "runs out Friday" means
/// something different from a pill box.
///
/// Stored raw so a future case can be added without a migration, and unknown
/// values — from newer builds, backups, or imports — fall back to `.pill`
/// rather than crashing a screen that only wanted an icon.
enum MedicationForm: String, CaseIterable, Identifiable, Sendable {
    case pill, capsule, liquid, drops, injection, inhaler, powder, patch, other

    var id: String { rawValue }

    static let `default` = MedicationForm.pill

    /// Tolerates empty (pre-V5 rows) and unknown values alike.
    static func named(_ raw: String) -> MedicationForm {
        MedicationForm(rawValue: raw) ?? .default
    }

    var displayName: String {
        switch self {
        case .pill: String(localized: "Pill", comment: "Medication form")
        case .capsule: String(localized: "Capsule", comment: "Medication form")
        case .liquid: String(localized: "Liquid", comment: "Medication form")
        case .drops: String(localized: "Drops", comment: "Medication form")
        case .injection: String(localized: "Injection", comment: "Medication form")
        case .inhaler: String(localized: "Inhaler", comment: "Medication form")
        case .powder: String(localized: "Powder", comment: "Medication form")
        case .patch: String(localized: "Patch", comment: "Medication form")
        case .other: String(localized: "Other", comment: "Medication form")
        }
    }

    /// SF Symbol for the tile glyph. Every name here is available on the
    /// deployment target — a symbol that doesn't exist renders as an empty
    /// tile with no warning, so these are pinned by `MedicationFormTests`.
    var systemImage: String {
        switch self {
        case .pill: "pill.fill"
        case .capsule: "capsule.fill"
        case .liquid: "waterbottle.fill"
        case .drops: "drop.fill"
        case .injection: "syringe.fill"
        case .inhaler: "inhaler.fill"
        case .powder: "bag.fill"
        case .patch: "bandage.fill"
        case .other: "cross.case.fill"
        }
    }

    /// The unit the supply counter and refill alerts count in.
    /// "2 puffs left" warns truthfully; "2 pills left" about an inhaler
    /// quietly teaches the user to distrust the number.
    func supplyUnit(count: Int) -> String {
        switch self {
        case .pill:
            count == 1 ? String(localized: "pill") : String(localized: "pills")
        case .capsule:
            count == 1 ? String(localized: "capsule") : String(localized: "capsules")
        case .liquid:
            String(localized: "mL")
        case .drops:
            count == 1 ? String(localized: "drop") : String(localized: "drops")
        case .injection:
            count == 1 ? String(localized: "dose") : String(localized: "doses")
        case .inhaler:
            count == 1 ? String(localized: "puff") : String(localized: "puffs")
        case .powder:
            count == 1 ? String(localized: "sachet") : String(localized: "sachets")
        case .patch:
            count == 1 ? String(localized: "patch") : String(localized: "patches")
        case .other:
            count == 1 ? String(localized: "dose") : String(localized: "doses")
        }
    }
}
