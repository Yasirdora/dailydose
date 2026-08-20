import Foundation

/// How many the pack holds, read off the carton.
///
/// The general shape is `<number> <counting noun>` — "30 Tabletten", "90
/// TABLETS", "200 Hub" — with a blister variant that multiplies, "3 x 10
/// Tabletten", and a trailing form, "Tabletten 30". The noun comes from
/// ``PackagingLexicon``, which is also where ``MedicationForm/detect(in:)``
/// reads, so the count and the form can never be read off the same printed word
/// and disagree about it.
///
/// The rules here are biased hard towards **no answer**. A blank supply field
/// costs the user ten seconds of typing; a wrong one silently mis-times the
/// refill warning, which is the number this app asks people to trust.
enum PackQuantity {

    /// What a pack can plausibly hold. Outside this, a number that sits beside
    /// a counting noun is a lot number, a phone fragment or a misread — a
    /// twelve-tablet pack is real, a twelve-thousand-tablet one is not.
    static let plausibleCount = 1...5000

    struct Reading: Equatable, Sendable {
        let count: Int
        /// The form the counted noun implies — "Filmtabletten" says pill as
        /// well as thirty — or nil where the noun only counts ("Stück").
        let form: MedicationForm?
        /// Read from a word that *names* the quantity — "Qty: 90". Believed
        /// over anything else on the label, however large.
        let isStated: Bool
    }

    static func read(_ text: String) -> Reading? {
        // Decided once, from the whole label: a gated entry matches only in
        // its own language, and "St" is German for pieces and the end of every
        // English street address.
        let language = CartonLanguageRecognizer.language(of: text)
        let tokens = CartonText.tokens(in: text)
        let strengthNumbers = strengthNumberIndices(in: tokens)

        var counted: [Reading] = []
        var volumes: [Reading] = []

        for (index, token) in tokens.enumerated() {
            guard case .number(let value) = token, !strengthNumbers.contains(index) else { continue }
            guard let (amount, term) = countingNoun(
                      in: tokens, forNumberAt: index, value: value, language: language
                  ),
                  let reading = reading(amount, term)
            else { continue }
            if term.isVolume { volumes.append(reading) } else { counted.append(reading) }
        }

        // A stated quantity settles it. A dispensing label prints "Qty: 90"
        // and, separately, the directions — "Take 1 capsule … and 2 capsules
        // in the evening" — so the label carries three numbers next to a
        // counting noun and only one of them is the dispensed count. Largest
        // does not decide this; the marker does.
        if let stated = counted.filter(\.isStated).max(by: { $0.count < $1.count }) { return stated }

        // Several counts on one carton is normal — "3 x 10" prints both the
        // blister size and the total, and a multipack prints both again. The
        // largest is the pack, which is what the supply counter is asking for.
        if let best = counted.max(by: { $0.count < $1.count }) { return best }

        // The millilitre rule. On a liquid the pack size genuinely *is* a
        // volume, so `ml` has to be readable as a quantity — but "500 mg / 5
        // ml" prints a millilitre figure that is part of the strength, and
        // "20 ml" on its own could be either. A volume is only believed when
        // nothing else was countable and the carton stated a strength
        // somewhere else, which is the pattern a liquid medicine's pack has
        // and a bare volume does not. Numbers that are themselves a strength
        // never reach here, so "a different token" is guaranteed, not checked.
        guard !strengthNumbers.isEmpty else { return nil }
        return volumes.max(by: { $0.count < $1.count })
    }

    // MARK: - Pieces

    /// Numbers a unit turns into a strength: the `500` of "500 mg".
    ///
    /// Recorded so they can be excluded from counting *before* any noun is
    /// looked at — without it, "Tabletten 500 mg" reads the strength backwards
    /// off the noun in front of it and reports a pack of five hundred.
    private static func strengthNumberIndices(in tokens: [CartonText.Token]) -> Set<Int> {
        var indices: Set<Int> = []
        for (index, token) in tokens.enumerated() {
            guard case .number = token,
                  case .word(let unit)? = element(tokens, at: index + 1),
                  PackagingLexicon.strengthUnits.contains(unit)
            else { continue }
            indices.insert(index)
        }
        return indices
    }

    /// The counting noun this number belongs to, and how many it means.
    private static func countingNoun(
        in tokens: [CartonText.Token], forNumberAt index: Int, value: Int,
        language: CartonLanguage?
    ) -> (amount: Int, term: PackagingLexicon.Term)? {
        // `30 Tabletten`, `60 metered doses`, `30 film coated tablets`
        if let term = countingTerm(tokens, from: index + 1, language: language) {
            return (value, term)
        }

        // `3 x 10 Tabletten` — a blister pack states the strip and the number
        // of strips, and neither one alone is what is in the box.
        if case .multiplier? = element(tokens, at: index + 1),
           case .number(let perStrip)? = element(tokens, at: index + 2),
           let term = countingTerm(tokens, from: index + 3, language: language) {
            let (total, overflowed) = value.multipliedReportingOverflow(by: perStrip)
            if !overflowed { return (total, term) }
        }

        // `Tabletten 30`. Adjacent only, and deliberately: reading backwards
        // past a word is how "Filmtabletten 500 mg" would find its noun.
        // `Tabletten 30`, and `Qty: 90` — the marker names the quantity and the
        // number follows it. Adjacent only, and deliberately: reading backwards
        // past a word is how "Filmtabletten 500 mg" would find its noun.
        if let term = countingTerm(tokens, at: index - 1, language: language) {
            return (value, term)
        }

        return nil
    }

    /// How many words of description may sit between a number and the noun it
    /// counts. Three covers "film coated tablets" and "metered dose inhaler"
    /// without letting a number reach across a whole sentence.
    private static let descriptionWindow = 3

    /// The counting noun a number introduces, looking past a word or two of
    /// description.
    ///
    /// A carton rarely sets the number against the noun: "60 metered doses",
    /// "30 film-coated tablets", "100 sugar coated tablets". The scan stops the
    /// moment the subject changes — a line break, another number, a multiplier,
    /// a size class, a strength unit, or a word that names a *form* rather than
    /// a count — so "1 pack contains 30 tablets" can never read the one, and
    /// "Ibuprofen AL 400" cannot reach the "Filmtabletten" on the line below.
    private static func countingTerm(
        _ tokens: [CartonText.Token], from index: Int, language: CartonLanguage?
    ) -> PackagingLexicon.Term? {
        for offset in 0..<descriptionWindow {
            guard case .word(let word)? = element(tokens, at: index + offset) else { return nil }
            guard !PackagingLexicon.strengthUnits.contains(word) else { return nil }
            guard let term = PackagingLexicon.term(for: word, language: language) else { continue }
            return term.counts ? term : nil
        }
        return nil
    }

    private static func countingTerm(
        _ tokens: [CartonText.Token], at index: Int, language: CartonLanguage?
    ) -> PackagingLexicon.Term? {
        guard case .word(let word)? = element(tokens, at: index),
              let term = PackagingLexicon.term(for: word, language: language), term.counts
        else { return nil }
        return term
    }

    private static func reading(_ count: Int, _ term: PackagingLexicon.Term) -> Reading? {
        guard plausibleCount.contains(count), count >= term.minimumCount else { return nil }
        return Reading(count: count, form: term.form, isStated: term.namesTheQuantity)
    }

    private static func element(_ tokens: [CartonText.Token], at index: Int) -> CartonText.Token? {
        tokens.indices.contains(index) ? tokens[index] : nil
    }
}
