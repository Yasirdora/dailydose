import Foundation
import Testing
@testable import DailyDose

/// The printed transcription a pack carries beside its barcode.
///
/// Every vector here is text, not bytes, which is the point of the change these
/// tests came with: the parenthesised form marks every field boundary, so the
/// whole class of "a separator went missing and two fields merged" bugs cannot
/// arise. What is left to get wrong is check digits and dates, and those are
/// pinned against published values elsewhere.
private enum HRI {
    static let calendar = Fixture.calendar()

    /// Read on a fixed day: the expiry century window slides with the current
    /// year, so a test that used `Date.now` would start failing on its own.
    static func read(_ text: String, on day: Date = Fixture.date(2026, 8, 19)) -> ScannedPack? {
        HRIParser.parse(text, now: day, calendar: calendar)
    }

    static func parts(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: date)
    }

    /// Transcribed from a real pack during device testing — the line whose
    /// misreading as a medication *name* prompted this whole simplification.
    static let devicePack = "(01)05437654786045(17)210212(10)ABC123"
}

@Suite("Human-readable barcode text")
struct HRIParserTests {

    /// The device vector, end to end. GTIN check digit 5, expiry 12 Feb 2021.
    @Test("A printed GS1 transcription yields GTIN, expiry and batch")
    func devicePack() throws {
        let pack = try #require(HRI.read(HRI.devicePack))

        #expect(pack.gtin?.value == "05437654786045")
        #expect(pack.key == .gtin(try #require(GTIN("05437654786045"))))
        #expect(HRI.parts(try #require(pack.expiry).day) == DateComponents(year: 2021, month: 2, day: 12))
        #expect(pack.batch == "ABC123")
    }

    /// OCR sets this text with the spacing the encoding does not have, and
    /// across several lines when the box is small.
    @Test("Spacing and line breaks between fields are tolerated")
    func whitespaceTolerated() throws {
        let spaced = try #require(HRI.read("(01) 05437654786045 (17) 210212 (10) ABC123"))
        let wrapped = try #require(HRI.read("(01)05437654786045\n(17)210212\n(10)ABC123"))
        let tight = try #require(HRI.read(HRI.devicePack))
        #expect(spaced == tight)
        #expect(wrapped == tight)
    }

    /// The serial is read — it is printed among the fields we do want — and
    /// then dropped. It identifies one physical box, which makes it a tracking
    /// identifier with no use here.
    @Test("A printed serial is read and then discarded")
    func serialIsDiscarded() throws {
        let pack = try #require(HRI.read("(01)05437654786045(21)SN12345678(10)ABC123(17)210212"))
        #expect(pack.batch == "ABC123", "the fields around the serial still land")
        #expect(!Mirror(reflecting: pack).children.contains {
            ($0.label ?? "").lowercased().contains("serial")
        }, "the serial must not survive parsing")
    }

    /// GS1 CSET-82 is case-sensitive, so `"ab12"` and `"AB12"` are different
    /// lots. Tidying the case would make a recall check quietly wrong.
    @Test("A batch keeps its case exactly")
    func batchCaseIsPreserved() throws {
        #expect(try #require(HRI.read("(01)05437654786045(10)aB12cD")).batch == "aB12cD")
    }

    /// `DD = 00` means the last day of that month, and `ExpiryDate` already
    /// knows it — this only checks the printed form reaches the same code.
    @Test("Day 00 resolves to the end of the month")
    func endOfMonth() throws {
        let pack = try #require(HRI.read("(01)05437654786045(17)250200"))
        let expiry = try #require(pack.expiry)
        #expect(HRI.parts(expiry.day) == DateComponents(year: 2025, month: 2, day: 28))
        #expect(expiry.isEndOfMonth)
    }

    /// An identifier we do not know costs us that field and nothing else: the
    /// next parenthesis says where it ends. The raw-payload parser had to
    /// reject one, because without its length it could not find the next field.
    @Test("An unknown application identifier is skipped, not fatal")
    func unknownIdentifierIsSkipped() throws {
        let pack = try #require(HRI.read("(01)05437654786045(240)XYZ999(17)210212"))
        #expect(pack.gtin?.value == "05437654786045")
        #expect(HRI.parts(try #require(pack.expiry).day) == DateComponents(year: 2021, month: 2, day: 12))
    }

    /// A German pack in NTIN syntax prints an ordinary GS1 transcription, and
    /// the PZN rides inside the GTIN.
    @Test("An NTIN transcription yields the PZN inside it")
    func ntinYieldsPZN() throws {
        let pack = try #require(HRI.read("(01)04150123456782(17)250600(10)LOT9"))
        #expect(pack.pzn?.value == "12345678")
        #expect(pack.key == .pzn(try #require(PZN("12345678"))))
    }

    /// A stated NHRN beats one inferred from the GTIN — it is what the pack
    /// says about itself.
    @Test("A stated NHRN outranks the one embedded in the GTIN")
    func statedNHRNWins() throws {
        let pack = try #require(HRI.read("(01)04150123456782(710)27580899"))
        #expect(pack.pzn?.value == "27580899")
    }

    /// `AI (715)` prints its own segmentation, so the US code needs no
    /// inference and takes the key.
    @Test("A resolvable AI (715) takes the key; an ambiguous one is harmless")
    func statedNDC() throws {
        let resolvable = try #require(HRI.read("(01)00312345678906(715)12345-6789-0"))
        let ndc = try #require(NationalDrugCode(hyphenated: "12345-6789-0"))
        #expect(resolvable.ndc == ndc)
        #expect(resolvable.key == .ndc(ndc))

        // Ten bare digits are three codes at once; declining costs nothing,
        // because the GTIN still identifies the box.
        let ambiguous = try #require(HRI.read("(01)00312345678906(715)1234567890"))
        #expect(ambiguous.ndc == nil)
        #expect(ambiguous.key == .gtin(try #require(GTIN("00312345678906"))))
    }

    /// Malformed input is the normal case when a camera is involved. Every one
    /// of these must be nil, and none may crash.
    @Test("Malformed transcriptions are refused rather than half-read")
    func malformed() {
        let cases: [(String, String)] = [
            ("empty", ""),
            ("prose", "Metformin 500 mg tablets"),
            ("no identifiers", "05437654786045 210212"),
            ("a GTIN with a wrong check digit", "(01)05437654786046"),
            ("a GTIN of the wrong length", "(01)0543765478604"),
            ("a non-numeric GTIN", "(01)0543765478604X"),
            ("expiry that is not six digits", "(01)05437654786045(17)2102"),
            ("expiry with month 13", "(01)05437654786045(17)211301"),
            ("expiry with 31 February", "(01)05437654786045(17)210231"),
            ("an empty batch", "(01)05437654786045(10)"),
            ("an over-long batch", "(01)05437654786045(10)ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
            ("a repeated identifier", "(01)05437654786045(17)210212(17)210213"),
            ("a stated PZN with a wrong check digit", "(01)05437654786045(710)12345679"),
            ("no product code at all", "(17)210212(10)ABC123"),
            ("only an unknown identifier", "(240)XYZ999"),
        ]
        for (label, text) in cases {
            #expect(HRI.read(text) == nil, "\(label) should be refused")
        }
    }

    /// German packs print the same data in a labelled form — `PZN:`,
    /// `Ch.-B.:`, `Verw. bis:`. We have not observed one, so it is deliberately
    /// unimplemented rather than guessed at: a format written from memory would
    /// look like it worked until a real box disagreed with it.
    ///
    /// This test documents the gap and passes. When a real German transcription
    /// arrives, it becomes the vector.
    @Test("The German labelled form is not read yet — a known gap")
    func germanLabelledFormIsNotYetRead() {
        let labelled = "PZN: 03752864  Ch.-B.: 1A234B5  Verw. bis: 2027-06"
        #expect(HRI.read(labelled) == nil, "unimplemented, and honest about it")
        #expect(!HRIParser.isTranscription(labelled), "so it is not mistaken for the GS1 form either")
    }
}

@Suite("Barcode text is never a name")
struct BarcodeTextIsNotANameTests {

    /// The observed failure: a pack's own printed transcription arrived as the
    /// medication's name. The boilerplate filter let it through because the
    /// truncated tail carried a serial with letters in it, which reads as an
    /// ordinary word.
    @Test("The transcription observed on device is refused as a name")
    func deviceTranscriptionIsNotAName() {
        let observed = "(01) 05437654786045 (17) 210212 (10)"
        #expect(HRIParser.isTranscription(observed))
        #expect(LabelScanParser.parse(observed).name.isEmpty)
        #expect(LabelScanParser.parse(HRI.devicePack).name.isEmpty)
    }

    /// Opening with an identifier is enough on its own; otherwise it takes two.
    @Test("One leading identifier, or two anywhere, marks a transcription")
    func shapeRules() {
        #expect(HRIParser.isTranscription("(01)05437654786045"))
        #expect(HRIParser.isTranscription("  (17)210212"))
        #expect(HRIParser.isTranscription("lot (10)ABC123 exp (17)210212"))
        // A single identifier that does not open the line is not enough.
        #expect(!HRIParser.isTranscription("Take (2) tablets daily"))

        // The deliberate over-reach: a line *opening* with a parenthesised
        // number is treated as a transcription whatever follows it, so a pack
        // that printed "(30) tablets" loses that line as a name candidate. The
        // cost is an empty name the user fills; the alternative is a barcode
        // saved as a medication's name, which they would not re-read.
        #expect(HRIParser.isTranscription("(30) tablets"))
    }

    /// A parenthesised aside on a real label is not digits, so it cannot trip
    /// the rule — and a medication whose name simply contains brackets keeps it.
    @Test("Ordinary label text with brackets is still a name")
    func ordinaryBracketsSurvive() {
        #expect(!HRIParser.isTranscription("Paracetamol (Acetaminophen) 500 mg"))
        // Kept as a name. The closing bracket is trimmed by the existing
        // punctuation trim, which predates this work and is not what these
        // tests are about — the property that matters is that a real product
        // name with brackets in it survives at all.
        let name = LabelScanParser.parse("Paracetamol (Acetaminophen) 500 mg").name
        #expect(name.hasPrefix("Paracetamol"))
        #expect(name.localizedCaseInsensitiveContains("acetaminophen"))

        #expect(!HRIParser.isTranscription("Ventolin 100 micrograms"))
        #expect(LabelScanParser.parse("METFORMIN HCL 500 MG TABLET").name == "Metformin HCL")
    }
}
