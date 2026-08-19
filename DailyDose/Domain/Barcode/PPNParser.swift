import Foundation

/// Reads an ISO/IEC 15434 Format 06 message — the envelope German pharmacy
/// DataMatrix codes use.
///
/// ```
/// [)>{RS}06{GS}9N111234567842{GS}1T1A234B5{GS}D151231{GS}S1234567890123456{RS}{EOT}
/// ```
///
/// Structurally kinder than GS1: every field is `GS`-delimited, so a Data
/// Identifier we do not recognise costs us that field and nothing else — the
/// boundary is still known. That is why this parser skips unknown identifiers
/// where `GS1Parser` has to reject them.
///
/// Field order is arbitrary. Indexing by position rather than by identifier
/// works on every sample payload and then fails on a real pharmacy's printer.
enum PPNParser {

    struct Element: Equatable, Sendable {
        let identifier: String
        let value: String
    }

    /// `[)>` RS `06` GS — the Format 06 header, and the definitive test for
    /// this syntax.
    static let header: [UInt8] = [0x5B, 0x29, 0x3E, ASCII.recordSeparator, 0x30, 0x36, ASCII.groupSeparator]

    /// The Data Identifiers a medicine pack carries, longest first.
    ///
    /// The order is load-bearing: matched short-first, `9N` would be read as
    /// `9` followed by `N…`, and `1T` as `1` followed by `T…`.
    private static let dataIdentifiers = ["9N", "1T", "D", "S"]

    /// Parses a complete message, header and all.
    static func parse(_ bytes: [UInt8]) -> [Element]? {
        guard bytes.starts(with: header) else { return nil }
        return parseBody(Array(bytes.dropFirst(header.count)))
    }

    /// Parses the fields alone, for scanners that hand over the body with the
    /// envelope already stripped.
    static func parseBody(_ bytes: [UInt8]) -> [Element]? {
        // The `RS EOT` trailer is optional in the wild — plenty of real codes
        // arrive without it, and one that ends abruptly is not malformed.
        var body = bytes[...]
        while let last = body.last, last == ASCII.recordSeparator || last == ASCII.endOfTransmission {
            body = body.dropLast()
        }

        var elements: [Element] = []
        var seen: Set<String> = []

        for field in body.split(separator: ASCII.groupSeparator, omittingEmptySubsequences: true) {
            guard let text = ASCII.printable(field) else { return nil }
            // An identifier we don't know is skipped, not fatal: the separators
            // told us exactly where this field ends, so nothing after it is at
            // risk. Rejecting here would throw away a perfectly good expiry
            // date because the pack also carried a field we have no use for.
            guard let identifier = dataIdentifiers.first(where: { text.hasPrefix($0) }) else { continue }
            let value = String(text.dropFirst(identifier.count))
            guard !value.isEmpty else { return nil }
            guard seen.insert(identifier).inserted else { return nil }
            elements.append(Element(identifier: identifier, value: value))
        }

        return elements.isEmpty ? nil : elements
    }
}
