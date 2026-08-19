import Foundation

/// The three check-digit algorithms a medicine pack can carry.
///
/// All three answer the same question — did the camera read this correctly? —
/// and a subtly wrong implementation is worse than none at all, because it
/// turns a misread into a *confidently* wrong medicine identity. So each one
/// here is written against a published worked example, and those examples are
/// the test vectors in `BarcodeParsingTests`.
enum CheckDigit {

    // MARK: - GTIN, modulo 10

    /// The check digit for a GTIN's data digits — everything but the last one.
    ///
    /// Weights 3 and 1 alternate **from the right**, which is why one routine
    /// serves GTIN-8, -12, -13 and -14 without a length table, and why leading
    /// zero padding cannot change the answer. The trailing `% 10` is not
    /// decoration: when the weighted sum is already a multiple of ten the check
    /// digit is 0, and `10 - 0` would make it 10 — a digit that does not exist.
    static func gtin(dataDigits: String) -> Int? {
        guard let digits = Self.digits(dataDigits) else { return nil }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            sum += digit * (offset.isMultiple(of: 2) ? 3 : 1)
        }
        return (10 - sum % 10) % 10
    }

    /// Whether a complete GTIN's last digit matches its own data.
    static func isValidGTIN(_ code: String) -> Bool {
        guard code.count >= 2,
              let expected = gtin(dataDigits: String(code.dropLast())),
              let actual = code.last?.wholeNumberValue
        else { return false }
        return expected == actual
    }

    // MARK: - PZN, modulo 11

    /// The check digit for a PZN's first seven digits.
    ///
    /// Weights 1…7 run left to right and the remainder *is* the digit — there
    /// is no `11 - remainder` step. A remainder of 10 has no single-digit
    /// representation, and IFA issues no substitution character for it: such
    /// numbers are simply never assigned. So a remainder of 10 means the input
    /// was never a PZN, and this returns nil rather than inventing an eighth
    /// digit that would make a wrong number look right.
    static func pzn(firstSeven: String) -> Int? {
        guard firstSeven.count == 7, let digits = Self.digits(firstSeven) else { return nil }
        let sum = digits.enumerated().reduce(0) { $0 + $1.element * ($1.offset + 1) }
        let remainder = sum % 11
        return remainder == 10 ? nil : remainder
    }

    static func isValidPZN(_ code: String) -> Bool {
        guard code.count == 8,
              let expected = pzn(firstSeven: String(code.prefix(7))),
              let actual = code.last?.wholeNumberValue
        else { return false }
        return expected == actual
    }

    // MARK: - PPN, modulo 97

    /// The two-digit check for a PPN body — the registration-agency code plus
    /// the article number, everything before the check itself.
    ///
    /// The weights run from 2 upwards over the **ASCII value** of each
    /// character, not its numeric value. That distinction is the classic
    /// implementation bug here: a digit-value version validates plenty of real
    /// PPNs by luck and rejects plenty of others, which looks like flaky
    /// hardware rather than a wrong algorithm. Both published worked examples
    /// are pinned in the tests for exactly that reason.
    static func ppn(body: String) -> String? {
        guard !body.isEmpty else { return nil }
        var sum = 0
        for (offset, scalar) in body.unicodeScalars.enumerated() {
            guard scalar.isASCII else { return nil }
            sum += Int(scalar.value) * (offset + 2)
        }
        return String(format: "%02d", sum % 97)
    }

    static func isValidPPN(_ code: String) -> Bool {
        guard code.count >= 3 else { return false }
        let body = String(code.dropLast(2))
        let check = String(code.suffix(2))
        guard check.isASCIIDigits else { return false }
        return ppn(body: body) == check
    }

    // MARK: - Digits

    private static func digits(_ text: String) -> [Int]? {
        guard text.isASCIIDigits else { return nil }
        return text.compactMap(\.wholeNumberValue)
    }
}

extension StringProtocol {
    /// Non-empty and made only of ASCII `0`…`9`.
    ///
    /// `Character.isNumber` alone is true for "½" and for the Arabic-Indic
    /// digits, which are not what a barcode carries and not what `Int()` would
    /// read back the same way.
    var isASCIIDigits: Bool {
        !isEmpty && allSatisfy { $0.isASCII && $0.isNumber }
    }
}
