import Foundation

/// A US National Drug Code, kept in the segmentation it was issued in.
///
/// Never an 11-character string. Two reasons, and both cost real money to
/// retrofit later:
///
/// * **The segmentation is meaning.** `1234567890` is a syntactically valid
///   4-4-2, 5-3-2 *and* 5-4-1 code, naming three different products. Flattening
///   it to digits throws away the only thing that distinguishes them, and the
///   11-digit billing form used by insurers is a padded derivative, not an NDC.
/// * **The format changes.** FDA's final rule of 5 March 2026 moves the NDC to
///   a uniform 12-digit 6-4-2 from 7 March 2033. Twelve digits do not fit in a
///   GTIN-12, so the `"3" + NDC-10 + check` embedding this app would otherwise
///   have baked in simply ends on that date.
struct NationalDrugCode: Sendable {

    /// The issued segmentations, plus the one that replaces them in 2033.
    enum Format: String, Sendable, CaseIterable {
        case f442, f532, f541, f642

        /// Digits in the labeler, product and package segments.
        var segments: (labeler: Int, product: Int, package: Int) {
            switch self {
            case .f442: (4, 4, 2)
            case .f532: (5, 3, 2)
            case .f541: (5, 4, 1)
            case .f642: (6, 4, 2)
            }
        }

        /// The one format with these segment lengths, if any.
        static func matching(labeler: Int, product: Int, package: Int) -> Format? {
            allCases.first { $0.segments == (labeler, product, package) }
        }
    }

    /// Whether the segmentation was *told* to us or *worked out* by us.
    ///
    /// Phase 1 only ever produces `.explicit`. `.inferred` exists so that when
    /// Phase 2 starts generating candidate splits from a GTIN, the UI has
    /// something to check before presenting a drug name as certain.
    enum Confidence: Sendable {
        /// The code carried its own boundaries, or the FDA directory confirmed them.
        case explicit
        /// We picked one of several readings of the same digits.
        case inferred
    }

    let labeler: String
    let product: String
    let package: String
    let format: Format
    let confidence: Confidence

    init?(labeler: String, product: String, package: String, confidence: Confidence) {
        guard labeler.isASCIIDigits, product.isASCIIDigits, package.isASCIIDigits,
              let format = Format.matching(
                labeler: labeler.count, product: product.count, package: package.count
              )
        else { return nil }
        self.labeler = labeler
        self.product = product
        self.package = package
        self.format = format
        self.confidence = confidence
    }

    /// Splits a run of digits at a format's segment boundaries.
    ///
    /// The format is an argument rather than something inferred, because there
    /// is nothing in the digits to infer it from: `1234567890` is a valid
    /// 4-4-2, 5-3-2 *and* 5-4-1 code naming three different products. Only
    /// `AI (715)`, which prints its own boundaries, reaches this today.
    init?(digits: String, format: Format, confidence: Confidence) {
        let (labeler, product, package) = format.segments
        guard digits.count == labeler + product + package, digits.isASCIIDigits else { return nil }
        self.init(
            labeler: String(digits.prefix(labeler)),
            product: String(digits.dropFirst(labeler).prefix(product)),
            package: String(digits.suffix(package)),
            confidence: confidence
        )
    }

    /// The same digits with the hyphens taken out — the form a GTIN embeds.
    var digits: String { labeler + product + package }

    /// `"50090-6441-0"` — the form the FDA publishes and the form we persist.
    var hyphenated: String { "\(labeler)-\(product)-\(package)" }

    /// Reads a hyphenated code, taking the segmentation from the hyphens.
    ///
    /// The four formats have four distinct length patterns, so the hyphens
    /// alone determine the format — there is no separate tag that could drift
    /// out of agreement with the digits.
    init?(hyphenated: String, confidence: Confidence = .explicit) {
        let parts = hyphenated.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        self.init(
            labeler: String(parts[0]), product: String(parts[1]), package: String(parts[2]),
            confidence: confidence
        )
    }
}

// MARK: - Identity

extension NationalDrugCode: Hashable {
    /// `confidence` is deliberately not part of identity.
    ///
    /// It records *how we came to read* the code, which is provenance, not the
    /// code. If it counted, one scan that carried AI (715) and one that did not
    /// would produce two keys for the same box — and the user would watch their
    /// medication list grow a duplicate every time they bought a new pack.
    static func == (lhs: NationalDrugCode, rhs: NationalDrugCode) -> Bool {
        lhs.labeler == rhs.labeler
            && lhs.product == rhs.product
            && lhs.package == rhs.package
            && lhs.format == rhs.format
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(labeler)
        hasher.combine(product)
        hasher.combine(package)
        hasher.combine(format)
    }
}

// MARK: - AI (715)

extension NationalDrugCode {
    /// Reads the NDC that GS1 AI (715) carries explicitly.
    ///
    /// AI (715) removes the *inference* — we no longer have to guess that a
    /// GTIN embeds an NDC — but it does not always remove the *ambiguity*. Ten
    /// bare digits are still a 4-4-2, a 5-3-2 and a 5-4-1 at once, and only the
    /// FDA directory can say which; eleven are the padded billing form, whose
    /// inserted zero cannot be located again from the digits. So we accept the
    /// readings that carry their own boundaries — hyphenated, or the 12-digit
    /// 6-4-2 that has only one — and return nil for the rest rather than pick a
    /// segmentation that would be wrong two times in three.
    ///
    /// A nil here is not a rejection of the scan. The pack still has a GTIN, an
    /// expiry and an identity; it simply has no resolvable NDC until Phase 2
    /// ships the directory.
    init?(applicationIdentifier715 raw: String) {
        if raw.contains("-") {
            self.init(hyphenated: raw, confidence: .explicit)
            return
        }
        guard raw.count == 12, raw.isASCIIDigits else { return nil }
        self.init(
            labeler: String(raw.prefix(6)),
            product: String(raw.dropFirst(6).prefix(4)),
            package: String(raw.suffix(2)),
            confidence: .explicit
        )
    }
}
