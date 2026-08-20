import Foundation

/// The language a label is printed in, as far as the lexicon needs to care.
///
/// This exists for one reason: **short words are not safe across languages.**
/// A real US dispensing label printed "10004 S. 152nd St Omaha", and the German
/// entry `St` — *Stück*, the word for "pieces" — matched "St" and reported a
/// supply of 152. `St` is only the first instance; `sobre` is Spanish for
/// "sachet" and also the everyday word for "on", `cap` is a bottle cap, `hub`
/// is a wheel's centre.
///
/// So the table marks its short and colliding entries as needing this gate, and
/// they match only when the label is actually printed in the language they
/// belong to. Everything long and unambiguous — "Filmtabletten", "comprimés",
/// "capsules" — keeps matching in any language, deliberately: a European
/// carton routinely prints six languages on one box, and filtering to a single
/// dominant one would throw away five of them.
enum CartonLanguage: String, CaseIterable, Sendable {
    case english, german, french, spanish, italian, dutch, portuguese, polish, nordic
}

/// Which language a label is printed in, decided from the words on it.
///
/// Deliberately not `NLLanguageRecognizer`: this text is not prose. A carton
/// is a handful of nouns, an address and a dosage — the shortest and least
/// grammatical input a language recogniser can be handed — and the words that
/// actually decide the question here are pharmaceutical, not linguistic.
/// "Filmtabletten" settles it in one token where a general recogniser needs a
/// sentence. Keeping it as a table also keeps the domain layer pure
/// `Foundation`, and keeps the decision testable without a framework.
enum CartonLanguageRecognizer {

    /// Words that identify a language, scored one point each.
    ///
    /// Every entry has to be **unambiguous across the whole table**: a word
    /// that could belong to two languages tells us nothing, and a word that is
    /// also an ordinary English word is worse than nothing — listing German
    /// `st` here would let "152nd St" prove the label was German, which is the
    /// exact bug this file exists to prevent.
    private static let markers: [CartonLanguage: [String]] = [
        .english: [
            "tablets", "capsules", "caplets", "softgels", "take", "mouth", "daily",
            "twice", "refills", "pharmacy", "pharmacist", "physician", "prescribed",
            "qty", "each", "before", "with", "food", "water", "count", "swallow",
        ],
        .german: [
            "tabletten", "filmtabletten", "kapseln", "hartkapseln", "weichkapseln",
            "stück", "beutel", "tropfen", "packungsbeilage", "gebrauchsinformation",
            "apotheke", "apothekenpflichtig", "einnehmen", "täglich", "wirkstoff",
            "darreichungsform", "zäpfchen", "pflaster", "arzneimittel",
        ],
        .french: [
            "comprimés", "comprimé", "gélules", "gélule", "pelliculés", "boîte",
            "notice", "pharmacie", "voie", "orale", "avant", "sachets",
        ],
        .spanish: [
            "comprimidos", "cápsulas", "recubiertos", "prospecto", "farmacia",
            "envase", "vía", "oral", "sobres", "polvo",
        ],
        .italian: [
            "compresse", "capsule", "rivestite", "foglio", "illustrativo",
            "farmacia", "scatola", "bustine", "sciroppo",
        ],
        .dutch: [
            "tabletten", "capsules", "bijsluiter", "apotheek", "zakjes",
            "innemen", "dagelijks", "omhulde",
        ],
        .portuguese: [
            "comprimidos", "cápsulas", "revestidos", "folheto", "farmácia",
            "saquetas", "embalagem",
        ],
        .polish: [
            "tabletki", "tabletka", "kapsułki", "kapsułka", "ulotka", "apteka",
            "saszetki", "powlekane",
        ],
        .nordic: [
            "tabletter", "kapsler", "kapslar", "tablett", "bipacksedel",
            "apotek", "pakningsvedlegg", "tablettia", "kapselia",
        ],
    ]

    /// Markers that several languages share. Scored for each of them, so a
    /// word like "tabletten" — German *and* Dutch — never settles the question
    /// on its own.
    private static let index: [String: [CartonLanguage]] = {
        var index: [String: [CartonLanguage]] = [:]
        for (language, words) in markers {
            for word in words {
                index[CartonText.fold(word), default: []].append(language)
            }
        }
        return index
    }()

    /// The language this text is printed in, or nil when the words on it do
    /// not say.
    ///
    /// Nil is a real answer and the common one on a small carton — "30
    /// Kapseln" carries a marker, "90 TABLETS" carries a marker, "100 St."
    /// carries nothing at all. When it is nil, gated entries simply do not
    /// match, which loses a count rather than inventing one.
    static func language(of text: String) -> CartonLanguage? {
        var scores: [CartonLanguage: Int] = [:]
        for case .word(let token) in CartonText.tokens(in: text) {
            guard let languages = index[token] else { continue }
            for language in languages { scores[language, default: 0] += 1 }
        }
        guard let best = scores.max(by: { $0.value < $1.value }) else { return nil }
        // A tie is not an answer. Two languages with the same score means the
        // markers found were shared ones, and choosing between them by
        // dictionary order would make the result depend on hashing.
        let leaders = scores.filter { $0.value == best.value }
        return leaders.count == 1 ? best.key : nil
    }
}
