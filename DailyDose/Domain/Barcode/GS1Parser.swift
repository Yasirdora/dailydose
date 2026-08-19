import Foundation

/// Reads a GS1 element string into its Application Identifiers.
///
/// The whole design of this parser is one rule: **never guess a boundary.**
/// Fixed-length fields are read by byte count, variable-length fields run to
/// the next `GS`, and an Application Identifier we do not know the length of
/// ends the parse. Guessing a length silently corrupts every field after it —
/// a batch number that is really half a batch number and half an expiry date
/// reads as perfectly ordinary text, and nothing downstream can tell.
enum GS1Parser {

    /// One Application Identifier and its value, in the order the code carried
    /// them. The interpreter, not this parser, decides what any of it means.
    struct Element: Equatable, Sendable {
        let ai: String
        let value: String
    }

    /// The Application Identifiers a medicine pack actually carries.
    ///
    /// Deliberately short. Every AI we add is one whose length rule we are
    /// promising to have got right, and an AI we simply reject costs the user
    /// nothing but a re-scan of a pack we could not have read usefully anyway.
    private static let fixedLength: [String: Int] = [
        "01": 14,   // GTIN
        "17": 6,    // Expiry, YYMMDD
    ]

    /// Variable-length AIs. All of them are 1…20 characters of GS1 CSET-82.
    private static let variableLength: Set<String> = [
        "10",   // Batch / lot
        "21",   // Serial
        "710",  // NHRN — PZN (Germany)
        "715",  // NHRN — NDC (US)
    ]

    private static let maximumVariableLength = 20

    /// Parses an element string, or rejects it whole.
    ///
    /// There is no partial success. A payload that is half-readable is a
    /// payload we cannot say anything true about, and on a medicine box the
    /// right answer to "I'm not sure" is to ask for another scan — which costs
    /// two seconds — rather than to fill a form with the parts that happened to
    /// come out looking sensible.
    static func parse(_ bytes: [UInt8]) -> [Element]? {
        var index = bytes.startIndex
        var elements: [Element] = []
        var seen: Set<String> = []

        while index < bytes.endIndex {
            // A separator in this position is never the start of a field. It is
            // either the redundant one many encoders emit after a fixed-length
            // field — non-conformant, and extremely common in the wild — or the
            // legal trailing one that closes the last field. Skipping it here is
            // what keeps both from producing an empty phantom element.
            if bytes[index] == ASCII.groupSeparator {
                index += 1
                continue
            }

            guard let ai = applicationIdentifier(in: bytes, at: index) else { return nil }
            index += ai.count

            // A repeated AI means two answers to one question — two expiry
            // dates, two batch numbers — with nothing to choose between them.
            guard seen.insert(ai).inserted else { return nil }

            guard let value = readValue(for: ai, in: bytes, from: &index) else { return nil }
            elements.append(Element(ai: ai, value: value))
        }

        return elements.isEmpty ? nil : elements
    }

    // MARK: - Fields

    private static func readValue(for ai: String, in bytes: [UInt8], from index: inout Int) -> String? {
        if let length = fixedLength[ai] {
            // Read by count, and never look for a separator: a fixed-length
            // field that runs short is a truncated symbol, not a short value.
            guard index + length <= bytes.endIndex,
                  let text = ASCII.printable(bytes[index..<(index + length)]),
                  text.isASCIIDigits
            else { return nil }
            index += length
            return text
        }

        guard variableLength.contains(ai) else { return nil }

        var end = index
        while end < bytes.endIndex, bytes[end] != ASCII.groupSeparator { end += 1 }
        guard let text = ASCII.printable(bytes[index..<end]), !text.isEmpty else { return nil }

        // Overrunning the 20-character maximum is the one visible signature of a
        // separator the scanner dropped — routine in HID keyboard-wedge mode —
        // because the field has swallowed the one that followed it. We reject
        // rather than split on a guess: a wrong lot number on a medicine is a
        // safety event, and "please scan that again" costs two seconds.
        //
        // The honest limit of this: when the swallowed field is short enough
        // that the merged value still fits in 20 characters, the boundary is
        // formally unrecoverable and this parser cannot see the loss.
        guard text.count <= maximumVariableLength else { return nil }

        // Leave `index` on the separator; the loop head consumes it, so a
        // trailing separator closes the string instead of opening a field.
        index = end
        return text
    }

    /// The AI beginning at `index`, or nil if it is one we do not know.
    ///
    /// Matched longest first. Our table happens to be prefix-free — no
    /// three-digit AI here begins with a two-digit one — and matching this way
    /// round keeps that true if the table ever grows.
    private static func applicationIdentifier(in bytes: [UInt8], at index: Int) -> String? {
        for length in [3, 2] {
            guard index + length <= bytes.endIndex,
                  let candidate = ASCII.printable(bytes[index..<(index + length)])
            else { continue }
            if fixedLength[candidate] != nil || variableLength.contains(candidate) { return candidate }
        }
        return nil
    }
}
