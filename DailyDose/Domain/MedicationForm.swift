import Foundation

/// The physical form of a medication — pill, injection, liquid, and so on.
///
/// Form is identity, not decoration: it chooses the glyph on every tile, the
/// unit the supply counter speaks in ("3 puffs", not "3 pills"), and the
/// honesty of refill forecasting — an inhaler that "runs out Friday" means
/// something different from a pill box.
///
/// Form is *optional* and there is no silent default: an empty raw value
/// means "the user never said", and the UI shows a neutral medical glyph
/// rather than claiming pill. Auto-detection (`detect(in:)`) only fires on
/// words a label actually prints — "tablets", "inhaler" — and even then the
/// user sees and can change the result.
///
/// Stored raw so a future case can be added without a migration, and unknown
/// values — from newer builds, backups, or imports — read as unspecified
/// rather than crashing a screen that only wanted an icon.
enum MedicationForm: String, CaseIterable, Identifiable, Sendable {
    case pill, capsule, liquid, topical, drops, injection, inhaler, powder, patch, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pill: String(localized: "Pill", comment: "Medication form")
        case .capsule: String(localized: "Capsule", comment: "Medication form")
        case .liquid: String(localized: "Liquid", comment: "Medication form")
        // Names the two words a box is most likely to print, because someone
        // holding a tube of Voltaren should not have to decide whether "gel"
        // counts as a cream. "Topical" is the accurate word and the wrong one:
        // it is the term a pharmacist uses, not the one on the label.
        case .topical: String(localized: "Cream or ointment", comment: "Medication form")
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
        // Interim. SF Symbols has no tube, jar or ointment glyph — the whole
        // catalogue was searched — and every alternative either collides with
        // a form already here (`drop.fill` is drops, `bandage.fill` is patch)
        // or is not available filled. A brush at least says *applied to a
        // surface*, which is the one thing every topical has in common. A
        // custom symbol drawn in the SF Symbols app is the real answer; this
        // is what ships until someone draws it.
        case .topical: "paintbrush.fill"
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
        case .topical:
            // Not mL. A tube is sold by weight and used by the smear, so
            // millilitres would be a unit the pack never mentions attached to
            // a number the user never measured.
            count == 1 ? String(localized: "application") : String(localized: "applications")
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

    /// The unit for a medication whose form is unspecified: the neutral
    /// "dose(s)", because guessing a unit would be a lie with a number in it.
    static func supplyUnit(form: MedicationForm?, count: Int) -> String {
        (form ?? .other).supplyUnit(count: count)
    }

    /// Detects the form from words a pharmacy label actually prints.
    ///
    /// Deliberately conservative: it only fires on explicit form words
    /// ("tablets", "inhaler", "eye drops") and returns nil the moment nothing
    /// certain is said. A nil here means "ask the user" — never "assume pill".
    ///
    /// The words themselves live in ``PackagingLexicon``, not here, and that is
    /// the point: the same table decides what "30 Filmtabletten" *counts*, so a
    /// carton can never be read as thirty pills and pictured as a bottle. The
    /// old private list here matched with `contains`, which found "gel" inside
    /// "softgel" and "drop" inside anything; the lexicon matches whole printed
    /// words, and compounds only where a word is long enough for that to be
    /// safe.
    static func detect(in text: String) -> MedicationForm? {
        PackagingLexicon.form(in: text)
    }
}
