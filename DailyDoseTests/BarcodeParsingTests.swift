import Foundation
import Testing
@testable import DailyDose

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
    /// would be wrong two times in three, so we decline: an NDC is filled only
    /// when the pack prints its own boundaries.
    @Test("AI (715) resolves only when it carries its own boundaries")
    func applicationIdentifier715() throws {
        #expect(NationalDrugCode(applicationIdentifier715: "12345-6789-0")?.format == .f541)
        #expect(NationalDrugCode(applicationIdentifier715: "123456789012")?.format == .f642)
        #expect(NationalDrugCode(applicationIdentifier715: "1234567890") == nil, "ten bare digits are ambiguous")
        #expect(NationalDrugCode(applicationIdentifier715: "12345678901") == nil, "the padded billing form")
        #expect(NationalDrugCode(applicationIdentifier715: "") == nil)
    }
}
