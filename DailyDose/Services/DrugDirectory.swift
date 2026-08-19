import Foundation

/// The FDA National Drug Code Directory, on the device, read-only.
///
/// This is the whole of the design's central promise made concrete: the US drug
/// database is public-domain data we **ship as a file**, so a scan never asks a
/// server what a medicine is. There is no request to secure, no key to embed, no
/// rate limit to respect, no international transfer to justify, and no rule to
/// break in a basement pharmacy with no signal. The answers are already here.
///
/// The file is `mmap`-ed rather than parsed: opening it costs one syscall and no
/// allocation, and a lookup touches two or three pages of a 7.9 MB file. Its
/// layout is specified in `Tools/NDC-INDEX-FORMAT.md` and produced by
/// `Tools/build-ndc-index.py`.
///
/// Everything here is defensive about the bytes it reads. A truncated download,
/// a half-written file, a resource that failed to copy — all of them must
/// produce "no answer", and the scan then falls back to reading the label, which
/// is what happens in every non-US market anyway.
struct DrugDirectory: Sendable {

    /// What the directory knows about one package.
    ///
    /// The strings are carried verbatim from the FDA and interpreted here, by
    /// the same code that reads a scanned label. One place where `"TABLET, FILM
    /// COATED"` becomes `.pill`, covered by one set of tests — rather than a
    /// build script and an app that could quietly disagree.
    struct Entry: Equatable, Sendable {
        /// The code the directory confirmed. `.explicit`: a matched candidate
        /// is no longer a guess, it is a product that exists.
        let ndc: NationalDrugCode
        /// The brand name, or the generic name when the record carries no
        /// brand — 21,710 of 137,198 do not.
        let name: String
        let genericName: String
        /// Exactly as the FDA publishes it: `"40 mg/1"`, `"12 [hp_X]/mL"`.
        /// Empty for a product with more than one active ingredient, where no
        /// single strength is the truth.
        let strengthText: String
        /// The FDA dosage form: `"TABLET, FILM COATED"`, `"INJECTION, SOLUTION"`.
        let dosageForm: String

        /// The form, read by the same detector the label scanner uses.
        var form: MedicationForm? { MedicationForm.detect(in: dosageForm) }

        /// The strength as structure — but only when the denominator is `1`.
        ///
        /// `"40 mg/1"` is forty milligrams in one tablet, which is what our
        /// amount-and-unit pair means. `"5 mg/mL"` is a concentration, and
        /// reading it as "5 mg" would put a number in the strength field that
        /// means something else entirely. Just over half of single-ingredient
        /// products are per-unit; the rest keep `strengthText` for display and
        /// leave the number unset rather than wrong.
        var strength: (amount: Double, unit: StrengthUnit)? {
            guard strengthText.hasSuffix("/1") else { return nil }
            let parsed = LabelScanParser.parse(String(strengthText.dropLast(2)))
            guard let amount = parsed.strengthAmount, let unit = parsed.strengthUnit else { return nil }
            return (amount, unit)
        }
    }

    // MARK: - Opening

    private let data: Data
    private let header: Header

    /// The FDA export this index was built from, as `yyyymmdd`. Shown in
    /// About → Data sources, because data with no date on it invites more
    /// trust than it has earned.
    var exportDate: Int { Int(header.exportDate) }
    var packageCount: Int { Int(header.packageCount) }

    /// The index shipped in the app bundle, or nil if it is not there.
    ///
    /// Nil is a supported state, not a crash: the app works everywhere without
    /// this file, and in every market except the US it has nothing to add.
    static let bundled: DrugDirectory? = {
        guard let url = Bundle.main.url(forResource: "ndc-index", withExtension: "ddndc") else {
            return nil
        }
        return DrugDirectory(contentsOf: url)
    }()

    init?(contentsOf url: URL) {
        // `.mappedIfSafe` — the kernel pages it in on demand and the whole file
        // never has to be resident. "IfSafe" declines to map from a volume that
        // could vanish underneath us, falling back to a normal read.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data)
    }

    init?(_ data: Data) {
        guard let header = Header(data) else { return nil }
        self.data = data
        self.header = header
    }

    // MARK: - Lookup

    /// The directory's record for an exact package code.
    ///
    /// The segmentation has to agree, not just the digits. `5009-0644-10` and
    /// `50090-6441-0` are the same ten digits and different medicines, and only
    /// one of them is a product that exists — answering "yes, here is the other
    /// one" would quietly undo the disambiguation this whole type is for.
    func entry(for ndc: NationalDrugCode) -> Entry? {
        guard let key = UInt64(ndc.digits) else { return nil }
        guard let slot = slot(forKey: key) else { return nil }
        return entry(at: slot, key: key, requiring: ndc.format)
    }

    /// What a scanned pack turns out to be, if the US directory knows it.
    ///
    /// Order matters and is the design's: a code the pack **stated** beats one
    /// we worked out from its GTIN, because it needed no inference at all.
    ///
    /// This resolves *content* — name, strength, form — and deliberately not
    /// identity. `ScannedPack.key` is left exactly as the barcode produced it:
    /// it is already stable and already matches two scans of the same box, and
    /// re-keying a medication once the directory can name it would orphan every
    /// row saved before this shipped.
    func resolve(_ pack: ScannedPack) -> Entry? {
        if let stated = pack.ndc, let entry = entry(for: stated) { return entry }
        guard let gtin = pack.gtin else { return nil }

        // At most one candidate can match: no two package codes in the whole
        // directory share a ten-digit form. So the first hit is the answer, and
        // a caller never has to choose.
        for candidate in NDCResolver.candidates(for: gtin) {
            if let entry = entry(for: candidate) { return entry }
        }
        return nil
    }

    // MARK: - Binary search

    /// The position of a key, or nil.
    ///
    /// The keys are sorted, so this is eighteen comparisons over 217k packages.
    /// The design called for "a single hash probe"; at this size the difference
    /// is unmeasurable, and a sorted array has no hash function to choose badly
    /// and no load factor to tune — the builder simply asserts the ordering.
    private func slot(forKey key: UInt64) -> Int? {
        var low = 0
        var high = Int(header.packageCount) - 1
        while low <= high {
            let middle = low + (high - low) / 2
            guard let candidate: UInt64 = read(at: Int(header.keysOffset) + middle * 8) else { return nil }
            if candidate == key { return middle }
            if candidate < key { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    private func entry(at slot: Int, key: UInt64, requiring wanted: NationalDrugCode.Format) -> Entry? {
        guard let productIndex: UInt32 = read(at: Int(header.packagesOffset) + slot * 4),
              productIndex < header.productCount,
              let formatByte: UInt8 = read(at: Int(header.formatsOffset) + slot),
              NationalDrugCode.Format.allCases.indices.contains(Int(formatByte))
        else { return nil }

        // The stored segmentation is the real one. A candidate that guessed a
        // different split named a different medicine, and is simply not found.
        let format = NationalDrugCode.Format.allCases[Int(formatByte)]
        guard format == wanted else { return nil }

        // Zero-padded back to full width: the leading zeros are meaning, and an
        // integer round trip drops them. The width comes from the format rather
        // than a literal 10, so the 12-digit form the FDA moves to in 2033
        // needs no change here.
        let segments = format.segments
        let width = segments.labeler + segments.product + segments.package
        let digits = String(format: "%0\(width)llu", key)
        guard let ndc = NationalDrugCode(digits: digits, format: format, confidence: .explicit)
        else { return nil }

        let base = Int(header.productsOffset) + Int(productIndex) * Self.productRecordSize
        guard let nameOffset: UInt32 = read(at: base),
              let nameLength: UInt16 = read(at: base + 4),
              let genericLength: UInt16 = read(at: base + 6),
              let genericOffset: UInt32 = read(at: base + 8),
              let strengthOffset: UInt32 = read(at: base + 12),
              let strengthLength: UInt16 = read(at: base + 16),
              let dosageFormLength: UInt16 = read(at: base + 18),
              let dosageFormOffset: UInt32 = read(at: base + 20)
        else { return nil }

        return Entry(
            ndc: ndc,
            name: string(offset: nameOffset, length: nameLength),
            genericName: string(offset: genericOffset, length: genericLength),
            strengthText: string(offset: strengthOffset, length: strengthLength),
            dosageForm: string(offset: dosageFormOffset, length: dosageFormLength)
        )
    }

    // MARK: - Raw reads

    private static let productRecordSize = 24

    /// A little-endian integer at a byte offset, or nil if it would run past
    /// the end. Every read in this type goes through here: the offsets come out
    /// of a file we did not write in this process, so none of them is trusted.
    private func read<T: FixedWidthInteger>(at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= data.count else { return nil }
        let value = data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        return T(littleEndian: value)
    }

    /// A UTF-8 string from the blob. Out-of-range or invalid bytes read as
    /// empty — a missing product name is a field the user fills in, where a
    /// trap here would be a crash while pointing a camera at a box.
    private func string(offset: UInt32, length: UInt16) -> String {
        guard length > 0 else { return "" }
        let start = Int(header.stringsOffset) + Int(offset)
        let end = start + Int(length)
        guard start >= Int(header.stringsOffset), end <= data.count,
              end <= Int(header.stringsOffset) + Int(header.stringsLength)
        else { return "" }
        return String(decoding: data[start..<end], as: UTF8.self)
    }

    // MARK: - Header

    /// The file's first 64 bytes, validated once at open.
    ///
    /// Everything is checked here — magic, version, and that every section
    /// lies inside the file at the size its counts imply — so a corrupt file is
    /// rejected at the door rather than discovered halfway through a lookup
    /// with a camera running.
    private struct Header {
        let exportDate: UInt32
        let packageCount: UInt32
        let productCount: UInt32
        let keysOffset: UInt32
        let packagesOffset: UInt32
        let formatsOffset: UInt32
        let productsOffset: UInt32
        let stringsOffset: UInt32
        let stringsLength: UInt32

        static let magic = Array("DDNDCIDX".utf8)
        static let size = 64
        static let supportedVersion: UInt32 = 1

        init?(_ data: Data) {
            guard data.count >= Self.size, data.prefix(8).elementsEqual(Self.magic) else { return nil }

            func word(_ offset: Int) -> UInt32 {
                data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            }
            guard word(8) == Self.supportedVersion else { return nil }

            exportDate = word(12)
            packageCount = word(16)
            productCount = word(20)
            keysOffset = word(24)
            packagesOffset = word(28)
            formatsOffset = word(32)
            productsOffset = word(36)
            stringsOffset = word(40)
            stringsLength = word(44)

            // Every section must fit, with its declared count, inside the file.
            let sections: [(UInt32, Int)] = [
                (keysOffset, Int(packageCount) * 8),
                (packagesOffset, Int(packageCount) * 4),
                (formatsOffset, Int(packageCount)),
                (productsOffset, Int(productCount) * DrugDirectory.productRecordSize),
                (stringsOffset, Int(stringsLength)),
            ]
            for (offset, length) in sections {
                guard offset >= UInt32(Self.size), Int(offset) + length <= data.count else { return nil }
            }
        }
    }
}
