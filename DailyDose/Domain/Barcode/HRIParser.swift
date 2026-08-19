import Foundation

/// Reads the human-readable text a medicine pack prints beside its barcode.
///
/// `(01)05437654786045(17)210212(10)ABC123` is the same data a GS1 DataMatrix
/// carries, printed in type the camera can already read. Under the EU Falsified
/// Medicines Directive a prescription pack must carry the product code, batch,
/// expiry and serial in human-readable form unless the pack is too small; US
/// DSCSA packs carry the same. So there is no need to decode the symbol to
/// learn what the symbol says.
///
/// This is the *easier* half of the problem, not a fallback for it. The
/// parentheses mark every field boundary explicitly, which removes the single
/// ambiguity that made the raw-payload path fragile: a variable-length field
/// there runs to a `GS` (0x1D) byte that scanners drop routinely, and a lost
/// separator merges a batch number into whatever followed it with nothing in
/// the data to show the loss. Here the boundary is printed.
///
/// One format is implemented: the parenthesised GS1 form. German packs also
/// print a labelled form (`PZN:`, `Ch.-B.:`, `Verw. bis:`); we have not
/// observed one, so it is deliberately absent rather than guessed at — see
/// `HRIParserTests.germanLabelledFormIsNotYetRead`.
enum HRIParser {

    /// An element and its value, in print order.
    private static let elementPattern = #"\((\d{2,4})\)([^(]*)"#

    private static let elementRegex = try? NSRegularExpression(pattern: elementPattern)

    /// Whether the text is a barcode transcription rather than prose.
    ///
    /// Used by `LabelScanParser` to keep this text out of the medication *name*
    /// field. A real pack put `(01) 05437654786045 (17) 210212 (10)…` on the
    /// box in small type, the OCR read it as a line like any other, and the
    /// name-boilerplate filter let it through — the truncated tail contained a
    /// serial with letters in it, which reads as a word. Shape is the reliable
    /// test, not vocabulary.
    static func isTranscription(_ text: String) -> Bool {
        let flat = text.singleLine
        guard let elementRegex else { return false }
        let range = NSRange(flat.startIndex..., in: flat)
        // Opening with an identifier is enough on its own; otherwise it takes
        // two, so an ordinary parenthesised aside — "(500 mg)" is not matched
        // by `\(\d{2,4}\)`, but "(30) tablets" would be — cannot trip it.
        if flat.range(of: #"^\s*\(\d{2,4}\)"#, options: .regularExpression) != nil { return true }
        return elementRegex.numberOfMatches(in: flat, range: range) >= 2
    }

    /// The pack this text describes, or nil.
    ///
    /// `now` and `calendar` are parameters rather than `Date.now` and
    /// `.current` because the expiry century window depends on today's date,
    /// and a test that depends on today's date is one that starts failing on
    /// its own one morning.
    static func parse(_ text: String, now: Date = .now, calendar: Calendar = .current) -> ScannedPack? {
        guard let elements = elements(in: text) else { return nil }
        return pack(from: elements, now: now, calendar: calendar)
    }

    // MARK: - Tokenising

    /// Every `(nn)value` in print order, or nil if the text is not a
    /// transcription or one of its values is impossible.
    ///
    /// An identifier we do not know is **skipped**, not fatal. The raw-payload
    /// parser had to reject one, because without knowing its length it could
    /// not find where the next field began; here the next parenthesis says.
    /// Rejecting a whole scan over a field we have no use for would throw away
    /// a perfectly good expiry date.
    static func elements(in text: String) -> [GS1Parser.Element]? {
        let flat = text.singleLine
        guard let elementRegex else { return nil }

        var elements: [GS1Parser.Element] = []
        var seen: Set<String> = []
        let matches = elementRegex.matches(in: flat, range: NSRange(flat.startIndex..., in: flat))
        guard !matches.isEmpty else { return nil }

        for match in matches {
            guard let aiRange = Range(match.range(at: 1), in: flat),
                  let valueRange = Range(match.range(at: 2), in: flat)
            else { return nil }

            let ai = String(flat[aiRange])
            guard GS1Parser.isKnown(ai) else { continue }

            // OCR sets these with spaces the encoding does not have — "(01) 054…".
            // Only the outside is trimmed: CSET-82 has no space in it, so an
            // inner one is a misread and `validate` will refuse it.
            let value = flat[valueRange].trimmingCharacters(in: .whitespaces)

            // A repeated identifier is two answers to one question — two expiry
            // dates, two batch numbers — with nothing to choose between them.
            guard seen.insert(ai).inserted else { return nil }
            guard let element = GS1Parser.validate(ai: ai, value: value) else { return nil }
            elements.append(element)
        }

        return elements.isEmpty ? nil : elements
    }

    // MARK: - Interpretation

    private static func pack(
        from elements: [GS1Parser.Element], now: Date, calendar: Calendar
    ) -> ScannedPack? {
        func value(_ ai: String) -> String? { elements.first { $0.ai == ai }?.value }

        // AI (21), the serial, is read and then deliberately thrown away.
        // Reading it is not optional — it is printed among the fields we do
        // want — but keeping it would be. It is unique to one physical box,
        // which makes it a tracking identifier, and nothing in this app asks
        // *which box*: only which medicine, and when it expires. Please do not
        // helpfully restore it to `ScannedPack`.

        guard let gtin = read(value("01"), GTIN.init) else { return nil }
        guard let expiry = read(value("17"), {
            ExpiryDate.parse($0, encoding: .gs1, reference: now, calendar: calendar)
        }) else { return nil }
        guard let statedPZN = read(value("710"), PZN.init) else { return nil }

        // AI (715) states the NDC rather than letting us infer it, but stating
        // it is not the same as segmenting it — see `NationalDrugCode`. An
        // unsegmentable value leaves `ndc` nil and costs the reading nothing.
        let ndc = value("715").flatMap(NationalDrugCode.init(applicationIdentifier715:))

        // The stated NHRN beats the one embedded in the GTIN: it is what the
        // pack says about itself, rather than what we read out of its number.
        let pzn = statedPZN ?? gtin?.pzn

        guard let key = preferredKey(ndc: ndc, pzn: pzn, gtin: gtin) else { return nil }

        return ScannedPack(
            key: key, gtin: gtin, pzn: pzn, ndc: ndc,
            batch: value("10"), expiry: expiry
        )
    }

    /// The most specific identity the pack offered.
    private static func preferredKey(
        ndc: NationalDrugCode?, pzn: PZN?, gtin: GTIN?
    ) -> ProductKey? {
        if let ndc { return .ndc(ndc) }
        if let pzn { return .pzn(pzn) }
        if let gtin { return .gtin(gtin) }
        return nil
    }

    /// Reads an optional field through a validating initialiser.
    ///
    /// The double optional is doing real work. The outer `nil` means *present
    /// and wrong*, which rejects the whole reading; `.some(nil)` means
    /// *absent*, which is ordinary. A field whose check digit fails is a
    /// misread, and a misread on a medicine pack must never be softened into a
    /// missing field — that is how a reading of the wrong box comes back
    /// looking like a reading of no box, and gets quietly retried.
    private static func read<T>(_ raw: String?, _ make: (String) -> T?) -> T?? {
        guard let raw else { return .some(nil) }
        guard let value = make(raw) else { return nil }
        return .some(value)
    }
}
