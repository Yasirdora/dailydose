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

        static let empty = Result(name: "", strength: "", strengthAmount: nil, strengthUnit: nil, detectedForm: nil)
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

    private static func isBoilerplate(_ text: String) -> Bool {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        return words.isEmpty || words.allSatisfy(nameBoilerplate.contains)
    }

    /// The name, or nothing. Never the strength wearing the name's clothes.
    private static func resolvedName(_ candidate: String) -> String {
        isBoilerplate(candidate) ? "" : prettifyName(candidate)
    }

    static func containsStrength(_ text: String) -> Bool {
        guard let strengthRegex else { return false }
        let flat = text.singleLine
        return strengthRegex.firstMatch(in: flat, range: NSRange(flat.startIndex..., in: flat)) != nil
    }

    static func parse(_ raw: String) -> Result {
        // OCR fragments arrive as vertical stacks; flatten before matching so a
        // label reading "PANADOL / EACH TABLET / CONTAINS" becomes one string.
        let text = raw.singleLine
        guard !text.isEmpty else { return .empty }
        // The whole label is scanned for form words, not just the part near
        // the strength — "EACH TABLET CONTAINS" declares the form as surely
        // as "500 mg tablets" does.
        let detectedForm = MedicationForm.detect(in: text)

        guard let strengthRegex,
              let match = strengthRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else {
            return Result(name: resolvedName(text), strength: "", strengthAmount: nil, strengthUnit: nil, detectedForm: detectedForm)
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
            detectedForm: detectedForm
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
