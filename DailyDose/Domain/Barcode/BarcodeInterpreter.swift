import Foundation

/// Turns a scanned barcode into a `ScannedPack`, or into nothing.
///
/// The one public entry point to `Domain/Barcode`. Everything below it is a
/// parser that reports structure; this is the only place that decides what the
/// structure *means* — which identifier wins, which century a year is in, and
/// which fields are dropped on the floor.
enum BarcodeInterpreter {

    /// Reads a payload, or returns nil.
    ///
    /// `now` and `calendar` are parameters, not `Date.now` and `.current`,
    /// because the expiry century window depends on today's date and a test
    /// that depends on today's date is a test that starts failing on its own
    /// one morning.
    static func interpret(
        _ payload: BarcodePayload,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ScannedPack? {
        let bytes = payload.bytes
        guard !bytes.isEmpty else { return nil }

        // 1. The IFA envelope is self-announcing, so it is tested first and
        //    settles the question outright.
        if bytes.starts(with: PPNParser.header) {
            return PPNParser.parse(bytes).flatMap { pack(fromPPN: $0, now: now, calendar: calendar) }
        }

        // 2. GS1's leading FNC1 is transmitted as the symbology identifier
        //    "]d2", never as data — except on the scanners that pass it through
        //    as a bare GS, which is why both are accepted.
        if payload.symbologyIdentifier == "]d2" || bytes.first == ASCII.groupSeparator {
            return GS1Parser.parse(bytes).flatMap { pack(fromGS1: $0, now: now, calendar: calendar) }
        }

        // 3. Envelope stripped. Order matters against the next rule: "01" is
        //    also a legal opening for a PPN *value*, so "9N" is tested first.
        if bytes.starts(with: Array("9N".utf8)) {
            return PPNParser.parseBody(bytes).flatMap { pack(fromPPN: $0, now: now, calendar: calendar) }
        }

        // 4. A GS1 element string whose FNC1 never reached us. Requiring a
        //    complete AI (01) — fourteen digits, not just the two-digit AI —
        //    keeps a plain numeric linear code out of the GS1 path.
        if opensWithGTIN(bytes) {
            return GS1Parser.parse(bytes).flatMap { pack(fromGS1: $0, now: now, calendar: calendar) }
        }

        // 5. UPC-A, EAN-13, EAN-8, ITF-14: a number and nothing else.
        if let text = ASCII.printable(bytes), let gtin = GTIN(text) {
            return pack(fromLinear: gtin)
        }

        return nil
    }

    // MARK: - Dispatch tests

    /// Matches `^01\d{14}`.
    private static func opensWithGTIN(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 16, let opening = ASCII.printable(bytes.prefix(16)) else { return false }
        return opening.hasPrefix("01") && opening.dropFirst(2).isASCIIDigits
    }

    // MARK: - Interpretation

    private static func pack(
        fromGS1 elements: [GS1Parser.Element], now: Date, calendar: Calendar
    ) -> ScannedPack? {
        func value(_ ai: String) -> String? { elements.first { $0.ai == ai }?.value }

        // AI (21), the serial, is parsed and then deliberately thrown away.
        // Parsing it is not optional — without consuming it the fields around it
        // cannot be located — but keeping it would be. It is unique to one
        // physical box, which makes it a tracking identifier, and nothing in
        // this app asks *which box*: only which medicine, and when it expires.
        // Please do not helpfully restore it to `ScannedPack`.

        guard let gtin = read(value("01"), GTIN.init) else { return nil }
        guard let expiry = read(value("17"), {
            ExpiryDate.parse($0, encoding: .gs1, reference: now, calendar: calendar)
        }) else { return nil }
        guard let statedPZN = read(value("710"), PZN.init) else { return nil }

        // AI (715) states the NDC rather than letting us infer it, but stating
        // it is not the same as segmenting it — see `NationalDrugCode`. An
        // unsegmentable value leaves `ndc` nil and costs the scan nothing.
        let ndc = value("715").flatMap(NationalDrugCode.init(applicationIdentifier715:))

        // The stated NHRN beats the one embedded in the GTIN: it is what the
        // pack says about itself, rather than what we read out of its number.
        let pzn = statedPZN ?? gtin?.pzn

        guard let key = preferredKey(ndc: ndc, pzn: pzn, ppn: nil, gtin: gtin) else { return nil }

        return ScannedPack(
            key: key, gtin: gtin, pzn: pzn, ndc: ndc,
            batch: value("10"), expiry: expiry, syntax: .gs1
        )
    }

    private static func pack(
        fromPPN elements: [PPNParser.Element], now: Date, calendar: Calendar
    ) -> ScannedPack? {
        func value(_ identifier: String) -> String? {
            elements.first { $0.identifier == identifier }?.value
        }

        // DI `S` is the serial. Same reasoning as AI (21) above: read past it,
        // never carry it.

        // Without a product code there is no identity, and a pack we cannot
        // identify is a pack we cannot match to a medication next month.
        guard let raw = value("9N"), let ppn = PPN(raw) else { return nil }
        guard let expiry = read(value("D"), {
            ExpiryDate.parse($0, encoding: .ppn, reference: now, calendar: calendar)
        }) else { return nil }

        let pzn = ppn.pzn
        guard let key = preferredKey(ndc: nil, pzn: pzn, ppn: ppn, gtin: nil) else { return nil }

        return ScannedPack(
            key: key, gtin: nil, pzn: pzn, ndc: nil,
            batch: value("1T"), expiry: expiry, syntax: .ifaPPN
        )
    }

    /// A linear code carries identity and nothing else — no expiry, no batch.
    /// That is normal, not a failure: it is what a UK pack or an over-the-counter
    /// box looks like, and the identity alone still makes a refill scan work.
    private static func pack(fromLinear gtin: GTIN) -> ScannedPack {
        let pzn = gtin.pzn
        return ScannedPack(
            key: pzn.map(ProductKey.pzn) ?? .gtin(gtin),
            gtin: gtin, pzn: pzn, ndc: nil, batch: nil, expiry: nil, syntax: .linear
        )
    }

    // MARK: - Helpers

    /// The most specific identity the pack offered.
    private static func preferredKey(
        ndc: NationalDrugCode?, pzn: PZN?, ppn: PPN?, gtin: GTIN?
    ) -> ProductKey? {
        if let ndc { return .ndc(ndc) }
        if let pzn { return .pzn(pzn) }
        if let ppn { return .ppn(ppn) }
        if let gtin { return .gtin(gtin) }
        return nil
    }

    /// Reads an optional field through a validating initialiser.
    ///
    /// The double optional is doing real work. The outer `nil` means *present
    /// and wrong*, which rejects the whole scan; `.some(nil)` means *absent*,
    /// which is ordinary. A field whose check digit fails is a misread, and a
    /// misread on a medicine pack must never be softened into a missing field —
    /// that is how a scan of the wrong box comes back looking like a scan of no
    /// box, and gets quietly retried until something matches.
    private static func read<T>(_ raw: String?, _ make: (String) -> T?) -> T?? {
        guard let raw else { return .some(nil) }
        guard let value = make(raw) else { return nil }
        return .some(value)
    }
}
