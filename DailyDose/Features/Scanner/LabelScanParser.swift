import Foundation

/// Extracts a medication name and strength from raw OCR text.
///
/// `"METFORMIN HCL 500 MG TABLET"` → name `"Metformin HCL"`, strength `"500 mg tablet"`.
///
/// Pure and synchronous, so every quirk of real pharmacy labels can be pinned
/// in tests rather than discovered by pointing a phone at a bottle.
enum LabelScanParser {

    struct Result: Equatable, Sendable {
        var name: String
        var strength: String
        /// The strength as structure: "500" and .mg out of "500 MG TABLET".
        /// Lets the editor pre-fill the amount and pre-select the unit row,
        /// instead of making the user retype what the label already said.
        var strengthAmount: Double?
        var strengthUnit: StrengthUnit?
        /// The form the label itself declared ("tablets", "inhaler"), or nil
        /// when the label said nothing certain. A suggestion to confirm,
        /// never a fact to impose.
        var detectedForm: MedicationForm?
        /// How many the pack holds, when the carton printed a count — "30
        /// Tabletten", "3 x 10", "200 Hub". Nil far more often than not, and
        /// that is the intended behaviour: see ``PackQuantity``.
        var quantity: Int?

        static let empty = Result(
            name: "", strength: "", strengthAmount: nil, strengthUnit: nil,
            detectedForm: nil, quantity: nil
        )
        var isEmpty: Bool { name.isEmpty && strength.isEmpty }
    }

    /// A number followed by a dose unit, not followed by another letter — so
    /// "10g" inside "10gauge" doesn't register as a strength, and "0,5 %"
    /// does (`%` is a non-word character; a trailing `\b` could never match
    /// after it). The number and the unit are captured separately so the
    /// structured fields can be filled without re-parsing the composed string.
    private static let strengthPattern =
        #"\b(\d+(?:[.,]\d+)?)\s?(mg|mcg|µg|μg|ml|iu|g|milligrams?|micrograms?|%)(?![a-zA-Z])"#

    private static let formPattern =
        #"^\s*(tablets?|capsules?|caps?|tabs?|oral|solution|cream|spray|patch|drops?|inhaler|injection|lotion|ointment|suspension|syrup|gel)\b"#

    private static let strengthRegex = try? NSRegularExpression(
        pattern: strengthPattern, options: .caseInsensitive
    )
    private static let formRegex = try? NSRegularExpression(
        pattern: formPattern, options: .caseInsensitive
    )

    /// Words a label prints around a strength that are not a medication's
    /// name: "EACH TABLET CONTAINS", "NET WT", "PER DOSE".
    ///
    /// A fragment made only of these — or of nothing at all, which is what a
    /// standalone "500 MG" line leaves behind — must not become the name.
    /// Auto-capture waits for a fragment containing a strength, and on a real
    /// box the strength is usually set on its own line, so this is the *most
    /// likely* scan of all. An empty name the user fills is honest; a name
    /// pre-filled with "500 Mg" is a trap they save without re-reading.
    private static let nameBoilerplate: Set<String> = [
        "each", "every", "per", "contains", "containing", "content", "contents",
        "dose", "doses", "dosage", "net", "total", "strength", "of", "wt",
        "weight", "tablet", "tablets", "capsule", "capsules", "ml", "mg",
    ]

    /// Words that appear on a carton in type as large as the name, and are
    /// never the name.
    ///
    /// Ranking name candidates by printed size is a real improvement over
    /// ranking them by length — but the biggest words on a box are not always
    /// the medicine. "GEBRAUCHSINFORMATION" is set in display type on the
    /// leaflet flap, and a dispensing label puts the pharmacy's own headings in
    /// bold. Without this the size heuristic just swaps one wrong answer for
    /// another, and a wrong name pre-filled is a trap the user saves without
    /// re-reading.
    private static let nonNameWords: Set<String> = [
        // German — leaflet, prescription status, batch and date headings
        "gebrauchsinformation", "gebrauchsanweisung", "packungsbeilage", "beipackzettel",
        "rezeptpflichtig", "apothekenpflichtig", "verschreibungspflichtig",
        "chargenbezeichnung", "charge", "hersteller", "pharmazeutischer", "unternehmer",
        // English
        "lot", "exp", "expiry", "expires", "mfg", "mfd", "batch",
    ]

    /// Phrases the same applies to, matched on the folded text because they
    /// are several words and punctuated inconsistently.
    private static let nonNamePhrases: [String] = [
        "keep out of reach", "out of the reach", "keep away from children",
        "store below", "store at", "store in", "protect from light",
        "read the leaflet", "for oral use", "not to be taken",
        "ch.-b", "verw. bis", "fur kinder unzuganglich",
    ]

    /// Whether a fragment could be a medication's name at all.
    ///
    /// Used both to resolve the name and to *rank* candidates, so a boilerplate
    /// line set in big type never wins on size alone.
    static func couldBeName(_ text: String) -> Bool {
        // A prescription record is never a medicine's name, and this is the one
        // choke point every path to the name field passes through.
        guard !DispensingLabel.isPrivate(text) else { return false }
        guard !isBoilerplate(text), !HRIParser.isTranscription(text) else { return false }
        let folded = CartonText.fold(text.singleLine)
        if nonNamePhrases.contains(where: folded.contains) { return false }
        let words = Set(folded.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return words.isDisjoint(with: nonNameWords)
    }

    private static func isBoilerplate(_ text: String) -> Bool {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        return words.isEmpty || words.allSatisfy(nameBoilerplate.contains)
    }

    /// The name, or nothing. Never the strength wearing the name's clothes,
    /// and never the barcode wearing them either.
    ///
    /// A pack prints its own barcode in human-readable form —
    /// `(01) 05437654786045 (17) 210212 (10)…` — and on a real box the OCR read
    /// that line and offered it as the medication's name. The boilerplate
    /// filter let it through because the truncated tail carried a serial with
    /// letters in it, which reads as an ordinary word. Vocabulary was never
    /// going to catch this; the shape does. What that text *is* good for is
    /// `HRIParser`, which reads the identity and the dates straight out of it.
    private static func resolvedName(_ candidate: String) -> String {
        guard couldBeName(candidate) else { return "" }
        return prettifyName(candidate)
    }

    static func containsStrength(_ text: String) -> Bool {
        guard let strengthRegex else { return false }
        let flat = text.singleLine
        return strengthRegex.firstMatch(in: flat, range: NSRange(flat.startIndex..., in: flat)) != nil
    }

    /// Reads a whole label — every printed line the camera could see, in
    /// reading order.
    ///
    /// The entry point that knows what *kind* of document it is looking at. A
    /// carton names a product and a dispensing label records a transaction, and
    /// the difference is not cosmetic: on a label the name comes from one
    /// regular line and nowhere else, because the largest text on it is
    /// routinely the patient's.
    ///
    /// Redaction happens here, first, before anything is ranked or parsed —
    /// which is the requirement, not an implementation detail. A filter applied
    /// to the winner would mean a patient's name had already competed for the
    /// medication name field and merely lost.
    static func read(_ lines: [String]) -> Result {
        let visible = DispensingLabel.redacted(lines)
        guard !visible.isEmpty else { return .empty }
        let source: String? = DispensingLabel.isDispensingLabel(visible)
            ? DispensingLabel.drugLine(in: visible)
            : visible.first(where: containsStrength) ?? visible.first(where: couldBeName)
        return parse(source ?? "", context: visible.joined(separator: "\n"))
    }

    /// The same, for text that already carries its own line breaks.
    static func read(_ text: String) -> Result {
        read(text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    /// Reads one captured fragment, in the light of the rest of the carton.
    ///
    /// `context` is everything else the camera could see. It exists because a
    /// carton does not print its facts on one line: the name and the strength
    /// share the front panel, but "Filmtabletten" and "30 Stück" are set
    /// somewhere else entirely, and the shutter captures a single fragment.
    /// Reading only that fragment is why a scanned pack arrived with its name
    /// and strength filled in and Form still saying "Choose".
    ///
    /// The split is deliberate and it matters: **name and strength are read
    /// from `raw` alone**, because those two are claims about *this* piece of
    /// text and pulling them from anywhere in frame is how a scan picks up the
    /// pharmacy's address. Form and quantity are read from the whole carton,
    /// because they are claims about the box.
    static func parse(_ raw: String, context: String = "") -> Result {
        // OCR fragments arrive as vertical stacks; flatten before matching so a
        // label reading "PANADOL / EACH TABLET / CONTAINS" becomes one string.
        let text = raw.singleLine
        // Joined with a line break, not a space: each fragment is one printed
        // line, and ``CartonText`` reads a quantity only where the number and
        // its noun share one. Flattening them is how "Ibuprofen AL 400" over
        // "Filmtabletten" becomes a pack of four hundred.
        let carton = context.isEmpty ? raw : raw + "\n" + context
        guard !carton.isEmpty else { return .empty }
        // The whole label is scanned for form words, not just the part near
        // the strength — "EACH TABLET CONTAINS" declares the form as surely
        // as "500 mg tablets" does.
        let detectedForm = MedicationForm.detect(in: carton)
        // One lexicon answers both questions, so the count and the form can
        // never be read off the same printed word and disagree about it.
        let quantity = PackQuantity.read(carton)?.count

        guard let strengthRegex,
              let match = strengthRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else {
            return Result(
                name: resolvedName(text), strength: "", strengthAmount: nil,
                strengthUnit: nil, detectedForm: detectedForm, quantity: quantity
            )
        }

        var strength = String(text[range])
        let name = String(text[..<range.lowerBound])

        // Structured strength: the captured number and unit, read once here
        // so nothing downstream has to re-parse the composed string.
        // "0,5 %" parses as 0.5 — European labels use the decimal comma.
        let strengthAmount = Range(match.range(at: 1), in: text)
            .flatMap { Double(text[$0].replacingOccurrences(of: ",", with: ".")) }
        let strengthUnit = Range(match.range(at: 2), in: text)
            .flatMap { StrengthUnit.named(String(text[$0])) }

        // Absorb a trailing dosage form ("tablet", "capsule") into the strength,
        // where it belongs, instead of leaving it stranded in the name.
        let tail = String(text[range.upperBound...])
        if let formRegex,
           let formMatch = formRegex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
           let formRange = Range(formMatch.range, in: tail) {
            strength += " " + tail[formRange].trimmingCharacters(in: .whitespaces)
        }

        let trimmedName = name.trimmingCharacters(
            in: CharacterSet.whitespaces.union(.punctuationCharacters)
        )
        return Result(
            // Only the words *before* the strength are ever a candidate. The
            // old fallback to the whole fragment is what produced "500 Mg".
            name: resolvedName(trimmedName),
            strength: normalizeStrength(strength),
            strengthAmount: strengthAmount,
            strengthUnit: strengthUnit,
            detectedForm: detectedForm,
            quantity: quantity
        )
    }

    /// Title-cases the name while preserving short all-caps tokens.
    ///
    /// Plain `.capitalized` turned "METFORMIN HCL" into "Metformin Hcl" and
    /// "CoQ10" into "Coq10". Clinical abbreviations are part of how people
    /// recognise their own medication, so they're kept intact.
    private static func prettifyName(_ text: String) -> String {
        let preserved: Set<String> = [
            "HCL", "HCI", "ER", "XR", "SR", "CR", "LA", "XL", "DS", "EC", "IR", "MR", "OD", "PM",
            "CD", "SA", "TR", "ODT", "IU", "CoQ10", "COQ10", "NPH", "USP",
        ]
        return text
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { token -> String in
                let raw = String(token)
                if preserved.contains(raw.uppercased()) { return raw.uppercased() }
                // A token mixing letters and digits ("D3", "B12") keeps its shape.
                if raw.rangeOfCharacter(from: .decimalDigits) != nil { return raw.uppercased() }
                return raw.lowercased().capitalized
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Normalises unit and form casing: "500 MG TABLET" → "500 mg tablet".
    private static func normalizeStrength(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)
        let lowercaseTokens = [
            "MG", "MCG", "ML", "IU", "G", "TABLETS", "TABLET", "CAPSULES", "CAPSULE",
            "CAPS", "CAP", "TABS", "TAB", "ORAL", "SOLUTION", "CREAM", "SPRAY", "PATCH",
            "DROPS", "DROP", "INHALER", "INJECTION", "LOTION", "OINTMENT", "SUSPENSION",
            "SYRUP", "GEL",
        ]
        for token in lowercaseTokens {
            result = result.replacingOccurrences(
                of: "\\b\(token)\\b",
                with: token.lowercased(),
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // Collapse any whitespace the substitutions left behind.
        return result
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
