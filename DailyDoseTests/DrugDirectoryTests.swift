import Foundation
import Testing
@testable import DailyDose

/// Builds a `DDNDCIDX` index in memory, so every test here is pure — no
/// bundle, no 7.5 MB resource, no file system.
///
/// It is a second implementation of the format, which is the point: if the
/// Swift reader and the Python builder ever drift apart, one of them has to be
/// wrong about something these tests can see. `bundledIndexMatchesTheReader`
/// then checks the real shipped file against the same reader.
private struct IndexBuilder {
    struct Product {
        var name: String
        var generic: String
        var strength: String
        var dosageForm: String
    }

    private(set) var products: [Product] = []
    /// key → (product index, format byte)
    private(set) var packages: [UInt64: (Int, UInt8)] = [:]
    var exportDate: UInt32 = 20_260_818

    mutating func add(_ product: Product, packages codes: [(UInt64, NationalDrugCode.Format)]) {
        let index = products.count
        products.append(product)
        for (key, format) in codes {
            let byte = UInt8(NationalDrugCode.Format.allCases.firstIndex(of: format) ?? 0)
            packages[key] = (index, byte)
        }
    }

    func build() -> Data {
        var blob = Data()
        var offsets: [String: (UInt32, UInt16)] = [:]
        func intern(_ value: String) -> (UInt32, UInt16) {
            guard !value.isEmpty else { return (0, 0) }
            if let existing = offsets[value] { return existing }
            let bytes = Array(value.utf8)
            let entry = (UInt32(blob.count), UInt16(bytes.count))
            blob.append(contentsOf: bytes)
            offsets[value] = entry
            return entry
        }

        var productSection = Data()
        for product in products {
            let name = intern(product.name)
            let generic = intern(product.generic)
            let strength = intern(product.strength)
            let form = intern(product.dosageForm)
            productSection.append(le(name.0))
            productSection.append(le(name.1))
            productSection.append(le(generic.1))
            productSection.append(le(generic.0))
            productSection.append(le(strength.0))
            productSection.append(le(strength.1))
            productSection.append(le(form.1))
            productSection.append(le(form.0))
        }

        let keys = packages.keys.sorted()
        var keySection = Data(), packageSection = Data(), formatSection = Data()
        for key in keys {
            keySection.append(le(key))
            guard let entry = packages[key] else { continue }
            packageSection.append(le(UInt32(entry.0)))
            formatSection.append(entry.1)
        }

        let headerSize = 64
        let keysOffset = UInt32(headerSize)
        let packagesOffset = keysOffset + UInt32(keySection.count)
        let formatsOffset = packagesOffset + UInt32(packageSection.count)
        let productsOffset = formatsOffset + UInt32(formatSection.count)
        let stringsOffset = productsOffset + UInt32(productSection.count)

        var header = Data("DDNDCIDX".utf8)
        for word in [UInt32(1), exportDate, UInt32(keys.count), UInt32(products.count),
                     keysOffset, packagesOffset, formatsOffset, productsOffset,
                     stringsOffset, UInt32(blob.count)] {
            header.append(le(word))
        }
        header.append(Data(repeating: 0, count: headerSize - header.count))

        return header + keySection + packageSection + formatSection + productSection + blob
    }

    private func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

private extension IndexBuilder.Product {
    static let atorvastatin = Self(
        name: "ATORVASTATIN CALCIUM", generic: "ATORVASTATIN CALCIUM",
        strength: "40 mg/1", dosageForm: "TABLET, FILM COATED"
    )
    static let amoxicillinSuspension = Self(
        name: "Amoxil", generic: "amoxicillin",
        strength: "250 mg/5mL", dosageForm: "POWDER, FOR SUSPENSION"
    )
    static let combination = Self(
        name: "Lisinopril and Hydrochlorothiazide", generic: "lisinopril and hydrochlorothiazide",
        strength: "", dosageForm: "TABLET"
    )
}

// MARK: - GTIN → NDC

@Suite("NDC resolution")
struct NDCResolverTests {

    /// The convention, worked through: `50090-6441-0` is package `5009064410`,
    /// so its GTIN-12 is `"3" + those ten + a mod-10 check`, padded to
    /// GTIN-14 with the two zeros that carry no information.
    @Test("A US GTIN yields the ten NDC digits it embeds")
    func embeddedDigits() throws {
        let gtin = try #require(GTIN("00350090644104"))
        #expect(NDCResolver.embeddedDigits(in: gtin) == "5009064410")
    }

    /// Not an error, and not a rare one: most of the world's GTINs are not
    /// NDC-derived, and every German, British and EU pack reaching here has
    /// nothing for the US directory to look up.
    @Test("A GTIN that embeds no NDC yields nothing, quietly")
    func nonNDCGTINs() throws {
        // A German NTIN — starts 04150, not 003.
        #expect(NDCResolver.embeddedDigits(in: try #require(GTIN("04150123456782"))) == nil)
        // A GTIN-12 whose first digit is not 3.
        #expect(NDCResolver.embeddedDigits(in: try #require(GTIN("00212345678909"))) == nil)
        // A GTIN-13 or -14 with a real indicator digit: not a "00" packet.
        #expect(NDCResolver.embeddedDigits(in: try #require(GTIN("10312345678903"))) == nil)
    }

    /// Three readings of one string of digits, three different medicines. This
    /// is the ambiguity the whole directory exists to settle.
    @Test("Three candidate segmentations are generated, all marked inferred")
    func threeCandidates() throws {
        let gtin = try #require(GTIN("00350090644104"))
        let candidates = NDCResolver.candidates(for: gtin)

        #expect(candidates.count == 3)
        #expect(candidates.map(\.hyphenated).sorted() == ["5009-0644-10", "50090-644-10", "50090-6441-0"])
        #expect(candidates.allSatisfy { $0.confidence == .inferred })
        // The 12-digit format cannot come from a GTIN-12 — which is exactly
        // why the convention ends when it takes effect in 2033.
        #expect(!candidates.contains { $0.format == .f642 })
    }

    @Test("A GTIN with no embedded NDC produces no candidates")
    func noCandidates() throws {
        #expect(NDCResolver.candidates(for: try #require(GTIN("04150123456782"))).isEmpty)
    }
}

// MARK: - The directory

@Suite("Drug directory")
struct DrugDirectoryTests {

    private func directory() throws -> DrugDirectory {
        var builder = IndexBuilder()
        builder.add(.atorvastatin, packages: [(5_009_064_410, .f541)])
        builder.add(.amoxicillinSuspension, packages: [(6_058_003_450, .f532)])
        builder.add(.combination, packages: [(1_234_567_890, .f442)])
        return try #require(DrugDirectory(builder.build()))
    }

    @Test("A package code resolves to its product")
    func exactLookup() throws {
        let directory = try directory()
        let ndc = try #require(NationalDrugCode(hyphenated: "50090-6441-0"))
        let entry = try #require(directory.entry(for: ndc))

        #expect(entry.name == "ATORVASTATIN CALCIUM")
        #expect(entry.ndc.hyphenated == "50090-6441-0")
        #expect(entry.form == .pill)
        // A directory match is no longer a guess: it is a product that exists.
        #expect(entry.ndc.confidence == .explicit)
    }

    @Test("A code the directory has never heard of resolves to nothing")
    func unlistedProduct() throws {
        let directory = try directory()
        let unlisted = try #require(NationalDrugCode(hyphenated: "99999-9999-9"))
        #expect(directory.entry(for: unlisted) == nil)
    }

    /// The end-to-end path: a scanned US pack, through candidate generation,
    /// to a name the editor can use. Exactly one of the three candidates is a
    /// real product, so the answer is never a choice.
    @Test("A scanned GTIN resolves through exactly one candidate")
    func resolvesFromGTIN() throws {
        let directory = try directory()
        let gtin = try #require(GTIN("00350090644104"))
        let pack = ScannedPack(
            key: .gtin(gtin), gtin: gtin, pzn: nil, ndc: nil,
            batch: nil, expiry: nil, syntax: .gs1
        )

        let entry = try #require(directory.resolve(pack))
        #expect(entry.name == "ATORVASTATIN CALCIUM")
        #expect(entry.ndc.hyphenated == "50090-6441-0")
        #expect(entry.ndc.format == .f541)

        // The other two readings of the same digits are not products.
        let others = NDCResolver.candidates(for: gtin).filter { $0.format != .f541 }
        #expect(others.count == 2)
        #expect(others.allSatisfy { directory.entry(for: $0) == nil })
    }

    /// AI (715) carries the NDC outright, so it needs no inference at all —
    /// and is consulted before the GTIN is even reduced.
    @Test("A stated NDC is preferred over one inferred from the GTIN")
    func statedNDCWins() throws {
        let directory = try directory()
        // A GTIN whose embedded digits name atorvastatin, and a stated NDC that
        // names the suspension. The stated one must win.
        let gtin = try #require(GTIN("00350090644104"))
        let stated = try #require(NationalDrugCode(hyphenated: "60580-034-50"))
        let pack = ScannedPack(
            key: .ndc(stated), gtin: gtin, pzn: nil, ndc: stated,
            batch: nil, expiry: nil, syntax: .gs1
        )
        #expect(directory.resolve(pack)?.name == "Amoxil")
    }

    /// Resolution fills in *content*, never identity. `ScannedPack.key` is
    /// already stable and already matches two scans of the same box; re-keying
    /// a medication once the directory can name it would orphan every row
    /// saved before the directory shipped.
    @Test("Resolving a pack does not change how it is keyed")
    func resolutionDoesNotRekey() throws {
        let directory = try directory()
        let gtin = try #require(GTIN("00350090644104"))
        let pack = ScannedPack(
            key: .gtin(gtin), gtin: gtin, pzn: nil, ndc: nil,
            batch: nil, expiry: nil, syntax: .gs1
        )
        #expect(directory.resolve(pack) != nil)
        #expect(pack.key == .gtin(gtin), "the key is the barcode's, not the directory's")
    }

    /// A German pack has nothing for the US directory, which is the ordinary
    /// case outside one market and must cost nothing.
    @Test("A pack with no GTIN and no NDC resolves to nothing")
    func nothingToResolve() throws {
        let directory = try directory()
        let pzn = try #require(PZN("12345678"))
        let pack = ScannedPack(
            key: .pzn(pzn), gtin: nil, pzn: pzn, ndc: nil,
            batch: "1A234B5", expiry: nil, syntax: .ifaPPN
        )
        #expect(directory.resolve(pack) == nil)
    }

    // MARK: Strength

    /// `"40 mg/1"` is forty milligrams in one tablet — what an amount and a
    /// unit mean. `"250 mg/5mL"` is a concentration, and reading it as "250 mg"
    /// would put a number in the strength field that means something else.
    @Test("Only a per-unit strength becomes a number")
    func strengthDenominator() throws {
        let directory = try directory()
        let tabletNDC = try #require(NationalDrugCode(hyphenated: "50090-6441-0"))
        let tablet = try #require(directory.entry(for: tabletNDC))
        let strength = try #require(tablet.strength)
        #expect(strength.amount == 40)
        #expect(strength.unit == .mg)

        let suspensionNDC = try #require(NationalDrugCode(hyphenated: "60580-034-50"))
        let suspension = try #require(directory.entry(for: suspensionNDC))
        #expect(suspension.strength == nil, "a concentration is not a per-dose strength")
        // But the FDA's own wording survives for display.
        #expect(suspension.strengthText == "250 mg/5mL")
    }

    /// A combination tablet has two strengths and neither is the truth alone,
    /// so the builder leaves the field empty rather than storing the first.
    @Test("A combination product carries no strength at all")
    func combinationProduct() throws {
        let directory = try directory()
        let combinationNDC = try #require(NationalDrugCode(hyphenated: "1234-5678-90"))
        let entry = try #require(directory.entry(for: combinationNDC))
        #expect(entry.strengthText.isEmpty)
        #expect(entry.strength == nil)
        #expect(entry.form == .pill)
    }

    // MARK: Robustness

    /// A truncated download, a half-written file, a resource that failed to
    /// copy. Every one must be "no directory" — never a crash while a camera
    /// is running.
    @Test("A corrupt or truncated index is refused at the door")
    func corruptFilesAreRefused() throws {
        var builder = IndexBuilder()
        builder.add(.atorvastatin, packages: [(5_009_064_410, .f541)])
        let good = builder.build()

        #expect(DrugDirectory(Data()) == nil)
        #expect(DrugDirectory(Data("not an index at all".utf8)) == nil)
        #expect(DrugDirectory(good.prefix(32)) == nil, "header cut in half")
        #expect(DrugDirectory(good.prefix(good.count - 8)) == nil, "sections run past the end")

        // Right magic, wrong version: a file from a future build.
        var wrongVersion = good
        wrongVersion.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(99).littleEndian) { Data($0) })
        #expect(DrugDirectory(wrongVersion) == nil)

        // A count that claims more packages than the file can hold.
        var wrongCount = good
        wrongCount.replaceSubrange(16..<20, with: withUnsafeBytes(of: UInt32(1_000_000).littleEndian) { Data($0) })
        #expect(DrugDirectory(wrongCount) == nil)
    }

    /// Every slot must be findable, and nothing between them.
    @Test("Binary search finds every key and invents none")
    func binarySearchIsExact() throws {
        var builder = IndexBuilder()
        let keys: [UInt64] = (0..<200).map { UInt64($0) * 7919 + 1_000_000_000 }
        for (index, key) in keys.enumerated() {
            builder.add(
                .init(name: "Product \(index)", generic: "", strength: "", dosageForm: "TABLET"),
                packages: [(key, .f541)]
            )
        }
        let directory = try #require(DrugDirectory(builder.build()))

        for (index, key) in keys.enumerated() {
            let ndc = try #require(NationalDrugCode(
                digits: String(format: "%010llu", key), format: .f541, confidence: .inferred
            ))
            #expect(directory.entry(for: ndc)?.name == "Product \(index)")
        }
        // The gaps between them are not products.
        for key in keys.map({ $0 + 1 }) {
            let ndc = try #require(NationalDrugCode(
                digits: String(format: "%010llu", key), format: .f541, confidence: .inferred
            ))
            #expect(directory.entry(for: ndc) == nil)
        }
    }
}

// MARK: - The shipped file

@Suite("Bundled drug directory")
struct BundledDirectoryTests {

    /// The 7.5 MB resource the app actually ships, opened by the reader that
    /// actually reads it.
    ///
    /// The builder is Python and the reader is Swift, so nothing but a test
    /// like this can catch the two drifting apart — a field swapped in one and
    /// not the other produces a file that opens cleanly and answers wrongly.
    @Test("The bundled index opens and answers")
    func bundledIndexMatchesTheReader() throws {
        let directory = try #require(
            DrugDirectory.bundled,
            "ndc-index.ddndc is missing from the bundle — rebuild it with Tools/build-ndc-index.py"
        )

        #expect(directory.packageCount > 200_000, "the real directory is 217k packages")
        #expect(directory.exportDate > 20_260_000, "and carries the date it was exported")

        // A real product, from the record the design document itself cites.
        let knownNDC = try #require(NationalDrugCode(hyphenated: "50090-6441-0"))
        let entry = try #require(directory.entry(for: knownNDC))
        #expect(entry.name.uppercased().contains("ATORVASTATIN"))
        #expect(entry.strengthText == "40 mg/1")
        #expect(entry.form == .pill)
        let strength = try #require(entry.strength)
        #expect(strength.amount == 40)
        #expect(strength.unit == .mg)

        // And the whole path, from a barcode a US pharmacy would print.
        let gtin = try #require(GTIN("00350090644104"))
        let pack = ScannedPack(
            key: .gtin(gtin), gtin: gtin, pzn: nil, ndc: nil,
            batch: nil, expiry: nil, syntax: .gs1
        )
        #expect(directory.resolve(pack)?.ndc.hyphenated == "50090-6441-0")
    }
}
