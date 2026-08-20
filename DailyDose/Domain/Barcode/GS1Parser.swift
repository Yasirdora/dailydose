import Foundation

/// The GS1 Application Identifiers a medicine pack carries, and what a valid
/// value for each one looks like.
///
/// This was once a byte-level tokeniser over a raw DataMatrix payload, and most
/// of it was machinery for a problem the printed form does not have: variable
/// fields run to a `GS` (0x1D) separator, scanners drop that byte routinely,
/// and a lost separator silently merges a batch number with whatever followed
/// it. The human-readable text prints `(nn)` around every identifier, so the
/// boundaries are simply given. `HRIParser` tokenises that; what survives here
/// is the part both forms need — which AIs we accept, and what a legal value
/// for each one is.
///
/// Deliberately short. Every AI listed is one whose length rule we are
/// promising to have got right, and an AI we skip costs the user nothing.
enum GS1Parser {

    /// One Application Identifier and its value, in the order the pack carried
    /// them. Whoever interprets these decides what any of it means.
    struct Element: Equatable, Sendable {
        let ai: String
        let value: String
    }

    /// AIs whose value is an exact number of digits.
    private static let fixedLength: [String: Int] = [
        "01": 14,   // GTIN
        "17": 6,    // Expiry, YYMMDD
    ]

    /// AIs whose value is a variable number of digits, up to this many.
    ///
    /// Only one, and it earns its place: AI (30) is the *count of items* in the
    /// pack, stated by the manufacturer. Where the OCR reads "30 Tabletten" off
    /// the front of a box and infers a count, this is the count.
    private static let variableNumeric: [String: Int] = [
        "30": 8,    // Count of items
    ]

    /// AIs whose value is 1…20 characters of GS1 CSET-82.
    private static let variableLength: Set<String> = [
        "10",   // Batch / lot
        "21",   // Serial
        "710",  // NHRN — PZN (Germany)
        "715",  // NHRN — NDC (US)
    ]

    private static let maximumVariableLength = 20

    static func isKnown(_ ai: String) -> Bool {
        fixedLength[ai] != nil || variableNumeric[ai] != nil || variableLength.contains(ai)
    }

    /// Whether a value that fails ``validate(ai:value:)`` may simply be dropped
    /// instead of rejecting the whole reading.
    ///
    /// The default is fatal, and it should be: a GTIN or an expiry that does
    /// not check out is a *misread*, and softening a misread into a missing
    /// field is how a reading of the wrong box comes back looking like a
    /// reading of no box. AI (30) is the exception because it is the one field
    /// nothing depends on — losing the pack's identity and its expiry date to
    /// salvage an item count would be exactly the wrong trade.
    static func isTolerated(_ ai: String) -> Bool { ai == "30" }

    /// An element, or nil when the value cannot be what its AI promises.
    ///
    /// The batch is returned exactly as printed. GS1 CSET-82 is case-sensitive,
    /// so `"ab12"` and `"AB12"` are different lots, and tidying the case here —
    /// the reflex everywhere else in this app, where it makes names read
    /// better — would make a recall check quietly wrong.
    static func validate(ai: String, value: String) -> Element? {
        if let length = fixedLength[ai] {
            guard value.count == length, value.isASCIIDigits else { return nil }
            return Element(ai: ai, value: value)
        }
        if let maximum = variableNumeric[ai] {
            guard !value.isEmpty, value.count <= maximum, value.isASCIIDigits else { return nil }
            return Element(ai: ai, value: value)
        }
        guard variableLength.contains(ai) else { return nil }
        guard !value.isEmpty, value.count <= maximumVariableLength else { return nil }
        // Printable ASCII only. Anything else is an OCR artefact, not a lot
        // number, and a batch with a control byte in it never came off a press.
        guard value.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else { return nil }
        return Element(ai: ai, value: value)
    }
}
