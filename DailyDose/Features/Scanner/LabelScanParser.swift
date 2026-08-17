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

        static let empty = Result(name: "", strength: "")
        var isEmpty: Bool { name.isEmpty && strength.isEmpty }
    }

    /// A number followed by a dose unit, with a word boundary at each end so
    /// "10g" inside "10gauge" doesn't register as a strength.
    private static let strengthPattern =
        #"\b\d+(?:[.,]\d+)?\s?(?:mg|mcg|µg|ml|iu|g|milligrams?|micrograms?|%)\b"#

    private static let formPattern =
        #"^\s*(tablets?|capsules?|caps?|tabs?|oral|solution|cream|spray|patch|drops?|inhaler|injection|lotion|ointment|suspension|syrup|gel)\b"#

    private static let strengthRegex = try? NSRegularExpression(
        pattern: strengthPattern, options: .caseInsensitive
    )
    private static let formRegex = try? NSRegularExpression(
        pattern: formPattern, options: .caseInsensitive
    )

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

        guard let strengthRegex,
              let match = strengthRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else {
            return Result(name: prettifyName(text), strength: "")
        }

        var strength = String(text[range])
        let name = String(text[..<range.lowerBound])

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
            name: prettifyName(trimmedName.isEmpty ? text : trimmedName),
            strength: normalizeStrength(strength)
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
