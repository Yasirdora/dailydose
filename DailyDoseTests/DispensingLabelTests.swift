import Testing
import Foundation
@testable import DailyDose

/// A real US pharmacy dispensing label, and the three faults it produced.
///
/// Transcribed from the label that failed on device. It is the fixture for all
/// of them, because they are not independent: the patient's name reached the
/// name field, a street address became a supply of 152, and the one number on
/// the label that *was* the dispensed count was ignored.
@Suite("Dispensing labels")
struct DispensingLabelTests {

    /// Line for line as printed, including the two-column rows — `Qty:90` and
    /// the prescriber's name share one, which is why a privacy rule that drops
    /// whole lines would also throw away the quantity.
    static let fixture = """
        AMBER SPECIALTY PHARMACY
        10004 S. 152nd St Omaha, NE 68138
        For refills call: (888) 370-1724
        Rx # 0010140712        Filled: 02/07/2018
                               Use By: 2/7/2019
        Jane Doe
        Tacrolimus 1mg Cap (ACC)
        Mfg: ACCORD HEALTHCARE
        Generic for: Prograf
        Take 1 capsule by mouth in the morning and
        2 capsules in the evening
        Qty:90    Physician: Test Doctor
        Orig Rx:02/07/2018   Refills: 7   Before 12/03/2018
        CAUTION: Federal Law PROHIBITS the transfer of this drug to
        any person other than the patient for whom it was prescribed.
        Pharmacist Kelli Wyant
        """

    // MARK: - 1. Nobody's name is ever captured

    /// The defect this suite exists for. `Jane Doe` reached the medication name
    /// field and would have been written to disk.
    ///
    /// `SCANNING-DESIGN.md` §5.4 has always required that patient and
    /// prescriber names are discarded at the region level, before any parsing,
    /// and never persisted, logged or exported. The assertion is deliberately
    /// total: **no** field of the result may contain any of these strings,
    /// rather than checking the one field that happened to leak.
    @Test("No person's name and no prescription number reaches any field")
    func nobodysName() {
        let result = LabelScanParser.read(Self.fixture)
        let fields = [result.name, result.strength]
        let forbidden = ["Jane", "Doe", "Kelli", "Wyant", "Test Doctor", "0010140712"]

        for field in fields {
            for secret in forbidden {
                #expect(
                    !field.localizedCaseInsensitiveContains(secret),
                    "\"\(secret)\" reached a saved field: \"\(field)\""
                )
            }
        }
    }

    /// And it never enters a candidate list in the first place — a filter on
    /// the *winner* would mean the patient's name had already competed for the
    /// field and merely lost.
    @Test("Private lines are gone before anything is ranked")
    func redactedBeforeRanking() {
        let visible = DispensingLabel.redacted(Self.fixture.components(separatedBy: .newlines))
        let joined = visible.joined(separator: "\n")
        for secret in ["Jane Doe", "Kelli Wyant", "Test Doctor", "0010140712", "Rx #"] {
            #expect(
                !joined.localizedCaseInsensitiveContains(secret),
                "\"\(secret)\" survived redaction"
            )
        }
    }

    /// A label packs two columns onto one printed line. Dropping the whole line
    /// on sight of `Physician:` would take the dispensed quantity with it, so
    /// person markers truncate and record markers drop.
    @Test("Truncating at a person marker keeps what shares the line")
    func twoColumnLineKeepsItsQuantity() {
        let visible = DispensingLabel.redacted(["Qty:90    Physician: Test Doctor"])
        #expect(visible == ["Qty:90"])
    }

    @Test("A line that is only a dispensing record goes entirely", arguments: [
        "Rx # 0010140712        Filled: 02/07/2018",
        "Use By: 2/7/2019",
        "Orig Rx:02/07/2018   Refills: 7   Before 12/03/2018",
        "For refills call: (888) 370-1724",
        "Pharmacist Kelli Wyant",
    ])
    func recordLinesAreDropped(line: String) {
        #expect(DispensingLabel.redacted([line]).isEmpty)
    }

    /// `DR` is delayed release, and a bare "dr" marker would truncate the line
    /// at it and take the strength with it.
    @Test("A delayed-release abbreviation is not a doctor")
    func delayedReleaseSurvives() {
        #expect(DispensingLabel.redacted(["Doxycycline DR 100mg"]) == ["Doxycycline DR 100mg"])
        #expect(DispensingLabel.redacted(["Metformin ER 500mg  Dr. Alice Brown"]) == ["Metformin ER 500mg"])
    }

    /// The scanner does not hand text over one line at a time — it groups by
    /// proximity, so a label's left column can arrive as one item spanning
    /// three printed lines, and a line with a wide gap can arrive as two.
    /// Geometry puts them back, because both the privacy rules and the
    /// quantity rules are positional.
    @Test("Fragments are rebuilt into printed lines by position")
    func linesAreRebuiltFromGeometry() {
        let fragments = [
            // Out of order on purpose: callback order means nothing.
            ScannedFragment(text: "Physician: Test Doctor", height: 10, verticalCenter: 200, left: 180),
            ScannedFragment(text: "Tacrolimus 1mg Cap", height: 14, verticalCenter: 100, left: 20),
            ScannedFragment(text: "Qty:90", height: 10, verticalCenter: 202, left: 20),
        ]
        #expect(ScannedFragment.lines(from: fragments) == [
            "Tacrolimus 1mg Cap",
            "Qty:90 Physician: Test Doctor",
        ])
    }

    /// A fragment that already carries newlines keeps them: a break the scanner
    /// stated is better evidence than one we inferred.
    @Test("Newlines inside one fragment are believed")
    func newlinesWithinAFragmentSurvive() {
        let fragments = [
            ScannedFragment(text: "Ibuprofen AL 400\nFilmtabletten", height: 12, verticalCenter: 100, left: 20),
            ScannedFragment(text: "20 Filmtabletten", height: 10, verticalCenter: 140, left: 20),
        ]
        #expect(ScannedFragment.lines(from: fragments) == [
            "Ibuprofen AL 400", "Filmtabletten", "20 Filmtabletten",
        ])
    }

    // MARK: - 2. A street address is not a quantity

    /// `152` came from `10004 S. 152nd St Omaha` — the German `St` (*Stück*)
    /// matched the end of a US street address and reported a supply of 152.
    @Test("152nd St yields no quantity")
    func streetAddressIsNotAQuantity() {
        #expect(PackQuantity.read("10004 S. 152nd St Omaha, NE 68138") == nil)
        // And not in the label's own company either, where the surrounding
        // English is what shuts the German entry off.
        #expect(PackQuantity.read(Self.fixture)?.count != 152)
    }

    /// The general fix, of which `St` was only the first instance. A gated
    /// entry matches in its own language and nowhere else.
    @Test("Gated entries match only in their own language")
    func languageGating() {
        // German context: "St" means Stück.
        #expect(PackQuantity.read("Ibuprofen AL 400\nFilmtabletten\n100 St.")?.count == 100)
        // English context: it is a street.
        #expect(PackQuantity.read("Take 2 tablets daily\n100 S. 152nd St")?.count != 100)
        // No context at all: refused rather than guessed.
        #expect(PackQuantity.read("100 St.") == nil)
    }

    @Test("The recogniser reads the language off the pharmacy words", arguments: [
        ("Ibuprofen 400 mg Filmtabletten 20 St. Apothekenpflichtig", CartonLanguage.german),
        ("Take 1 capsule by mouth daily Qty: 30 Refills: 2", .english),
        ("Doliprane 500 mg comprimés pelliculés Boîte de 16", .french),
        ("Ibuprofeno 600 mg comprimidos recubiertos Prospecto", .spanish),
        ("10004 S. 152nd St Omaha, NE 68138", nil),
    ])
    func languageRecognition(vector: (text: String, language: CartonLanguage?)) {
        #expect(CartonLanguageRecognizer.language(of: vector.text) == vector.language)
    }

    /// Tapping a fragment names its own winner and skips ranking entirely, so
    /// every rule ranking enforces has to hold here too. Without this, a tap on
    /// the patient's name put it straight into the field that all the ranking
    /// work exists to keep it out of.
    @Test("A tap cannot pick what ranking would have refused")
    func tappingObeysTheSameRules() {
        // On a dispensing label, only a line stating a strength may be picked.
        #expect(RecognizedTextStore.pickable("Jane Doe", isDispensingLabel: true) == nil)
        #expect(RecognizedTextStore.pickable("Pharmacist Kelli Wyant", isDispensingLabel: true) == nil)
        #expect(RecognizedTextStore.pickable("Rx # 0010140712", isDispensingLabel: true) == nil)
        #expect(RecognizedTextStore.pickable("Tacrolimus 1mg Cap", isDispensingLabel: true) != nil)

        // On a carton there is no patient, so a tap stays free — that is how
        // someone corrects a name the ranking got wrong.
        #expect(RecognizedTextStore.pickable("Ibuprofen AL", isDispensingLabel: false) != nil)
        // Except for the records, which are never a medicine anywhere.
        #expect(RecognizedTextStore.pickable("Rx # 0010140712", isDispensingLabel: false) == nil)
    }

    // MARK: - 3. A dispensing label is a different document

    @Test("The label is recognised as one, and a carton is not")
    func documentType() {
        #expect(DispensingLabel.isDispensingLabel(Self.fixture.components(separatedBy: .newlines)))
        #expect(!DispensingLabel.isDispensingLabel([
            "Ibuprofen AL 400", "Filmtabletten", "20 Filmtabletten N1", "Apothekenpflichtig",
        ]))
    }

    /// `Qty` is noun-then-number and often has no space — `Qty:90` — and it is
    /// the authoritative figure. The label also carries "Take 1 capsule … and
    /// 2 capsules", so three numbers sit next to counting nouns and only one is
    /// the dispensed count. Largest does not decide this; the marker does.
    @Test("Qty outranks every other candidate on the label")
    func qtyIsAuthoritative() {
        #expect(PackQuantity.read(Self.fixture)?.count == 90)
        #expect(PackQuantity.read(Self.fixture)?.isStated == true)
    }

    @Test("Qty is read however it is punctuated", arguments: [
        "Qty:90", "Qty: 90", "QTY 90", "Quantity 90", "Qty:  90",
    ])
    func qtyPunctuation(text: String) {
        #expect(PackQuantity.read("Take 1 capsule daily\n\(text)")?.count == 90)
    }

    @Test("And in the other languages that mark it")
    func qtyElsewhere() {
        #expect(PackQuantity.read("Filmtabletten Menge: 30")?.count == 30)
        #expect(PackQuantity.read("Filmtabletten Anzahl 30")?.count == 30)
    }

    /// A marked quantity beats a larger unmarked one — which is exactly the
    /// case largest-wins gets wrong.
    @Test("A stated quantity beats a larger read one")
    func statedBeatsLarger() {
        let reading = PackQuantity.read("Take 2 tablets daily\nQty: 30\n500 tablets per case")
        #expect(reading?.count == 30)
    }

    /// The label rules must not reach a carton. A carton has no patient, no
    /// prescriber and no `Qty` marker, its name *is* its largest text, and the
    /// line above the drug is very often the brand — which the patient-name
    /// rule would delete on sight if it ever fired here.
    @Test("A carton is read as a carton")
    func cartonIsNotALabel() {
        let carton = """
            Ibuprofen AL 400
            Filmtabletten
            20 Filmtabletten N1
            Apothekenpflichtig
            """
        #expect(!DispensingLabel.isDispensingLabel(carton.components(separatedBy: .newlines)))
        #expect(DispensingLabel.redacted(carton.components(separatedBy: .newlines)).count == 4)

        let result = LabelScanParser.read(carton)
        // "Al" rather than "AL": `prettifyName` preserves clinical
        // abbreviations (HCL, ER, XR), and a manufacturer's initials are not
        // one. Pre-existing, and pinned here rather than quietly special-cased.
        #expect(result.name == "Ibuprofen Al 400")
        #expect(result.quantity == 20)
        #expect(result.detectedForm == .pill)
    }

    // MARK: - The whole label, end to end

    @Test("The fixture reads as the medicine and nothing else")
    func endToEnd() {
        let result = LabelScanParser.read(Self.fixture)
        #expect(result.name == "Tacrolimus")
        #expect(result.strengthAmount == 1)
        #expect(result.strengthUnit == .mg)
        #expect(result.detectedForm == .capsule)
        #expect(result.quantity == 90)
    }

    /// The name comes from the drug line and nowhere else. On a carton the
    /// largest text is the medicine; on a label it is very often the patient.
    @Test("The drug line is the only name source")
    func drugLineIsTheNameSource() {
        let visible = DispensingLabel.redacted(Self.fixture.components(separatedBy: .newlines))
        #expect(DispensingLabel.drugLine(in: visible) == "Tacrolimus 1mg Cap (ACC)")
    }

    // MARK: - 5. The count is an observation, the toggle is a preference

    /// Reported: scanning with tracking off lost the number, and switching
    /// tracking on afterwards started from an empty field.
    @Test("A count captured with tracking off is not thrown away")
    func countSurvivesTrackingOff() {
        var draft = MedicationDraft()
        draft.apply(LabelScanParser.read(Self.fixture))
        #expect(draft.pillsRemaining == 90)

        // The user does not want warnings. The number is still theirs.
        draft.tracksSupply = false
        #expect(draft.resolvedPills == 90, "the count is an observation, not a preference")
        #expect(draft.resolvedThreshold == nil, "the warning level is the preference")
        #expect(draft.hasSupplyCount)
        // And asking for no warnings is not a validation failure.
        #expect(!draft.isMissingSupplyCount)
        #expect(draft.blockingReason == nil)
    }

    /// Switching tracking on later reveals what was already captured, rather
    /// than presenting an empty field.
    @Test("Switching tracking on reveals the captured number")
    func togglingOnRevealsTheCount() {
        var draft = MedicationDraft()
        draft.tracksSupply = false
        draft.apply(LabelScanParser.read(Self.fixture))
        draft.tracksSupply = true
        #expect(draft.pillsRemaining == 90)
        #expect(!draft.isMissingSupplyCount)
    }

    /// But wanting warnings with nothing ever captured or typed still blocks.
    ///
    /// Silently, by design: the count blocks Save through `isValid` and no
    /// longer contributes a sentence to `blockingReason`.
    @Test("Tracking on with nothing captured still blocks Save")
    func trackingWithNoCountStillBlocks() {
        var draft = MedicationDraft()
        draft.name = "Metformin"
        draft.tracksSupply = true
        #expect(draft.isMissingSupplyCount)
        #expect(!draft.isValid)
        #expect(draft.blockingReason == nil, "it blocks without a sentence")
    }
}
