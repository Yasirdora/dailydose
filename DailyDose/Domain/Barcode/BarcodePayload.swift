import Foundation

/// A barcode exactly as the scanner handed it over.
///
/// Bytes, not a `String`. A GS1 element string separates its variable-length
/// fields with `GS` (0x1D), and the `FNC1` that marks a symbol as GS1 is never
/// data at all — it reaches us, if it reaches us, as the AIM symbology
/// identifier instead. Both are the kind of thing a round trip through text
/// processing quietly normalises away, and a lost separator is two fields
/// silently becoming one.
struct BarcodePayload: Equatable, Sendable {

    /// The symbologies a medicine pack is printed in.
    ///
    /// Recorded, never dispatched on. Both syntaxes we read announce
    /// themselves in their own bytes, and a scanner can report the symbology
    /// wrongly or not at all — so letting it decide which parser runs would
    /// hang the parse on the least reliable field in the payload.
    enum Symbology: String, Sendable, CaseIterable {
        case dataMatrix, ean13, ean8, upce, code39, code128
        case gs1DataBar, gs1DataBarExpanded, gs1DataBarLimited
        case other
    }

    let bytes: [UInt8]
    let symbology: Symbology
    /// The AIM identifier the scanner transmitted — `"]d2"` for a GS1
    /// DataMatrix. Absent is normal, not an error: most scanners never send it.
    let symbologyIdentifier: String?

    init(bytes: [UInt8], symbology: Symbology = .other, symbologyIdentifier: String? = nil) {
        self.bytes = bytes
        self.symbology = symbology
        self.symbologyIdentifier = symbologyIdentifier
    }

    /// For the ordinary case where the scanner hands over decoded text.
    init(_ text: String, symbology: Symbology = .other, symbologyIdentifier: String? = nil) {
        self.init(bytes: Array(text.utf8), symbology: symbology, symbologyIdentifier: symbologyIdentifier)
    }
}

/// The three control bytes the two barcode syntaxes are built from.
///
/// Named because `0x1D` on its own tells a future reader nothing, and getting
/// `RS` and `GS` the wrong way round produces a parser that works on every
/// payload except the real ones.
enum ASCII {
    /// Separates GS1 variable-length fields, and ISO/IEC 15434 data fields.
    static let groupSeparator: UInt8 = 0x1D
    /// Opens and closes an ISO/IEC 15434 format envelope.
    static let recordSeparator: UInt8 = 0x1E
    /// Closes an ISO/IEC 15434 message. Optional in the wild.
    static let endOfTransmission: UInt8 = 0x04

    /// Decodes printable ASCII, and nothing else.
    ///
    /// Control bytes and anything above 0x7E mean the decode went wrong — a
    /// partial read, a mangled symbol, a payload that was never a barcode.
    /// Returning nil here is what keeps camera noise out of the parsers.
    static func printable<Bytes: Sequence>(_ bytes: Bytes) -> String? where Bytes.Element == UInt8 {
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            guard (0x20...0x7E).contains(byte) else { return nil }
            scalars.append(Unicode.Scalar(byte))
        }
        return String(scalars)
    }
}
