import Foundation

/// Every word a medicine carton prints to say what is inside it, and how much.
///
/// **One table, two answers.** A dosage-form word carries both facts at once:
/// "30 Filmtabletten" says the pack holds thirty *and* that the medication is a
/// pill; "200 Hub" says two hundred *and* that it is an inhaler. A quantity
/// parser with its own word list and a form detector with another could
/// disagree about the same printed word — read the count off "Filmtabletten"
/// and then show a water bottle on the tile. They cannot disagree here, because
/// there is one list and both read it.
///
/// **This is data, not code.** The entries below are assembled from knowledge
/// of European and US packaging, not from photographs of real packs, and they
/// will be wrong in ways nobody can predict from a desk — abbreviations, phrases
/// broken across lines, OCR confusions between `O`/`0` and `rn`/`m`. When real
/// pack photographs arrive, extending a table is a five-minute job. Please keep
/// it that way: add rows, do not add rules.
enum PackagingLexicon {

    /// How much of a printed word a table entry may claim.
    enum Matching: Sendable {
        /// The printed word must be exactly this. The only safe mode for short
        /// words and abbreviations: `ct` is the end of "product", `st` the end
        /// of "test", `patch` the end of "dispatch".
        case whole
        /// The printed word may *end* with this — so German compounding works
        /// without enumerating it. "Filmtabletten", "Brausetabletten" and
        /// "Kautabletten" all end in "tabletten"; "Hartkapseln" ends in
        /// "kapseln". Compound entries must be at least ``minimumCompoundLength``
        /// characters, which is what keeps "gel" from being found inside
        /// "softgel" — the bug that made a swallowed capsule detect as a cream.
        case compound
    }

    /// A word a carton prints, and everything the app can conclude from it.
    struct Term: Equatable, Sendable {
        /// Folded — lowercase, no diacritics. See ``CartonText/fold(_:)``.
        let word: String
        /// The dosage form this word declares, or nil where it counts things
        /// without saying what they are ("Stück", "ct") or names a form this
        /// app does not model (a suppository). Nil is an honest "the pack did
        /// not say", never an assumed pill.
        let form: MedicationForm?
        let matching: Matching
        /// Whether a number in front of this word is a pack quantity.
        ///
        /// False for words that name a form but are never counted: nobody
        /// writes "30 solution". A word wrongly marked false costs a supply
        /// figure the user can type; a word wrongly marked true invents one.
        let counts: Bool
        /// Counts a volume rather than a number of things — see the `ml` rule
        /// in ``PackQuantity``.
        let isVolume: Bool
        /// Languages this word may be matched in, or nil when it may be
        /// matched in any.
        ///
        /// Short and colliding entries carry this. `St` is German for
        /// *Stück* — and the end of "152nd St" on a US pharmacy address, which
        /// is how a real label reported a supply of 152. `sobre` is Spanish for
        /// sachet and also the everyday word for "on"; `cap` is a bottle cap;
        /// `hub` is the centre of a wheel. Long unambiguous words carry no
        /// gate, deliberately: a European carton prints six languages on one
        /// box, and filtering to a single dominant one would throw away five.
        let languages: Set<CartonLanguage>?
        /// Whether this word *names* the quantity — "Qty: 90", "Menge: 30".
        ///
        /// A dispensing label prints the dispensed count under a marker like
        /// this, and also prints the directions, which contain numbers of their
        /// own: "Take 1 capsule … and 2 capsules". The marked figure is the
        /// authoritative one and outranks every other candidate, however large.
        let namesTheQuantity: Bool
        /// The smallest number that may be read as a pack quantity through this
        /// word. Defaults to 1, and exists for exactly one reason: "dose".
        /// "60 metered doses" is a pack size and "2 doses daily" is a
        /// direction, and this app does not read directions. A threshold cannot
        /// tell those apart perfectly, but it keeps the harmful reading — a
        /// supply of 2, which fires a refill warning on a full box — off the
        /// common case.
        let minimumCount: Int
    }

    /// Compound (suffix) matching is only safe for words long enough that a
    /// longer word ending in them is unlikely to be unrelated.
    static let minimumCompoundLength = 5

    /// When a carton names two forms, the more specific one wins: "ophthalmic
    /// drops solution" is drops, "liquid filled capsule" is a capsule,
    /// "transdermal patch" is a patch. `.topical` sits above `.liquid` because
    /// a cream is not a liquid, and below `.capsule` because a softgel is
    /// swallowed.
    static let precedence: [MedicationForm] = [
        .patch, .injection, .inhaler, .drops, .capsule, .powder, .topical, .liquid, .pill, .other,
    ]

    /// Units that make the number in front of them a *strength*, not a count.
    /// `ml` is deliberately absent: on a liquid the pack size genuinely is a
    /// volume, so it is a counting noun with a rule of its own.
    static let strengthUnits: Set<String> = [
        "mg", "mcg", "µg", "μg", "ug", "g", "kg", "iu", "ie", "ui", "%",
        "milligram", "milligrams", "microgram", "micrograms", "gram", "grams",
    ]

    // MARK: - The table

    /// Words that name a dosage form but are never a pack quantity.
    private static let formWords: [(MedicationForm, Matching, [String])] = [
        // English
        (.patch, .compound, ["transdermal"]),
        (.injection, .compound, [
            "injection", "injections", "injectable", "inyectable", "injektionslösung",
        ]),
        (.inhaler, .compound, [
            "inhaler", "inhalers", "aerosol", "inhalation", "inhalations", "inhalator", "puffer",
        ]),
        (.powder, .compound, ["powder", "powders", "granule", "granules", "granulat", "granulate"]),
        (.liquid, .compound, [
            "syrup", "syrups", "suspension", "suspensions", "solution", "solutions",
            "liquid", "liquids", "elixir", "spray", "sprays",
        ]),
        // Topicals. `gel` and `gels` are whole-word only: "softgel" ends in
        // "gel", and a gel capsule is swallowed rather than rubbed in.
        (.topical, .whole, ["gel", "gels", "balm"]),
        (.topical, .compound, [
            "cream", "creams", "ointment", "ointments", "lotion", "lotions",
            "balms", "salve", "salves", "topical",
        ]),
        // German
        (.powder, .compound, ["pulver"]),
        (.liquid, .compound, ["lösung", "lösungen", "sirup", "tropflösung"]),
        (.topical, .compound, ["creme", "cremes", "salbe", "salben"]),
        // French
        (.powder, .compound, ["poudre", "poudres"]),
        (.liquid, .compound, ["sirop", "sirops"]),
        (.topical, .compound, ["crème", "crèmes", "pommade", "pommades", "topique"]),
        // Spanish · Portuguese
        (.powder, .compound, ["polvo", "polvos"]),
        (.liquid, .compound, ["jarabe", "jarabes", "xarope", "solución", "solução"]),
        (.topical, .compound, ["crema", "cremas", "pomada", "pomadas", "unguento"]),
        // Italian
        (.liquid, .compound, ["sciroppo", "sciroppi", "soluzione", "sospensione"]),
        (.topical, .compound, ["pomata", "pomate", "unguenti"]),
        // Dutch · Nordic · Polish
        (.powder, .compound, ["poeder"]),
        (.liquid, .compound, ["oplossing", "syrop", "mikstur", "mikstura"]),
        (.topical, .whole, ["zalf", "krem", "maść"]),
        (.topical, .compound, ["zalven", "salva"]),
    ]

    /// Counting nouns: a number in front of one of these is a pack quantity,
    /// and the form each implies.
    private static let countingNouns: [(MedicationForm?, Matching, [String])] = [
        // MARK: Pills
        (.pill, .compound, [
            // English
            "tablet", "tablets", "pills", "lozenge", "lozenges",
            // German
            "tablette", "tabletten", "dragee", "dragees", "lutschtablette", "lutschtabletten",
            // French · Spanish · Portuguese · Italian
            "comprimé", "comprimés", "comprimido", "comprimidos",
            "compressa", "compresse", "pastille", "pastilles", "pastilla", "pastillas",
            // Polish · Nordic
            "tabletka", "tabletki", "tabletek",
            // Finnish takes the partitive after a number, so a pack prints
            // "30 tablettia" and never "30 tabletti".
            "tablett", "tabletter", "tabletti", "tabletit", "tablettia",
        ]),
        // "tab" and "tabs" are abbreviations; suffix matching would find them
        // in unrelated words.
        (.pill, .whole, ["tab", "tabs", "pill"]),

        // MARK: Capsules
        // "caplet" keeps the mapping it has always had here. A caplet is
        // strictly a capsule-*shaped* tablet, but changing it is a product
        // decision, not a lexicon one.
        (.capsule, .compound, [
            // English
            "capsule", "capsules", "caplet", "caplets",
            "softgel", "softgels", "gelcap", "gelcaps",
            // German · Nordic
            "kapsel", "kapseln", "kapsler", "kapslar", "kapseli", "kapselit",
            // French · Spanish · Portuguese · Italian
            "gélule", "gélules", "cápsula", "cápsulas", "capsula", "capsulas",
            // Polish
            "kapsułka", "kapsułki", "kapsułek", "kapselia",
        ]),
        (.capsule, .whole, ["caps", "cap"]),

        // MARK: Sachets and powders
        (.powder, .compound, [
            "sachet", "sachets", "sachê", "sachês", "saqueta", "saquetas",
            "beutel", "zakje", "zakjes", "bustina", "bustine",
            "saszetka", "saszetki", "sobres",
        ]),
        // Spanish "sobre" is also the everyday word for "on" / "about". The
        // plural above is unambiguously the packaging noun; the singular counts
        // without being allowed to claim a form.
        (nil, .whole, ["sobre"]),

        // MARK: Injections
        (.injection, .compound, [
            "ampoule", "ampoules", "ampule", "ampules", "ampul",
            "ampulle", "ampullen", "ampolla", "ampollas", "ampola", "ampolas",
            "ampułka", "ampułki", "fiala", "fiale", "fiole", "fioles",
            "syringe", "syringes", "spritze", "spritzen", "injektion", "injektionen",
        ]),
        // "trivial" ends in "vial".
        (.injection, .whole, ["vial", "vials"]),

        // MARK: Patches — "dispatch" ends in "patch".
        (.patch, .whole, ["patch", "patches"]),
        (.patch, .compound, ["pflaster", "cerotto", "cerotti", "plaster", "plastry"]),

        // MARK: Drops — "drops" compounds into "eyedrops" and "eardrops";
        // the singular is too short to match that way safely.
        (.drops, .whole, ["drop"]),
        (.drops, .compound, [
            "drops", "tropfen", "goutte", "gouttes", "gotas", "gocce",
            "druppels", "krople", "dråper", "droppar",
        ]),

        // MARK: Inhalers
        (.inhaler, .whole, ["puff", "puffs", "hub", "hübe", "hüben"]),
        (.inhaler, .compound, ["actuation", "actuations", "sprühstoß", "sprühstöße"]),

        // MARK: Counted, but silent about the form
        // "Stück", "ct", "count" say how many and nothing else. Guessing a form
        // from them would be a lie with a number in it.
        (nil, .whole, ["st", "stk", "stck", "pcs", "ct", "count", "qty"]),
        // "Qty 60" and "Inhalt: 30" put the noun first; the number-after rule
        // reads them.
        (nil, .compound, ["quantity", "menge", "anzahl", "inhalt"]),
        (nil, .whole, ["styk"]),
        (nil, .compound, ["stück", "stycken", "kappaletta"]),
        // "60 metered doses" is a pack size; "2 doses daily" is a direction.
        // `minimumCount` keeps the harmful reading off the common case.
        (nil, .whole, ["dose", "doses", "dosen", "doser"]),
        // Forms this app does not model. Counted honestly, and deliberately not
        // squeezed into `.pill`: a suppository is not a pill, and an icon that
        // says it is would be worse than the neutral one.
        (nil, .compound, [
            "suppository", "suppositories", "suppositoire", "suppositoires",
            "supositorio", "supositorios", "supposta", "supposte",
            "zäpfchen", "czopek", "czopki", "stikkpille", "stikkpiller",
        ]),
    ]

    /// Counting nouns that count a volume. Split out because a millilitre
    /// figure only becomes a pack quantity under a rule of its own.
    private static let volumeNouns: [(MedicationForm, Matching, [String])] = [
        (.liquid, .whole, ["ml"]),
        (.liquid, .compound, [
            "milliliter", "milliliters", "millilitre", "millilitres", "mililitro", "mililitros",
        ]),
    ]

    /// Entries that only match when the label is printed in one of these
    /// languages. See ``Term/languages``.
    ///
    /// Two kinds of row belong here: anything three characters or shorter, and
    /// anything that is also an ordinary word in another language. Adding a
    /// short row without a gate is how "152nd St" became a pack of 152.
    private static let gated: [String: Set<CartonLanguage>] = [
        // German and Nordic "pieces". The end of every English street address.
        "st": [.german, .nordic], "stk": [.german, .nordic], "stck": [.german],
        "styk": [.nordic],
        // German inhaler actuations. Also an English noun.
        "hub": [.german], "hube": [.german],
        // English abbreviations, all of them ordinary English words too.
        "ct": [.english], "cap": [.english], "caps": [.english],
        "tab": [.english], "tabs": [.english], "pcs": [.english], "qty": [.english],
        "drop": [.english], "count": [.english],
        // Spanish for sachet, and for "on".
        "sobre": [.spanish], "sobres": [.spanish, .portuguese],
    ]

    /// Words that name a quantity rather than the thing being counted.
    private static let quantityMarkers: Set<String> = [
        "qty", "quantity", "menge", "anzahl", "inhalt", "count",
    ]

    /// Terms whose count must clear a floor before it is believed.
    private static let minimumCounts: [String: Int] = ["dose": 10, "doses": 10, "dosen": 10, "doser": 10]

    // MARK: - Lookup

    /// The whole table, folded, with the first spelling of a repeated word
    /// winning. Words genuinely repeat across languages — Italian "capsule" is
    /// English "capsules"' neighbour, Dutch "tablet" is English "tablet" — and
    /// every such pair agrees, which `CartonExtractionTests` asserts rather
    /// than assumes.
    static let terms: [Term] = {
        var terms: [Term] = []
        var seen: Set<String> = []

        func add(_ form: MedicationForm?, _ matching: Matching, _ words: [String], isVolume: Bool, counts: Bool) {
            for word in words {
                let folded = CartonText.fold(word)
                guard seen.insert(folded).inserted else { continue }
                terms.append(
                    Term(
                        word: folded, form: form, matching: matching,
                        counts: counts, isVolume: isVolume,
                        languages: gated[folded],
                        namesTheQuantity: quantityMarkers.contains(folded),
                        minimumCount: minimumCounts[folded] ?? 1
                    )
                )
            }
        }

        for (form, matching, words) in countingNouns {
            add(form, matching, words, isVolume: false, counts: true)
        }
        for (form, matching, words) in volumeNouns {
            add(form, matching, words, isVolume: true, counts: true)
        }
        // Form words go in last: where a word is both, the counting entry is
        // the more informative one and already claimed the slot.
        for (form, matching, words) in formWords {
            add(form, matching, words, isVolume: false, counts: false)
        }
        return terms
    }()

    private static let byWord: [String: Term] =
        Dictionary(terms.map { ($0.word, $0) }, uniquingKeysWith: { first, _ in first })

    /// Compound entries, longest first, so the most specific word wins:
    /// "softgel" is found before "gel" whatever order the table is written in.
    private static let compoundTerms: [Term] =
        terms.filter { $0.matching == .compound }.sorted { $0.word.count > $1.word.count }

    /// The term a printed word names, or nil.
    ///
    /// `token` must already be folded — it comes from ``CartonText/tokens(in:)``.
    /// `language` is the label's, and a gated entry only matches when it is one
    /// of the entry's own. A nil language matches nothing gated, which loses a
    /// count rather than inventing one.
    static func term(for token: String, language: CartonLanguage? = nil) -> Term? {
        func admits(_ term: Term) -> Bool {
            guard let languages = term.languages else { return true }
            guard let language else { return false }
            return languages.contains(language)
        }
        if let exact = byWord[token] { return admits(exact) ? exact : nil }
        return compoundTerms.first {
            token.count > $0.word.count && token.hasSuffix($0.word) && admits($0)
        }
    }

    /// The form this text declares, or nil when it declares none.
    ///
    /// Word-boundary matching, not substring: the old `contains` check found
    /// "gel" inside "softgel" and "drop" inside anything.
    static func form(in text: String) -> MedicationForm? {
        let language = CartonLanguageRecognizer.language(of: text)
        var found: Set<MedicationForm> = []
        for case .word(let token) in CartonText.tokens(in: text) {
            if let form = term(for: token, language: language)?.form { found.insert(form) }
        }
        return precedence.first(where: found.contains)
    }
}
