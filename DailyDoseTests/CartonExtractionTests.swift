import Testing
import Foundation
@testable import DailyDose

/// What a medicine carton says, and what the app is allowed to conclude.
///
/// Every vector here is pure text. That is the point: the lexicon is assembled
/// from knowledge of European and US packaging rather than from photographs of
/// real packs, so the one thing that can be pinned without a camera is what the
/// rules do with a given string — and those rules must be extendable by adding
/// rows rather than rewriting logic.
@Suite("Carton extraction")
struct CartonExtractionTests {

    // MARK: - Quantity, one vector per language

    /// The counting noun is the same token that names the form, so a pack read
    /// as thirty is a pack pictured as thirty *pills*.
    @Test("A count and a form come out of one printed word", arguments: [
        ("30 Filmtabletten", 30, MedicationForm.pill),          // German
        ("90 TABLETS", 90, .pill),                              // English
        ("20 comprimés", 20, .pill),                            // French
        ("28 cápsulas", 28, .capsule),                          // Spanish
        ("14 compresse", 14, .pill),                            // Italian
        ("10 zakjes", 10, .powder),                             // Dutch
        ("12 saquetas", 12, .powder),                           // Portuguese
        ("20 tabletki", 20, .pill),                             // Polish
        ("100 tabletter", 100, .pill),                          // Swedish / Danish / Norwegian
        ("30 kapsler", 30, .capsule),                           // Danish / Norwegian
        ("30 tablettia", 30, .pill),                            // Finnish (partitive)
        // German abbreviations are language-gated — "St" is also the end of
        // every US street address — so these carry the German word that
        // identifies the label, as a real carton does.
        ("Dosieraerosol Apothekenpflichtig 200 Hub", 200, .inhaler),
        ("20 Beutel", 20, .powder),                             // German, sachets
        // "St." counts and says nothing about form; "Filmtabletten" is what
        // names it. The reading takes the form of the noun it counted, so nil
        // here is the right answer and not a gap.
        ("Filmtabletten 100 St.", 100, nil),
        ("Qty 60", 60, nil),                                    // noun first, number after
        ("Tabletten 30", 30, .pill),                            // trailing number
    ])
    func countAndFormAgree(vector: (text: String, count: Int, form: MedicationForm?)) {
        let reading = PackQuantity.read(vector.text)
        #expect(reading?.count == vector.count, "count from \(vector.text)")
        #expect(reading?.form == vector.form, "form from \(vector.text)")
        // The same word, read by the other half of the app, says the same
        // thing. One table is what guarantees it.
        if let form = vector.form {
            #expect(MedicationForm.detect(in: vector.text) == form)
        }
    }

    /// A blister pack states the strip and the number of strips. Neither alone
    /// is what is in the box, and the strip size is the tempting wrong answer
    /// because it is the number nearest the noun.
    @Test("Blister packs multiply", arguments: ["3 x 10 Tabletten", "3 × 10 Tabletten", "3X10 Tabletten"])
    func blisterPacks(text: String) {
        #expect(PackQuantity.read(text)?.count == 30)
    }

    // MARK: - The refusals

    /// German *Normgrößen* are package **size classes**, not counts: N1 is
    /// twenty tablets for one medicine and ten for another, and the mapping
    /// lives in a reference table this app does not carry. Reading the digit
    /// would produce a supply of one, two or three on a full box — and the
    /// refill warning is built on that number, so an invented one is worse
    /// than a blank field.
    @Test("N1, N2 and N3 never become a number", arguments: [
        "Ibuprofen 400 mg N1", "Ibuprofen 400 mg N2", "Ibuprofen 400 mg N3",
        "N1", "N2 Filmtabletten",
    ])
    func normgroessen(text: String) {
        #expect(PackQuantity.read(text) == nil)
    }

    /// And a size class next to a real count does not suppress it.
    @Test("A real count still reads with a size class beside it")
    func normgroesseDoesNotBlockARealCount() {
        #expect(PackQuantity.read("Ibuprofen 600 mg Filmtabletten N2 50 St.")?.count == 50)
    }

    /// A strength and a quantity are different token classes and separate
    /// cleanly — except backwards. "Tabletten 500 mg" puts a counting noun in
    /// front of a strength, and the trailing-number rule would read the
    /// strength as a pack of five hundred if the strength were not excluded
    /// before any noun is looked at.
    @Test("A strength is never a quantity", arguments: [
        "500 mg", "Metformin 500 mg", "Tabletten 500 mg", "Insulin 100 units/ml",
        "Hydrocortisone 1% cream 30 g",
    ])
    func strengthIsNotQuantity(text: String) {
        #expect(PackQuantity.read(text) == nil)
    }

    @Test("Both come out of one carton when both are printed")
    func strengthAndQuantityTogether() {
        let result = LabelScanParser.parse("Metformin 500 mg 30 Tabletten")
        #expect(result.strengthAmount == 500)
        #expect(result.strengthUnit == .mg)
        #expect(result.quantity == 30)
        #expect(result.detectedForm == .pill)
    }

    /// A lot number, a phone fragment or a misread can sit next to a counting
    /// noun and look exactly like a count.
    @Test("Implausible counts are refused", arguments: [
        "0 tablets", "9999 tablets", "-5 tablets", "1234567890 tablets",
        "99999999999999999999 tablets", "2.5 ml",
    ])
    func implausibleCounts(text: String) {
        #expect(PackQuantity.read(text) == nil)
    }

    /// "60 metered doses" is a pack size; "2 doses daily" is a direction, and
    /// this app does not read directions. A floor cannot tell those apart
    /// perfectly, but it keeps the harmful reading — a supply of two, which
    /// fires a refill warning on a full box — off the common case.
    @Test("A tiny dose count reads as a direction, not a pack size")
    func doseFloor() {
        #expect(PackQuantity.read("Take 2 doses daily") == nil)
        #expect(PackQuantity.read("60 metered doses")?.count == 60)
    }

    // MARK: - The millilitre rule

    /// On a liquid the pack size genuinely is a volume, so `ml` has to be
    /// readable as a quantity — but "500 mg / 5 ml" prints a millilitre figure
    /// that is part of the strength, and "20 ml" alone could be either. A
    /// volume is believed only when nothing else was countable and the carton
    /// stated a strength somewhere else.
    @Test("A bare volume is not a pack size")
    func volumeAlone() {
        #expect(PackQuantity.read("20 ml") == nil)
        #expect(PackQuantity.read("Saline 20 ml") == nil)
    }

    @Test("A volume beside a strength is a pack size")
    func volumeWithStrength() {
        let reading = PackQuantity.read("Paracetamol 120 mg/5 ml Suspension 100 ml")
        #expect(reading?.count == 100)
        #expect(reading?.form == .liquid)
    }

    @Test("Anything countable beats a volume")
    func countableBeatsVolume() {
        #expect(PackQuantity.read("Amoxicillin 250 mg 21 capsules 20 ml")?.count == 21)
    }

    // MARK: - Folding

    /// `KAPSELN`, `kapseln` and `Kapseln` are one word; so are `cápsulas` and
    /// `capsulas`. Polish `ł` carries a stroke rather than a combining mark, so
    /// Unicode diacritic folding leaves it alone — which is fine until an OCR
    /// reads it as a plain `l`, and then nothing matches at all.
    @Test("Case and diacritics do not change the reading", arguments: [
        "30 KAPSELN", "30 Kapseln", "30 kapseln",
        "30 cápsulas", "30 CÁPSULAS", "30 capsulas",
        "30 Kapsułki", "30 KAPSUŁKI", "30 kapsulki",
    ])
    func folding(text: String) {
        let reading = PackQuantity.read(text)
        #expect(reading?.count == 30, "count from \(text)")
        #expect(reading?.form == .capsule, "form from \(text)")
    }

    // MARK: - Form detection

    /// The old detector matched with `contains`, so "gel" was found inside
    /// "softgel" and a swallowed capsule detected as a cream. Whole-word
    /// matching is the fix; compound matching is allowed only for words long
    /// enough that a longer word ending in them is unlikely to be unrelated.
    @Test("A form word is a word, not a substring")
    func wordBoundaries() {
        #expect(MedicationForm.detect(in: "Omega-3 softgel") == .capsule)
        #expect(MedicationForm.detect(in: "Voltaren gel") == .topical)
        // Short words that end other words, and used to match inside them.
        #expect(MedicationForm.detect(in: "Dispatch note") == nil)
        #expect(MedicationForm.detect(in: "A trivial matter") == nil)
        #expect(PackQuantity.read("30 product") == nil)
        #expect(PackQuantity.read("30 test") == nil)
    }

    /// German compounds put the head noun last, so a suffix match reads them
    /// without the table having to enumerate every prefix.
    @Test("German compounds resolve to their head noun", arguments: [
        "Filmtabletten", "Brausetabletten", "Kautabletten", "Retardtabletten",
    ])
    func germanCompounds(word: String) {
        #expect(MedicationForm.detect(in: "Ibuprofen 400 mg \(word)") == .pill)
    }

    @Test("Hard capsules and soft capsules are both capsules")
    func germanCapsules() {
        #expect(MedicationForm.detect(in: "60 Hartkapseln") == .capsule)
        #expect(MedicationForm.detect(in: "60 Weichkapseln") == .capsule)
    }

    // MARK: - The lexicon's own invariants

    /// Suffix matching on a short word is how "gel" got found inside
    /// "softgel". Any row added below the floor reopens that bug, so the floor
    /// is asserted rather than trusted.
    @Test("Every compound entry clears the length floor")
    func compoundFloor() {
        for term in PackagingLexicon.terms where term.matching == .compound {
            #expect(
                term.word.count >= PackagingLexicon.minimumCompoundLength,
                "\(term.word) is too short to be matched as a suffix"
            )
        }
    }

    /// A row that names no form and counts nothing is dead weight that reads
    /// like a rule.
    @Test("Every entry earns its row")
    func noDeadRows() {
        for term in PackagingLexicon.terms {
            #expect(term.form != nil || term.counts, "\(term.word) says nothing")
            #expect(term.word == CartonText.fold(term.word), "\(term.word) is not folded")
        }
    }

    /// Words genuinely repeat across the languages in the table — Italian
    /// "capsule" is English "capsules"' singular, Dutch "tablet" is English
    /// "tablet". The build keeps the first spelling of a repeated word, so
    /// these are pinned to catch a future row that disagrees with an existing
    /// one and is then silently dropped.
    @Test("Words shared between languages agree", arguments: [
        ("capsule", MedicationForm.capsule), ("capsules", .capsule),
        ("tablet", .pill), ("tabletten", .pill), ("sachet", .powder),
        ("ampoule", .injection), ("patch", .patch), ("spray", .liquid),
    ])
    func sharedWords(entry: (word: String, form: MedicationForm)) {
        #expect(PackagingLexicon.term(for: entry.word)?.form == entry.form)
    }

    /// Longest match wins, so the specific word beats the general one whatever
    /// order the table happens to be written in.
    @Test("The most specific word wins")
    func longestMatchWins() {
        #expect(PackagingLexicon.term(for: "softgel")?.form == .capsule)
        #expect(PackagingLexicon.term(for: "gel")?.form == .topical)
        #expect(PackagingLexicon.term(for: "hartkapseln")?.form == .capsule)
    }

    // MARK: - Name extraction

    /// The medication's name is almost always the largest text on a carton.
    /// Ranking by string length instead preferred whichever line had the most
    /// characters — the ingredients sentence, the address, the storage note.
    @Test("The name is the tallest text, not the longest")
    func nameRanksByHeight() {
        let fragments = [
            ScannedFragment(text: "Metformin", height: 44),
            ScannedFragment(text: "Each film-coated tablet contains metformin hydrochloride", height: 7),
        ]
        #expect(ScannedFragment.nameCandidate(among: fragments) == "Metformin")
    }

    /// But the biggest words on a box are not always the medicine, and a wrong
    /// name pre-filled is a trap the user saves without re-reading.
    @Test("Boilerplate set in display type still loses")
    func nameRejectsBoilerplate() {
        let fragments = [
            ScannedFragment(text: "GEBRAUCHSINFORMATION", height: 60),
            ScannedFragment(text: "Ibuprofen", height: 30),
            ScannedFragment(text: "Pharmazeutischer Unternehmer: Musterfirma GmbH", height: 6),
        ]
        #expect(ScannedFragment.nameCandidate(among: fragments) == "Ibuprofen")
    }

    @Test("Known non-names are refused", arguments: [
        "Gebrauchsinformation", "Packungsbeilage", "Beipackzettel",
        "Rezeptpflichtig", "verschreibungspflichtig", "Apothekenpflichtig",
        "LOT 24B117", "EXP 03/2027", "MFG 01/2026", "Ch.-B.: 24B117",
        "Verw. bis: 03/2027", "Keep out of reach of children",
        "Store below 25°C", "12345678", "— / —",
    ])
    func rejectedNames(text: String) {
        #expect(!LabelScanParser.couldBeName(text))
        #expect(LabelScanParser.parse(text).name.isEmpty)
    }

    /// The rejection list is vocabulary, and vocabulary over-reaches. These are
    /// real product names that contain a rejected word or look like one.
    @Test("Real names survive the rejection list", arguments: [
        "Sterile Water for Injection", "Lotensin", "Exparel", "Batchelor's",
        "Metformin HCL", "Ventolin Evohaler",
    ])
    func namesSurvive(text: String) {
        #expect(LabelScanParser.couldBeName(text))
    }

    // MARK: - End to end

    /// The bug this brief was written about: a scan filled the name and the
    /// strength and left Form on "Choose" and Supply empty — because the parser
    /// only ever saw the one fragment the shutter caught, and a carton does not
    /// print its facts on one line.
    @Test("The rest of the carton is what fills Form and Supply")
    func contextFillsFormAndSupply() {
        let alone = LabelScanParser.parse("Ibuprofen 400 mg")
        #expect(alone.detectedForm == nil)
        #expect(alone.quantity == nil)

        let inContext = LabelScanParser.parse(
            "Ibuprofen 400 mg", context: "Filmtabletten N2 50 St."
        )
        #expect(inContext.name == "Ibuprofen")
        #expect(inContext.strengthAmount == 400)
        #expect(inContext.detectedForm == .pill)
        #expect(inContext.quantity == 50)
    }

    /// German brands print the strength in the product's own name and leave
    /// the unit off — "Ibuprofen AL 400", "Aspirin 500", "Paracetamol 500" —
    /// and set the dosage form on the line beneath. Flatten those two lines and
    /// the strength reads as a pack of four hundred, which then *beats* the
    /// real count further down the box, because the larger count wins.
    ///
    /// A pack quantity and the noun it counts are printed together. That is the
    /// whole rule, and it is why ``CartonText/Token/lineBreak`` exists.
    @Test("A strength on the line above is not a count")
    func strengthOnTheLineAbove() {
        let carton = "Ibuprofen AL 400\nFilmtabletten\n20 Filmtabletten N1"
        #expect(PackQuantity.read(carton)?.count == 20)

        // Same words, one line: now there is nothing to tell them apart, and
        // the reading changes. Pinned so the dependence is visible rather than
        // discovered.
        #expect(PackQuantity.read("Ibuprofen AL 400 Filmtabletten")?.count == 400)
    }

    /// Whole cartons, as the OCR would hand them over: several fragments, the
    /// name on one line and the count on another, with the legal small print
    /// in between. Assembled from knowledge of what these packs print rather
    /// than from photographs of them — which is exactly why they are pinned,
    /// so a future correction from a real pack changes a test rather than
    /// silently changing behaviour.
    @Test("Realistic cartons", arguments: [(text: String, count: Int?, form: MedicationForm?)]([
        (
            "METFORMIN HCl 500 mg\n100 TABLETS\nRx only\nStore below 25°C",
            100, .pill
        ),
        (
            "Ventolin HFA\nalbuterol sulfate\ninhalation aerosol\n200 metered actuations",
            200, .inhaler
        ),
        (
            "Ibuprofen AL 400\nFilmtabletten\n20 Filmtabletten N1\nApothekenpflichtig",
            20, .pill
        ),
        (
            "Amoxicilline 500 mg\n12 gélules\nListe I",
            12, .capsule
        ),
        (
            "Voltaren Emulgel\ndiclofenac 1%\nGel 100 g",
            nil, .topical
        ),
        (
            "Paracetamol 120 mg/5 ml\nSuspension orale\nFlacon 100 ml",
            100, .liquid
        ),
    ]))
    func realisticCartons(vector: (text: String, count: Int?, form: MedicationForm?)) {
        #expect(PackQuantity.read(vector.text)?.count == vector.count, "count from \(vector.text)")
        #expect(MedicationForm.detect(in: vector.text) == vector.form, "form from \(vector.text)")
    }

    // MARK: - What reaches the editor

    /// Supply had never been implemented in the scan path at all: nothing
    /// anywhere touched `pillsRemaining`, so a carton that printed its own pack
    /// size still arrived with the field blank and tracking off.
    @Test("A carton that prints a count fills Supply")
    func scanFillsSupply() {
        var draft = MedicationDraft()
        draft.apply(LabelScanParser.parse("Metformin 500 mg", context: "100 TABLETS"))
        #expect(draft.tracksSupply)
        #expect(draft.pillsRemaining == 100)
        #expect(draft.hasScannedSupplyCount)
        // Left nil deliberately — a warning level is a product decision, not
        // something a carton states.
        #expect(draft.refillThreshold == nil)
    }

    /// And one that does not print a count leaves it blank. An empty field the
    /// user fills is honest; a number invented from a size class or a lot
    /// number is what the refill warning would then be built on.
    @Test("A carton that prints no count leaves Supply alone")
    func scanWithoutCountLeavesSupplyAlone() {
        var draft = MedicationDraft()
        draft.apply(LabelScanParser.parse("Metformin 500 mg", context: "Filmtabletten N2"))
        #expect(!draft.tracksSupply)
        #expect(draft.pillsRemaining == nil)
        #expect(!draft.hasScannedSupplyCount)
        // The form still lands — it is stated, where the count is not.
        #expect(draft.form == .pill)
    }

    /// The same rule `form` already follows. A scan filling a blank field is
    /// help; a scan replacing a number someone typed is the app overruling them
    /// about their own medicine cabinet.
    @Test("A scan never overwrites a count the user entered")
    func scanNeverOverwritesTheUser() {
        var draft = MedicationDraft()
        draft.tracksSupply = true
        draft.pillsRemaining = 12
        draft.apply(LabelScanParser.parse("Metformin 500 mg", context: "100 TABLETS"))
        #expect(draft.pillsRemaining == 12)
        #expect(!draft.hasScannedSupplyCount, "12 is the user's number, not a scan's")
    }

    /// But a scan may improve on a scan. AI (30) is a count the manufacturer
    /// encoded; the label's is one we read off the printed front.
    @Test("A stated count outranks a read one")
    func statedCountWins() throws {
        let pack = try #require(HRIParser.parse("(01)05437654786045(17)301231(30)0090"))
        var draft = MedicationDraft()
        draft.apply(ScanCapture(label: LabelScanParser.parse("Metformin 500 mg", context: "100 TABLETS"), pack: pack))
        #expect(draft.pillsRemaining == 90)
        #expect(draft.hasScannedSupplyCount)
    }

    /// …and still not on the user.
    @Test("A stated count does not overrule the user either")
    func statedCountYieldsToTheUser() throws {
        let pack = try #require(HRIParser.parse("(01)05437654786045(17)301231(30)0090"))
        var draft = MedicationDraft()
        draft.tracksSupply = true
        draft.pillsRemaining = 12
        draft.apply(ScanCapture(label: .empty, pack: pack))
        #expect(draft.pillsRemaining == 12)
    }

    /// Context is for claims about the *box*. The name and the strength are
    /// claims about one piece of text, and reading them from anywhere in frame
    /// is how a scan picks up the pharmacy's address.
    @Test("Context never reaches the name or the strength")
    func contextIsNotTheName() {
        let result = LabelScanParser.parse(
            "Ibuprofen", context: "Musterfirma GmbH 250 mg 30 Tabletten"
        )
        #expect(result.name == "Ibuprofen")
        #expect(result.strength.isEmpty)
        #expect(result.strengthAmount == nil)
        // The box's own facts still arrive.
        #expect(result.quantity == 30)
    }
}
