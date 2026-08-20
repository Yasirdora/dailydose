import Foundation

/// Turns the text printed on a medicine carton into tokens the lexicon can
/// match, in the one normal form every language in the table is written in.
///
/// Pure `Foundation`, deliberately: everything here is decided by characters,
/// so every rule can be pinned in a test rather than discovered by pointing a
/// phone at a box.
enum CartonText {

    /// One piece of printed text, classified only as far as the quantity rules
    /// need. Anything finer would be sig parsing, which this app does not do.
    enum Token: Equatable, Sendable {
        /// A whole number. Negative when a `-` ran straight into the digits,
        /// so `Omega-3` yields −3 and is rejected by range rather than read as
        /// a pack of three.
        case number(Int)
        /// Part of a decimal — `2.5`, `0,5`. A pack quantity is a whole number
        /// of things, so this is deliberately not a `number`: without it,
        /// `2.5 ml` reads as five millilitres.
        case decimal
        /// `x`, `X` or `×` between two numbers: `3 x 10`.
        case multiplier
        /// A run of letters, folded. `%` arrives here too, because it is a
        /// strength unit and nothing else.
        case word(String)
        /// The end of a printed line — or of one OCR fragment, which is the
        /// same thing.
        ///
        /// Load-bearing, not cosmetic. A German pack prints "Ibuprofen AL 400"
        /// on one line and "Filmtabletten" on the next, where the 400 is the
        /// strength in milligrams with the unit left off. Flatten the lines and
        /// that reads as four hundred tablets — and beats the real "20
        /// Filmtabletten" further down the box, because the larger count wins.
        /// A pack quantity and the noun it counts are printed together.
        case lineBreak
        /// A German *Normgröße* — `N1`, `N2`, `N3`.
        ///
        /// These are package **size classes**, not counts: N1 is 20 tablets for
        /// one medicine and 10 for another, and the mapping lives in a
        /// reference table this app does not carry. The digit is consumed here
        /// so it can never reach the quantity rules, because a supply figure
        /// invented from a size class is worse than a blank one — the refill
        /// warning is built on it.
        case packSizeClass
    }

    /// Lowercased and stripped of diacritics, so `KAPSELN`, `Kapseln` and
    /// `kapseln` are one word, and `cápsulas` matches `capsulas`.
    ///
    /// The manual substitutions are the letters Unicode diacritic folding does
    /// *not* touch: `ł`, `ø` and `đ` carry a stroke through the letter rather
    /// than a combining mark, so they have no canonical decomposition and
    /// survive folding intact. Polish `kapsułki` would otherwise only ever
    /// match a table entry spelled with the same `ł` — which is fine until an
    /// OCR reads it as a plain `l`, and then nothing matches at all.
    static func fold(_ text: String) -> String {
        var folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: nil
        )
        for (stroked, plain) in strokeLetters {
            folded = folded.replacingOccurrences(of: stroked, with: plain)
        }
        return folded
    }

    /// Case folding has already run by the time these apply, so only the
    /// lowercase forms are needed.
    private static let strokeLetters: [(String, String)] = [
        ("ł", "l"), ("ø", "o"), ("đ", "d"), ("ß", "ss"), ("æ", "ae"), ("œ", "oe"),
    ]

    static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(fold(text))
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character.isNewline {
                tokens.append(.lineBreak)
                index += 1
                continue
            }

            if character.isASCIIDigit {
                var end = index
                while end < characters.count, characters[end].isASCIIDigit { end += 1 }
                tokens.append(numberToken(characters, from: index, to: end))
                index = end
                continue
            }

            if character.isLetter {
                var end = index
                while end < characters.count, characters[end].isLetter { end += 1 }
                let word = String(characters[index..<end])

                if let consumed = packSizeClass(characters, word: word, after: end) {
                    tokens.append(.packSizeClass)
                    index = consumed
                    continue
                }
                tokens.append(word == "x" ? .multiplier : .word(word))
                index = end
                continue
            }

            if character == "×" || character == "*" {
                tokens.append(.multiplier)
            } else if character == "%" {
                tokens.append(.word("%"))
            }
            index += 1
        }
        return tokens
    }

    // MARK: - Pieces

    private static func numberToken(
        _ characters: [Character], from start: Int, to end: Int
    ) -> Token {
        let followsSeparator = start > 0 && isDecimalSeparator(characters[start - 1])
        let precedesSeparator = end < characters.count && isDecimalSeparator(characters[end])

        let isFraction = (followsSeparator && start > 1 && characters[start - 2].isASCIIDigit)
            || (precedesSeparator && end + 1 < characters.count && characters[end + 1].isASCIIDigit)
        if isFraction { return .decimal }

        // A run longer than `Int` can hold is a lot number or a phone
        // fragment, never a pack size. `Int.max` fails the plausible range on
        // its own, so there is no second rejection path to keep in step.
        guard let value = Int(String(characters[start..<end])) else { return .number(.max) }
        let isNegative = start > 0 && characters[start - 1] == "-"
        return .number(isNegative ? -value : value)
    }

    private static func isDecimalSeparator(_ character: Character) -> Bool {
        character == "." || character == ","
    }

    /// The index just past `N1`/`N2`/`N3`, or nil when this is not one.
    ///
    /// Only the closed-up form is read. `N 1` with a space is not something we
    /// have seen printed, and guessing at it would mean treating a lone `n`
    /// before any digit as a size class.
    private static func packSizeClass(
        _ characters: [Character], word: String, after end: Int
    ) -> Int? {
        guard word == "n", end < characters.count,
              let digit = characters[end].wholeNumberValue, (1...3).contains(digit),
              end + 1 >= characters.count || !characters[end + 1].isASCIIDigit
        else { return nil }
        return end + 1
    }
}

private extension Character {
    /// `isNumber` is true for `½` and for Eastern Arabic digits; a pack size is
    /// written in the digits `Int(_:)` can read.
    var isASCIIDigit: Bool { isASCII && isNumber }
}
