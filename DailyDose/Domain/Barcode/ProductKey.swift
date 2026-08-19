import Foundation

/// A GTIN whose check digit has been verified, normalised to 14 digits.
///
/// A type rather than a `String` for the same reason `TimeOfDay` is a type:
/// there is then no way to hold a GTIN that nobody checked. The one stored
/// form is GTIN-14, so the EAN-13 on the outer carton and the ITF-14 on the
/// case compare equal instead of looking like two different products —
/// leading zeros carry no information, and mod-10 weights count from the
/// right, so padding cannot change the check digit.
struct GTIN: Hashable, Sendable, CustomStringConvertible {
    /// Always 14 ASCII digits.
    let value: String

    /// Fails on anything that is not 8, 12, 13 or 14 digits with a check digit
    /// that agrees. The length whitelist matters: without it any run of digits
    /// would pad into a "valid" GTIN and a phone number could name a medicine.
    init?(_ raw: String) {
        guard [8, 12, 13, 14].contains(raw.count), raw.isASCIIDigits else { return nil }
        let padded = String(repeating: "0", count: 14 - raw.count) + raw
        guard CheckDigit.isValidGTIN(padded) else { return nil }
        self.value = padded
    }

    var description: String { value }

    /// The PZN carried inside a German NTIN.
    ///
    /// NTIN syntax builds a GTIN-13 as `"4150"` + the 8-digit PZN + a mod-10
    /// check, which is `"04150…"` once padded to 14. The PZN's own mod-11
    /// check then has to agree as well: the `04150` prefix alone is a
    /// coincidence a 14-digit number can produce, and one check digit
    /// confirming another is what makes this safe to act on.
    var pzn: PZN? {
        guard value.hasPrefix("04150") else { return nil }
        return PZN(String(value.dropFirst(5).prefix(8)))
    }
}

/// An 8-digit Pharmazentralnummer whose modulo-11 check digit has been verified.
///
/// Germany's national medicine number. We can validate it and use it as an
/// identity key for free; turning it into `"Metformin 500 mg Filmtabletten"`
/// needs IFA's commercial article database, which we deliberately do not
/// licence — the camera reads the name off the box instead.
struct PZN: Hashable, Sendable, CustomStringConvertible {
    let value: String

    init?(_ raw: String) {
        guard raw.count == 8, raw.isASCIIDigits, CheckDigit.isValidPZN(raw) else { return nil }
        self.value = raw
    }

    var description: String { value }
}

/// A Pharmacy Product Number whose modulo-97 check has been verified.
///
/// The IFA identifier carried by German DataMatrix codes in PPN syntax:
/// a two-digit Product Registration Agency code, an article number, and two
/// check digits.
struct PPN: Hashable, Sendable, CustomStringConvertible {
    let value: String

    init?(_ raw: String) {
        guard (11...28).contains(raw.count),
              raw.allSatisfy({ $0.isASCII && ($0.isNumber || ($0.isUppercase && $0.isLetter)) }),
              CheckDigit.isValidPPN(raw)
        else { return nil }
        self.value = raw
    }

    var description: String { value }

    /// The registration agency that issued the article number.
    var registrationAgency: String { String(value.prefix(2)) }

    /// The 8-digit PZN inside an IFA-issued PPN.
    ///
    /// Gated on agency code `"11"`, because other agencies exist and their
    /// article numbers are not PZNs — reading one as a PZN would key a Swiss
    /// or Austrian pack to a German medicine. As with the NTIN route, the
    /// PZN's own check digit has the final say.
    var pzn: PZN? {
        guard registrationAgency == "11", value.count >= 10 else { return nil }
        return PZN(String(value.dropFirst(2).prefix(8)))
    }
}

/// What a pack *is*, in whichever way its market says so.
///
/// This is the whole of Phase 1's value proposition in one type. We cannot
/// turn most of these codes into a product name without a licensed database,
/// but we do not need to: the user names an unknown pack once, we store the
/// key beside it, and every later scan of that pack — new box, different
/// country, no network — matches the medication they already have.
///
/// Every case's payload is a type that cannot be constructed without a passing
/// check digit, so a `ProductKey` in hand has already been validated. The order
/// below is the preference order when a code carries more than one.
enum ProductKey: Hashable, Sendable {
    /// US. Resolvable against the local FDA directory — in Phase 2.
    case ndc(NationalDrugCode)
    /// Germany. Validated but not resolvable: a key, never a name.
    case pzn(PZN)
    /// A pack whose only identifier is a non-German PPN. Rare, and still an
    /// identity — dropping it would throw away the expiry date with it.
    case ppn(PPN)
    /// Anywhere.
    case gtin(GTIN)
}

// MARK: - Persisted form

extension ProductKey: RawRepresentable {
    /// A tagged string, so `Medication` can store the key in one dull column
    /// and lightweight-migrate onto it.
    ///
    /// Reading it back re-runs the check digit rather than trusting what is on
    /// disk. A raw value written by a newer build, edited by hand, or restored
    /// from a corrupted backup then reads as `nil` — the same contract
    /// `MedicationForm` has, and for the same reason: an unknown value must
    /// degrade to "we don't know", never to a crash on a screen that only
    /// wanted to match two boxes.
    var rawValue: String {
        switch self {
        case .ndc(let ndc): "ndc:\(ndc.hyphenated)"
        case .pzn(let pzn): "pzn:\(pzn.value)"
        case .ppn(let ppn): "ppn:\(ppn.value)"
        case .gtin(let gtin): "gtin:\(gtin.value)"
        }
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let body = String(parts[1])
        switch parts[0] {
        case "ndc":
            guard let ndc = NationalDrugCode(hyphenated: body) else { return nil }
            self = .ndc(ndc)
        case "pzn":
            guard let pzn = PZN(body) else { return nil }
            self = .pzn(pzn)
        case "ppn":
            guard let ppn = PPN(body) else { return nil }
            self = .ppn(ppn)
        case "gtin":
            guard let gtin = GTIN(body) else { return nil }
            self = .gtin(gtin)
        default:
            return nil
        }
    }
}
