import Foundation

/// Everything a medicine pack tells us about itself, without a database.
///
/// Which, in every market on earth, is: what this product is, when it expires,
/// and which batch it came from. That is enough to match a refill to the
/// medication the user already has, and enough to warn them that the box in the
/// cupboard went out of date in March — neither of which needs a licence, a
/// lookup, or a single byte leaving the phone.
struct ScannedPack: Equatable, Sendable {

    /// The identity this pack is filed under, in the app's preference order.
    let key: ProductKey
    let gtin: GTIN?
    let pzn: PZN?
    /// US only. Phase 1 fills this only when the code stated it outright;
    /// deriving one from a GTIN needs the FDA directory, which is Phase 2.
    let ndc: NationalDrugCode?
    /// The lot, exactly as printed — case included. GS1 CSET-82 is
    /// case-sensitive, so `"ab12"` and `"AB12"` are different lots and
    /// "tidying" the case would make a recall check quietly wrong.
    let batch: String?
    let expiry: ExpiryDate?
    /// How many the pack holds, as the manufacturer encoded it — GS1 AI (30).
    ///
    /// Rarely present on a medicine pack, and worth reading when it is: it is
    /// the one count on the whole carton that is stated rather than inferred,
    /// so it outranks anything the OCR reads off the printed front.
    let count: Int?
}
