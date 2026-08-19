import Foundation

/// Reads the National Drug Code a US GTIN carries inside it.
///
/// The convention is `GTIN-12 = "3" + NDC-10 + check digit`. Getting from a
/// barcode to those ten digits is arithmetic. Getting from the ten digits to an
/// NDC is **not**, and that is the single most important correctness point in
/// the barcode work:
///
/// > `1234567890` is a syntactically valid 4-4-2, a valid 5-3-2 *and* a valid
/// > 5-4-1 code. Three different medicines, one string of digits, and nothing
/// > in the barcode recording which.
///
/// So this type does not resolve anything. It generates the three readings and
/// hands them to whoever holds the FDA directory, which is the only thing that
/// can say which one is a product that exists. Everything here is pure, and the
/// ambiguity is expressed in the return type rather than hidden behind a guess.
enum NDCResolver {

    /// The ten NDC digits embedded in a GTIN, or nil when it embeds none.
    ///
    /// A nil is ordinary, not an error: most of the world's GTINs are not
    /// NDC-derived, and a German or British pack reaching here simply has
    /// nothing for the US directory to look up.
    static func embeddedDigits(in gtin: GTIN) -> String? {
        // Reduce GTIN-14 to GTIN-12. Anything that does not start with "00"
        // carries a real indicator digit or a longer company prefix, and its
        // twelve low digits are not an NDC packet.
        guard gtin.value.hasPrefix("00") else { return nil }
        let twelve = gtin.value.dropFirst(2)

        // The US National Health Related Item Code convention. A GTIN-12 that
        // does not start with 3 is a perfectly good GTIN — just not one built
        // from an NDC.
        guard twelve.hasPrefix("3") else { return nil }

        // The check digit is already verified: `GTIN` cannot be constructed
        // without it, and leading zeros cannot change a mod-10 result.
        let digits = String(twelve.dropFirst().prefix(10))
        return digits.count == 10 ? digits : nil
    }

    /// Every way the embedded digits could be read, in no particular order.
    ///
    /// All three are tagged `.inferred`, because that is exactly what they are
    /// until a directory match promotes one. At most one of them names a real
    /// product — across the whole FDA directory no two package codes share a
    /// ten-digit form — so a caller that finds several matches has a data
    /// problem, not a choice to make.
    ///
    /// The 12-digit 6-4-2 format is deliberately absent: it does not fit in a
    /// GTIN-12, which is why this whole convention ends when the FDA's new
    /// format takes effect on 7 March 2033.
    static func candidates(for gtin: GTIN) -> [NationalDrugCode] {
        guard let digits = embeddedDigits(in: gtin) else { return [] }
        return [.f442, .f532, .f541].compactMap {
            NationalDrugCode(digits: digits, format: $0, confidence: .inferred)
        }
    }
}
