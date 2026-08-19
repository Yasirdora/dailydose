import Testing
import UIKit
@testable import DailyDose

@Suite("Medication form")
struct MedicationFormTests {

    /// Rows written before V5 carry an empty raw value; rows from a newer
    /// build or an imported backup can carry one this build doesn't know.
    /// Both must read as *unspecified* — an honest "the user never said",
    /// never an assumed pill and never a crash on a screen that only
    /// wanted an icon.
    @Test("Empty and unknown raw values read as unspecified, not pill")
    func tolerantResolution() {
        let medication = Medication(name: "Metformin", schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1)))
        #expect(medication.formRaw == "")
        #expect(medication.form == nil)

        medication.formRaw = "suppository-9000"
        #expect(medication.form == nil)

        medication.form = .inhaler
        #expect(medication.formRaw == "inhaler")
        #expect(medication.form == .inhaler)

        medication.form = nil
        #expect(medication.formRaw == "")
    }

    /// The supply counter speaks in the form's own unit: "2 puffs left"
    /// warns truthfully where "2 pills left" about an inhaler would teach
    /// the user to distrust the number. An unspecified form counts in
    /// neutral doses, because guessing a unit would be a lie with a number
    /// in it.
    @Test("Supply units are form-aware and pluralise")
    func supplyUnits() {
        #expect(MedicationForm.pill.supplyUnit(count: 1) == "pill")
        #expect(MedicationForm.pill.supplyUnit(count: 2) == "pills")
        #expect(MedicationForm.inhaler.supplyUnit(count: 1) == "puff")
        #expect(MedicationForm.inhaler.supplyUnit(count: 200) == "puffs")
        #expect(MedicationForm.liquid.supplyUnit(count: 150) == "mL")
        #expect(MedicationForm.injection.supplyUnit(count: 1) == "dose")
        #expect(MedicationForm.supplyUnit(form: nil, count: 3) == "doses")
        // A tube is sold by weight and used by the smear. Counting it in
        // millilitres would attach a unit the pack never mentions to a number
        // the user never measured.
        #expect(MedicationForm.topical.supplyUnit(count: 1) == "application")
        #expect(MedicationForm.topical.supplyUnit(count: 4) == "applications")
        #expect(MedicationForm.topical.supplyUnit(count: 30) != "mL")
    }

    /// Cream, ointment, gel and lotion used to detect as `.liquid`, which put
    /// a water bottle on the tile and counted a 30 g tube in millilitres. In
    /// the FDA directory that is 16,610 products telling the same small lie.
    @Test("Topicals are their own form, not liquids")
    func topicalsAreNotLiquids() {
        #expect(MedicationForm.detect(in: "Hydrocortisone 1% cream") == .topical)
        #expect(MedicationForm.detect(in: "Fucidin ointment") == .topical)
        #expect(MedicationForm.detect(in: "Voltaren gel 2.32%") == .topical)
        #expect(MedicationForm.detect(in: "Calamine lotion") == .topical)
        #expect(MedicationForm.detect(in: "Lip balm") == .topical)

        // And the liquids they were confused with stay liquids.
        #expect(MedicationForm.detect(in: "Lactulose oral solution") == .liquid)
        #expect(MedicationForm.detect(in: "Amoxicillin suspension") == .liquid)
        #expect(MedicationForm.detect(in: "Nasal spray") == .liquid)
    }

    /// "gel" is a substring of "softgel", and a gel capsule is swallowed
    /// rather than rubbed in — so `.capsule` has to win. This is the trap the
    /// topical keywords introduced, pinned so a later reorder trips on it.
    @Test("A softgel is a capsule, not a cream")
    func gelSubstringDoesNotStealCapsules() {
        #expect(MedicationForm.detect(in: "Omega-3 softgel") == .capsule)
        #expect(MedicationForm.detect(in: "Vitamin D gelcap") == .capsule)
        #expect(MedicationForm.detect(in: "Ibuprofen liquid filled capsule") == .capsule)
        // Eye gel is still drops: `.drops` outranks both.
        #expect(MedicationForm.detect(in: "Carbomer eye gel drops") == .drops)
    }

    /// Detection fires only on words a label actually prints. The moment
    /// nothing certain is said, the answer is nil — "ask the user", never
    /// "assume pill".
    @Test("Form detection is confident or silent")
    func detection() {
        #expect(MedicationForm.detect(in: "METFORMIN HCL 500 MG TABLET") == .pill)
        #expect(MedicationForm.detect(in: "Amoxicillin 250mg capsules") == .capsule)
        #expect(MedicationForm.detect(in: "Ventolin inhaler 100 micrograms") == .inhaler)
        #expect(MedicationForm.detect(in: "Timolol eye drops 0.5%") == .drops)
        #expect(MedicationForm.detect(in: "Insulin glargine injection") == .injection)
        #expect(MedicationForm.detect(in: "Nicotine transdermal patch 21 mg") == .patch)
        #expect(MedicationForm.detect(in: "Lactulose oral solution") == .liquid)
        // Nothing declared → nothing guessed.
        #expect(MedicationForm.detect(in: "Metformin 500 mg") == nil)
        #expect(MedicationForm.detect(in: "") == nil)
        // The specific word wins over the general one.
        #expect(MedicationForm.detect(in: "ophthalmic drops solution") == .drops)
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
        // The neutral glyph for unspecified form is pinned too.
        #expect(UIImage(systemName: "cross.case.fill") != nil)
    }
}
