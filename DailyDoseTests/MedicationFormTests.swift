import Testing
import UIKit
@testable import DailyDose

@Suite("Medication form")
struct MedicationFormTests {

    /// Rows written before V5 carry an empty raw value; rows from a newer
    /// build or an imported backup can carry one this build doesn't know.
    /// Both must read as the default form — a screen that only wanted an
    /// icon is never a place for a crash.
    @Test("Empty and unknown raw values resolve to the default form")
    func tolerantResolution() {
        #expect(MedicationForm.named("") == .pill)
        #expect(MedicationForm.named("suppository-9000") == .pill)
        #expect(MedicationForm.named("inhaler") == .inhaler)
        #expect(MedicationForm.default == .pill)
    }

    /// The supply counter speaks in the form's own unit: "2 puffs left"
    /// warns truthfully where "2 pills left" about an inhaler would teach
    /// the user to distrust the number.
    @Test("Supply units are form-aware and pluralise")
    func supplyUnits() {
        #expect(MedicationForm.pill.supplyUnit(count: 1) == "pill")
        #expect(MedicationForm.pill.supplyUnit(count: 2) == "pills")
        #expect(MedicationForm.inhaler.supplyUnit(count: 1) == "puff")
        #expect(MedicationForm.inhaler.supplyUnit(count: 200) == "puffs")
        #expect(MedicationForm.liquid.supplyUnit(count: 150) == "mL")
        #expect(MedicationForm.injection.supplyUnit(count: 1) == "dose")
    }

    /// A symbol name that doesn't exist renders as an empty tile with no
    /// compiler warning — so the existence of every glyph is pinned here.
    @Test("Every form glyph exists on this platform")
    func glyphsExist() {
        for form in MedicationForm.allCases {
            #expect(
                UIImage(systemName: form.systemImage) != nil,
                "\(form.rawValue) names a symbol that does not exist: \(form.systemImage)"
            )
        }
    }
}
