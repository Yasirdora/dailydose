import Foundation
import Testing
@testable import DailyDose

/// Barcode payloads as bytes, written the way a scanner hands them over.
///
/// Built by hand rather than from string literals because the separators are
/// the whole difficulty: `GS` is invisible in a source file, and a test that
/// cannot express "this byte is missing" cannot test the case that matters.
private enum Payload {
    static let gs = ASCII.groupSeparator
    static let rs = ASCII.recordSeparator
    static let eot = ASCII.endOfTransmission

    static func bytes(_ parts: [Any]) -> [UInt8] {
        parts.flatMap { part -> [UInt8] in
            if let text = part as? String { return Array(text.utf8) }
            if let byte = part as? UInt8 { return [byte] }
            return []
        }
    }

    /// `(01)00312345678906(21)12345678(10)ABC123(17)180630` — a US pack.
    static let usDataMatrix = bytes([
        "0100312345678906",
        "2112345678", gs,
        "10ABC123", gs,
        "17180630",
    ])

    /// The worked example from the IFA specification, envelope and all.
    static let germanPPN = bytes([
        "[)>", rs, "06", gs,
        "9N111234567842", gs,
        "1T1A234B5", gs,
        "D151231", gs,
        "S1234567890123456", rs, eot,
    ])
}

/// A calendar and a "today" that never move, so the century window is a
/// property of the code under test rather than of the day the suite runs.
private enum Scan {
    static let calendar = Fixture.calendar()

    static func read(
        _ bytes: [UInt8],
        on day: Date = Fixture.date(2026, 8, 19),
        symbologyIdentifier: String? = nil
    ) -> ScannedPack? {
        BarcodeInterpreter.interpret(
            BarcodePayload(bytes: bytes, symbology: .dataMatrix, symbologyIdentifier: symbologyIdentifier),
            now: day,
            calendar: calendar
        )
    }

    static func parts(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: date)
    }
}

// MARK: - Check digits

@Suite("Barcode check digits")
struct CheckDigitTests {

    /// The worked example from the GS1 General Specifications. Asserted against
    /// the literal 6, not against a second call to the same routine — a test
    /// that recomputes the implementation's own answer agrees with every bug
    /// the implementation has.
    @Test("A GTIN's modulo-10 digit matches the published example")
    func gtinVector() {
        #expect(CheckDigit.gtin(dataDigits: "0031234567890") == 6)
        #expect(CheckDigit.isValidGTIN("00312345678906"))
        #expect(!CheckDigit.isValidGTIN("00312345678907"))
    }

    /// The final `% 10` that turns a check digit of "10" into 0. Without it the
    /// routine returns a two-digit answer for one GTIN in ten, and every one of
    /// those products fails to scan.
    @Test("A weighted sum that is a multiple of ten checks as 0, never 10")
    func gtinZeroCheckDigit() {
        // 0000000000000 sums to 0, so the check digit must be 0.
        #expect(CheckDigit.gtin(dataDigits: "0000000000000") == 0)
        #expect(CheckDigit.isValidGTIN("00000000000000"))
    }

    /// Both published IFA examples.
    @Test("A PZN's modulo-11 digit matches both published examples")
    func pznVectors() {
        #expect(CheckDigit.pzn(firstSeven: "2758089") == 9)
        #expect(CheckDigit.pzn(firstSeven: "1234567") == 8)
        #expect(CheckDigit.isValidPZN("27580899"))
        #expect(CheckDigit.isValidPZN("12345678"))
    }

    /// A remainder of 10 has no single-digit form and IFA issues no
    /// substitution character, so such numbers are simply never assigned.
    /// Inventing an eighth digit here would make a number that cannot exist
    /// look like a valid medicine.
    @Test("A PZN whose remainder is 10 is rejected, not substituted")
    func pznRemainderTenIsRejected() {
        // 9·1 + 9·2 + 9·3 + 9·4 + 9·5 + 9·6 + 9·7 = 252, and 252 % 11 == 10.
        #expect(CheckDigit.pzn(firstSeven: "9999999") == nil)
        // 3·7 = 21, and 21 % 11 == 10.
        #expect(CheckDigit.pzn(firstSeven: "0000003") == nil)

        // No eight-digit form of such a prefix validates, for any final digit:
        // the number was never issued, so nothing can complete it.
        for digit in 0...9 {
            #expect(!CheckDigit.isValidPZN("9999999" + String(digit)))
            #expect(PZN("9999999" + String(digit)) == nil)
        }
    }

    /// The classic implementation bug is weighting the *digit values* instead
    /// of the ASCII values. Both published examples are here because one of
    /// them passes under the wrong algorithm often enough to look fine.
    @Test("A PPN's modulo-97 check runs over ASCII values, not digit values")
    func ppnVectors() {
        #expect(CheckDigit.ppn(body: "1103752864") == "14")
        #expect(CheckDigit.ppn(body: "1112345678") == "42")
        #expect(CheckDigit.isValidPPN("110375286414"))
        #expect(CheckDigit.isValidPPN("111234567842"))
        #expect(!CheckDigit.isValidPPN("111234567843"))

        // The digit-value version of the same sum, spelled out, to show it is
        // a different number: 1·2 + 1·3 + 1·4 + 2·5 + 3·6 + 4·7 + 5·8 + 6·9
        // + 7·10 + 8·11 = 357, and 357 % 97 == 66, not 42.
        #expect(CheckDigit.ppn(body: "1112345678") != "66")
    }

    /// A check digit that has not been verified must not be expressible as a
    /// verified code — that is the whole reason these are types.
    @Test("Identity types refuse a code whose check digit disagrees")
    func typesRefuseBadCheckDigits() {
        #expect(GTIN("00312345678906") != nil)
        #expect(GTIN("00312345678907") == nil)
        // Lengths that are not a GTIN, however well-formed as digits.
        #expect(GTIN("0031234567890") == nil)
        #expect(GTIN("1234567890") == nil)
        #expect(GTIN("") == nil)
        #expect(GTIN("0031234567890X") == nil)

        #expect(PZN("12345678") != nil)
        #expect(PZN("12345679") == nil)
        #expect(PZN("1234567") == nil)

        #expect(PPN("111234567842") != nil)
        #expect(PPN("111234567843") == nil)
        // Below the 11-character minimum.
        #expect(PPN("1112345642") == nil)
    }

    /// Zero padding cannot change a mod-10 result, because the weights count
    /// from the right. That is what makes one canonical GTIN-14 form safe.
    @Test("A GTIN normalises to fourteen digits without changing its check")
    func gtinNormalisation() {
        #expect(GTIN("4150123456782")?.value == "04150123456782")
        #expect(GTIN("04150123456782")?.value == "04150123456782")
        // The same product, whichever length it was printed at.
        #expect(GTIN("4150123456782") == GTIN("04150123456782"))
    }
}

// MARK: - Real payloads

@Suite("Barcode payloads")
struct BarcodePayloadTests {

    /// The full US DataMatrix, read on an ordinary day in 2026: `(17)180630`
    /// is a pack that expired in 2018, and the sliding window says so.
    @Test("A US GS1 DataMatrix yields GTIN, batch and expiry — and no serial")
    func usDataMatrix() throws {
        let pack = try #require(Scan.read(Payload.usDataMatrix))

        #expect(pack.syntax == .gs1)
        #expect(pack.gtin?.value == "00312345678906")
        #expect(pack.key == .gtin(try #require(GTIN("00312345678906"))))
        #expect(pack.batch == "ABC123")
        #expect(Scan.parts(try #require(pack.expiry).day) == DateComponents(year: 2018, month: 6, day: 30))
        #expect(pack.expiry?.isEndOfMonth == false)
        // No AI (715), so nothing to resolve without the FDA directory.
        #expect(pack.ndc == nil)

        // The serial was read — the fields after it could not have been found
        // otherwise — and then dropped. There is nowhere on `ScannedPack` for
        // it to be, and that is deliberate: it identifies one physical box, so
        // it is a tracking identifier with no use here.
        let elements = try #require(GS1Parser.parse(Payload.usDataMatrix))
        #expect(elements.contains(GS1Parser.Element(ai: "21", value: "12345678")))
        #expect(!ScannedPack.carriesASerialField(pack), "the serial must not survive parsing")
    }

    /// The worked example from the IFA specification.
    @Test("A German PPN DataMatrix yields PPN, PZN, batch and expiry")
    func germanPPN() throws {
        let pack = try #require(Scan.read(Payload.germanPPN))

        #expect(pack.syntax == .ifaPPN)
        #expect(pack.pzn?.value == "12345678")
        #expect(pack.key == .pzn(try #require(PZN("12345678"))))
        #expect(pack.batch == "1A234B5")
        #expect(Scan.parts(try #require(pack.expiry).day) == DateComponents(year: 2015, month: 12, day: 31))
        #expect(pack.gtin == nil)

        let elements = try #require(PPNParser.parse(Payload.germanPPN))
        #expect(elements.contains(PPNParser.Element(identifier: "9N", value: "111234567842")))
        // DI `S` parsed, then left behind — same reasoning as AI (21).
        #expect(elements.contains(PPNParser.Element(identifier: "S", value: "1234567890123456")))
        #expect(!ScannedPack.carriesASerialField(pack))
    }

    /// A pack that carries only the envelope's fields, with the header already
    /// stripped by the scanner — and `9N` tested before `01`, because `01` is
    /// a legal opening for a PPN value too.
    @Test("A PPN body without its envelope still parses")
    func ppnBodyWithoutEnvelope() throws {
        let bytes = Payload.bytes(["9N111234567842", Payload.gs, "D151231"])
        let pack = try #require(Scan.read(bytes))
        #expect(pack.syntax == .ifaPPN)
        #expect(pack.pzn?.value == "12345678")
    }

    /// Field order in Format 06 is arbitrary; indexing by position works on
    /// every sample payload and then fails on a real pharmacy's printer.
    @Test("PPN fields are read by identifier, in any order")
    func ppnFieldOrderIsIrrelevant() throws {
        let shuffled = Payload.bytes([
            "[)>", Payload.rs, "06", Payload.gs,
            "D151231", Payload.gs,
            "S1234567890123456", Payload.gs,
            "1T1A234B5", Payload.gs,
            "9N111234567842",
        ])
        let pack = try #require(Scan.read(shuffled))
        #expect(pack.pzn?.value == "12345678")
        #expect(pack.batch == "1A234B5")
        #expect(Scan.parts(try #require(pack.expiry).day) == DateComponents(year: 2015, month: 12, day: 31))
    }

    /// NTIN syntax: a German PZN riding inside an ordinary EAN-13.
    @Test("An NTIN linear code yields the PZN inside it")
    func ntinLinearCode() throws {
        let pack = try #require(Scan.read(Payload.bytes(["04150123456782"])))
        #expect(pack.syntax == .linear)
        #expect(pack.gtin?.value == "04150123456782")
        #expect(pack.pzn?.value == "12345678")
        // The PZN wins the key: it is the more specific identity.
        #expect(pack.key == .pzn(try #require(PZN("12345678"))))
        // A linear code carries no dates. That is normal, not a failure.
        #expect(pack.expiry == nil)
        #expect(pack.batch == nil)
    }

    /// The `04150` prefix is a pattern any fourteen-digit number can produce.
    /// Only the PZN's own check digit makes it safe to act on.
    @Test("An 04150 GTIN whose inner PZN fails its check is not a PZN")
    func ntinRequiresAValidInnerPZN() throws {
        // 04150123456799 is a valid GTIN whose embedded "12345679" is not a
        // valid PZN — the PZN check digit should be 8, not 9.
        let gtin = try #require(GTIN("4150123456799"))
        #expect(CheckDigit.isValidGTIN(gtin.value))
        #expect(gtin.pzn == nil)
        let pack = try #require(Scan.read(Payload.bytes([gtin.value])))
        #expect(pack.key == .gtin(gtin))
    }

    /// AI (710) states the PZN outright, and beats the one inferred from a
    /// GTIN — it is what the pack says about itself.
    @Test("A stated NHRN outranks the one embedded in the GTIN")
    func statedNHRNWins() throws {
        let bytes = Payload.bytes(["0104150123456782", "71027580899"])
        let pack = try #require(Scan.read(bytes))
        #expect(pack.pzn?.value == "27580899")
        #expect(pack.gtin?.value == "04150123456782")
    }

    /// A DataBar carries a bare element string with no separator and no
    /// symbology identifier — matched on the complete AI (01) rather than on
    /// the two-digit prefix, so a plain numeric code cannot fall in here.
    @Test("A GS1 element string with no FNC1 is still recognised")
    func elementStringWithoutFNC1() throws {
        let pack = try #require(Scan.read(Payload.bytes(["0100312345678906", "17280630"])))
        #expect(pack.syntax == .gs1)
        #expect(Scan.parts(try #require(pack.expiry).day) == DateComponents(year: 2028, month: 6, day: 30))
    }

    /// A leading `GS` is the FNC1 some scanners pass through as data.
    @Test("A leading separator opens a GS1 payload without becoming a field")
    func leadingSeparator() throws {
        let pack = try #require(Scan.read(Payload.bytes([Payload.gs, "0100312345678906"])))
        #expect(pack.gtin?.value == "00312345678906")
    }

    @Test("The symbology identifier alone can route a payload to GS1")
    func symbologyIdentifierRouting() throws {
        let pack = try #require(
            Scan.read(Payload.bytes(["0100312345678906"]), symbologyIdentifier: "]d2")
        )
        #expect(pack.syntax == .gs1)
    }
}

// MARK: - Separators

@Suite("GS1 separators")
struct GS1SeparatorTests {

    /// A separator after a fixed-length field is non-conformant and extremely
    /// common. Tolerating it costs nothing; rejecting it would fail on real
    /// pharmacy stock.
    @Test("A redundant separator after a fixed-length field is skipped")
    func redundantSeparatorAfterFixedField() throws {
        let bytes = Payload.bytes([
            "0100312345678906", Payload.gs,
            "17180630", Payload.gs,
            "10ABC123",
        ])
        let pack = try #require(Scan.read(bytes))
        #expect(pack.batch == "ABC123")
        #expect(Scan.parts(try #require(pack.expiry).day) == DateComponents(year: 2018, month: 6, day: 30))
    }

    /// A trailing separator is legal and redundant. It must close the last
    /// field, not open an empty one.
    @Test("A trailing separator emits no empty field")
    func trailingSeparator() throws {
        let bytes = Payload.bytes(["0100312345678906", "10ABC123", Payload.gs])
        let elements = try #require(GS1Parser.parse(bytes))
        #expect(elements.count == 2)
        #expect(elements.last == GS1Parser.Element(ai: "10", value: "ABC123"))
    }

    /// The pair that matters. One byte apart: with the separator the batch is
    /// `LOT12345`; without it the field swallows the serial that followed and
    /// overruns AI (10)'s twenty-character maximum, which is the one visible
    /// signature of a separator a scanner dropped.
    @Test("A stripped group separator is rejected rather than guessed")
    func strippedSeparatorIsRejected() throws {
        let withSeparator = Payload.bytes([
            "0100312345678906",
            "10LOT12345", Payload.gs,
            "21SERIAL987654321",
        ])
        let stripped = Payload.bytes([
            "0100312345678906",
            "10LOT12345",
            "21SERIAL987654321",
        ])

        #expect(try #require(Scan.read(withSeparator)).batch == "LOT12345")
        #expect(Scan.read(stripped) == nil)
    }

    /// The honest limit of the rule above, pinned so nobody mistakes it for a
    /// guarantee: when the swallowed field is short enough that the merged
    /// value still fits in twenty characters, the boundary is formally
    /// unrecoverable and the batch reads long. Phase 1 cannot detect this, and
    /// a reviewer should know that rather than discover it.
    @Test("A short stripped separator is invisible — a known limit, not a bug")
    func shortStrippedSeparatorIsUndetectable() throws {
        let stripped = Payload.bytes(["0100312345678906", "10ABC123", "17180630"])
        let pack = try #require(Scan.read(stripped))
        #expect(pack.batch == "ABC12317180630")
        #expect(pack.expiry == nil)
    }
}

// MARK: - Malformed input

@Suite("Malformed barcodes")
struct MalformedBarcodeTests {

    /// Every one of these must be nil. None may crash: malformed input is the
    /// *normal* case when a camera is involved.
    @Test("Malformed payloads return nil rather than a partial reading")
    func malformedPayloadsAreRejected() {
        let cases: [(String, [UInt8])] = [
            ("empty", []),
            ("pure noise", Payload.bytes(["!!!???"])),
            ("truncated fixed-length field", Payload.bytes(["010031234567"])),
            ("non-numeric fixed-length field", Payload.bytes(["0100312345ABCD06"])),
            ("unknown AI", Payload.bytes(["0100312345678906", "99XYZ"])),
            ("empty variable field", Payload.bytes(["0100312345678906", "10", Payload.gs, "17180630"])),
            ("over-long variable field", Payload.bytes(["10ABCDEFGHIJKLMNOPQRSTUVWXYZ"])),
            ("GTIN with a wrong check digit", Payload.bytes(["0100312345678907"])),
            ("expiry with month 13", Payload.bytes(["0100312345678906", "17251301"])),
            ("expiry with 31 February", Payload.bytes(["0100312345678906", "17250231"])),
            ("repeated AI", Payload.bytes(["0100312345678906", "17250601", "17250602"])),
            ("no product code at all", Payload.bytes([Payload.gs, "17250601"])),
            ("PPN with a wrong check digit", Payload.bytes(["9N111234567843"])),
            ("PPN body with an empty field", Payload.bytes(["9N111234567842", Payload.gs, "1T"])),
            ("PPN expiry that is not six digits", Payload.bytes(["9N111234567842", Payload.gs, "D1512"])),
            ("a linear code of the wrong length", Payload.bytes(["1234567890"])),
            ("a linear code with a bad check digit", Payload.bytes(["4006381333932"])),
            ("control bytes in the middle", [0x30, 0x31, 0x00, 0x31]),
        ]
        for (label, bytes) in cases {
            #expect(Scan.read(bytes) == nil, "\(label) should be rejected")
        }
    }

    /// An unknown Data Identifier is *not* fatal in Format 06, unlike an
    /// unknown AI in GS1: the separators mean the boundary is still known, so
    /// nothing after it is at risk. Rejecting here would throw away a good
    /// expiry date because the pack also carried a field we have no use for.
    @Test("An unknown PPN data identifier is skipped, not fatal")
    func unknownDataIdentifierIsSkipped() throws {
        let bytes = Payload.bytes([
            "9N111234567842", Payload.gs,
            "12Z9876", Payload.gs,
            "D151231",
        ])
        let pack = try #require(Scan.read(bytes))
        #expect(pack.pzn?.value == "12345678")
        #expect(Scan.parts(try #require(pack.expiry).day) == DateComponents(year: 2015, month: 12, day: 31))
    }

    /// The trailer is optional in the wild.
    @Test("A Format 06 message with no trailer is not malformed")
    func missingTrailerIsFine() throws {
        let bytes = Payload.bytes([
            "[)>", Payload.rs, "06", Payload.gs,
            "9N111234567842", Payload.gs,
            "D151231",
        ])
        #expect(Scan.read(bytes) != nil)
    }
}

// MARK: - Case

@Suite("Barcode text fields")
struct BarcodeTextFieldTests {

    /// GS1 CSET-82 is case-sensitive, so `"ab12"` and `"AB12"` are different
    /// lots. Upper-casing them — the reflex everywhere else in this app, where
    /// it makes names read better — would make a recall check quietly wrong.
    @Test("Batch and serial preserve case exactly")
    func caseIsPreserved() throws {
        let bytes = Payload.bytes([
            "0100312345678906",
            "10aB12cD", Payload.gs,
            "21xY99zW",
        ])
        let pack = try #require(Scan.read(bytes))
        #expect(pack.batch == "aB12cD")

        let elements = try #require(GS1Parser.parse(bytes))
        #expect(elements.contains(GS1Parser.Element(ai: "10", value: "aB12cD")))
        #expect(elements.contains(GS1Parser.Element(ai: "21", value: "xY99zW")))
    }

    @Test("A PPN batch preserves case too")
    func ppnBatchCase() throws {
        let bytes = Payload.bytes(["9N111234567842", Payload.gs, "1TaB234b5"])
        #expect(try #require(Scan.read(bytes)).batch == "aB234b5")
    }
}

// MARK: - Expiry

@Suite("Expiry dates")
struct ExpiryDateTests {

    private static let calendar = Fixture.calendar()

    private func read(
        _ yymmdd: String, _ encoding: ExpiryDate.Encoding, on day: Date = Fixture.date(2026, 8, 19)
    ) -> ExpiryDate? {
        ExpiryDate.parse(yymmdd, encoding: encoding, reference: day, calendar: Self.calendar)
    }

    private func parts(_ date: Date) -> DateComponents {
        Self.calendar.dateComponents([.year, .month, .day], from: date)
    }

    /// GS1 healthcare has prohibited `DD = 00` since 1 January 2025; German PPN
    /// syntax still permits it. Both are accepted on input, because legacy
    /// stock is still on shelves — only the flag differs.
    @Test("Day 00 means the last day of the month, in both syntaxes")
    func endOfMonth() throws {
        let gs1 = try #require(read("250200", .gs1))
        #expect(parts(gs1.day) == DateComponents(year: 2025, month: 2, day: 28))
        #expect(gs1.isEndOfMonth)
        #expect(gs1.isNonConformant)

        let ppn = try #require(read("240200", .ppn))
        #expect(parts(ppn.day) == DateComponents(year: 2024, month: 2, day: 29), "2024 is a leap year")
        #expect(ppn.isEndOfMonth)
        #expect(!ppn.isNonConformant, "PPN syntax still permits day 00")

        // A month with 30 days, and one with 31.
        #expect(parts(try #require(read("250400", .ppn)).day) == DateComponents(year: 2025, month: 4, day: 30))
        #expect(parts(try #require(read("251200", .ppn)).day) == DateComponents(year: 2025, month: 12, day: 31))
    }

    /// An ordinary day carries neither flag.
    @Test("An explicit day is neither end-of-month nor non-conformant")
    func explicitDay() throws {
        let date = try #require(read("250615", .gs1))
        #expect(parts(date.day) == DateComponents(year: 2025, month: 6, day: 15))
        #expect(!date.isEndOfMonth)
        #expect(!date.isNonConformant)
    }

    /// IFA states it outright: PPN dates are 21st century, whatever the year is.
    @Test("A PPN year is always 2000 plus YY")
    func ppnCentury() throws {
        #expect(Self.calendar.component(.year, from: try #require(read("000601", .ppn)).day) == 2000)
        #expect(Self.calendar.component(.year, from: try #require(read("150601", .ppn)).day) == 2015)
        #expect(Self.calendar.component(.year, from: try #require(read("990601", .ppn)).day) == 2099)
        // And it does not move when "today" does.
        #expect(
            Self.calendar.component(
                .year, from: try #require(read("150601", .ppn, on: Fixture.date(2099, 1, 1))).day
            ) == 2015
        )
    }

    /// GS1's window is centred on the current *year*, not the current century:
    /// fifty forward, forty-nine back. That is what makes a recently expired
    /// pack read as recently expired instead of as a date in the 1920s.
    @Test("A GS1 year resolves inside the sliding hundred-year window")
    func gs1Century() throws {
        let today = Fixture.date(2026, 8, 19)   // window: 1977…2076
        func year(_ yy: String) throws -> Int {
            Self.calendar.component(.year, from: try #require(read("\(yy)0601", .gs1, on: today)).day)
        }
        #expect(try year("26") == 2026)
        #expect(try year("27") == 2027)
        #expect(try year("25") == 2025, "last year, not 1925")
        #expect(try year("18") == 2018, "a pack that expired eight years ago")
        #expect(try year("00") == 2000)

        // The seam, both sides of it. Fifty years forward is inside the
        // window; fifty-one back is where it wraps.
        #expect(try year("76") == 2076, "the last year the window reaches forward")
        #expect(try year("77") == 1977, "one further, and it is the past instead")
        #expect(try year("99") == 1999)
    }

    /// The window slides with the reference date, which is exactly why the
    /// reference is a parameter rather than `Date.now` — the same two digits
    /// name different years depending on when they are read.
    @Test("The GS1 window follows the reference date")
    func gs1WindowSlides() throws {
        func year(_ yy: String, on day: Date) throws -> Int {
            Self.calendar.component(.year, from: try #require(read("\(yy)0601", .gs1, on: day)).day)
        }
        // Read in 2019 the window is 1970…2069, so YY = 75 is in the past.
        #expect(try year("75", on: Fixture.date(2019, 6, 1)) == 1975)
        // Read in 2026 it is 1977…2076, and the same digits are in the future.
        #expect(try year("75", on: Fixture.date(2026, 8, 19)) == 2075)
    }

    /// `Calendar` will happily roll 30 February into 2 March, which would turn
    /// a misread into a plausible-looking date.
    @Test("A day that does not exist is rejected, never rolled forward")
    func impossibleDates() {
        #expect(read("250230", .ppn) == nil)
        #expect(read("250431", .ppn) == nil)
        #expect(read("251301", .ppn) == nil)
        #expect(read("250001", .ppn) == nil, "month 00")
        #expect(read("2506", .ppn) == nil, "too short")
        #expect(read("2506011", .ppn) == nil, "too long")
        #expect(read("25O601", .ppn) == nil, "a letter O for a zero")
    }
}

// MARK: - Identity

@Suite("Product keys")
struct ProductKeyTests {

    /// The persisted form has to round-trip exactly, or a second scan of the
    /// same box fails to find the medication the user named.
    @Test("Every key round-trips through its persisted string")
    func roundTrip() throws {
        let keys: [ProductKey] = [
            .gtin(try #require(GTIN("00312345678906"))),
            .pzn(try #require(PZN("12345678"))),
            .ppn(try #require(PPN("111234567842"))),
            .ndc(try #require(NationalDrugCode(hyphenated: "12345-6789-0"))),
        ]
        for key in keys {
            #expect(ProductKey(rawValue: key.rawValue) == key, "\(key.rawValue)")
        }
        // Pinned literals, so a change to the format is a deliberate one —
        // it would orphan every key already on a user's phone.
        #expect(keys[0].rawValue == "gtin:00312345678906")
        #expect(keys[1].rawValue == "pzn:12345678")
        #expect(keys[2].rawValue == "ppn:111234567842")
        #expect(keys[3].rawValue == "ndc:12345-6789-0")
    }

    /// A raw value from a newer build, a damaged file or a hand edit must read
    /// as "no key" — never as a crash, and never as a wrong match.
    @Test("An unreadable raw value reads as no key at all")
    func tolerantResolution() {
        for raw in ["", "nonsense", "gtin:", "gtin:99999999999999", "pzn:12345679",
                    "ppn:111234567843", "ndc:12345", "ndc:123456-7890-123", "future:xyz"] {
            #expect(ProductKey(rawValue: raw) == nil, "\(raw) should not resolve")
        }
    }

    /// The same box scanned twice must produce one key, whatever the code's
    /// printed length was.
    @Test("The same product produces the same key from any GTIN length")
    func canonicalGTIN() throws {
        let short = try #require(GTIN("4150123456782"))
        let long = try #require(GTIN("04150123456782"))
        #expect(ProductKey.gtin(short).rawValue == ProductKey.gtin(long).rawValue)
    }
}

// MARK: - NDC

@Suite("National Drug Code")
struct NationalDrugCodeTests {

    /// The four formats have four distinct length patterns, so the hyphens
    /// alone determine the format — there is no tag to drift out of agreement.
    @Test("A hyphenated code carries its own segmentation")
    func formatFromHyphens() throws {
        #expect(NationalDrugCode(hyphenated: "1234-5678-90")?.format == .f442)
        #expect(NationalDrugCode(hyphenated: "12345-678-90")?.format == .f532)
        #expect(NationalDrugCode(hyphenated: "12345-6789-0")?.format == .f541)
        #expect(NationalDrugCode(hyphenated: "123456-7890-12")?.format == .f642)
        #expect(NationalDrugCode(hyphenated: "12345-6789") == nil)
        #expect(NationalDrugCode(hyphenated: "123-456-78") == nil)
        #expect(NationalDrugCode(hyphenated: "1234A-5678-90") == nil)

        let ndc = try #require(NationalDrugCode(hyphenated: "50090-6441-0"))
        #expect(ndc.labeler == "50090")
        #expect(ndc.product == "6441")
        #expect(ndc.package == "0")
        #expect(ndc.hyphenated == "50090-6441-0")
    }

    /// How we came to read a code is provenance, not identity. If it counted,
    /// a scan carrying AI (715) and one without it would key the same box two
    /// different ways, and the medication list would gain a duplicate on every
    /// refill.
    @Test("Confidence is not part of a code's identity")
    func confidenceIsNotIdentity() throws {
        let explicit = try #require(NationalDrugCode(hyphenated: "12345-6789-0", confidence: .explicit))
        let inferred = try #require(NationalDrugCode(hyphenated: "12345-6789-0", confidence: .inferred))
        #expect(explicit == inferred)
        #expect(explicit.hashValue == inferred.hashValue)
    }

    /// Ten bare digits are a 4-4-2, a 5-3-2 and a 5-4-1 at once. Picking one
    /// would be wrong two times in three, so Phase 1 declines and leaves the
    /// answer to the directory Phase 2 ships.
    @Test("AI (715) resolves only when it carries its own boundaries")
    func applicationIdentifier715() throws {
        #expect(NationalDrugCode(applicationIdentifier715: "12345-6789-0")?.format == .f541)
        #expect(NationalDrugCode(applicationIdentifier715: "123456789012")?.format == .f642)
        #expect(NationalDrugCode(applicationIdentifier715: "1234567890") == nil, "ten bare digits are ambiguous")
        #expect(NationalDrugCode(applicationIdentifier715: "12345678901") == nil, "the padded billing form")
        #expect(NationalDrugCode(applicationIdentifier715: "") == nil)
    }

    /// A stated NDC is the most specific identity a pack can carry, so it takes
    /// the key. An unsegmentable one costs the scan nothing — the GTIN is
    /// still there and still identifies the box.
    @Test("A resolvable AI (715) takes the key; an ambiguous one is harmless")
    func ndcTakesTheKey() throws {
        let resolvable = Payload.bytes(["0100312345678906", "71512345-6789-0"])
        let pack = try #require(Scan.read(resolvable))
        #expect(pack.ndc == NationalDrugCode(hyphenated: "12345-6789-0"))
        #expect(pack.key == .ndc(try #require(NationalDrugCode(hyphenated: "12345-6789-0"))))
        #expect(pack.ndc?.confidence == .explicit)

        let ambiguous = Payload.bytes(["0100312345678906", "7151234567890"])
        let fallback = try #require(Scan.read(ambiguous))
        #expect(fallback.ndc == nil)
        #expect(fallback.key == .gtin(try #require(GTIN("00312345678906"))))
    }
}


private extension ScannedPack {
    /// Whether a serial number found its way back onto the result.
    ///
    /// A structural check rather than a string search: it fails the moment a
    /// `serial` property appears on `ScannedPack`, which is the change this
    /// test exists to catch. Searching the description would instead depend on
    /// whether some other field happened to contain the same digits.
    static func carriesASerialField(_ pack: ScannedPack) -> Bool {
        Mirror(reflecting: pack).children.contains {
            ($0.label ?? "").lowercased().contains("serial")
        }
    }
}
