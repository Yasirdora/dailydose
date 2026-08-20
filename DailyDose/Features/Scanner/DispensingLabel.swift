import Foundation

/// A pharmacy dispensing label — and everything on one this app must not read.
///
/// A carton and a dispensing label are different documents. A carton is a
/// product: a name, a strength, a form, a pack size. A label is a *transaction*:
/// it names a patient, a prescriber, a pharmacist, a prescription number and a
/// date, and only incidentally the medicine. The extraction rules that are
/// right for one are wrong for the other, and one of them is a privacy defect.
///
/// **The defect.** A real label put `Jane Doe` in the medication name field,
/// and it would have been written to disk. `SCANNING-DESIGN.md` §5.4 has always
/// required that patient and prescriber names are discarded at the region
/// level, before any parsing, and never persisted, logged or exported. This is
/// that rule.
///
/// It is deliberately blunt. Everything from a prescriber marker onward goes,
/// whole lines carrying a prescription number go, and on a recognised label the
/// line above the drug goes on sight. That will sometimes throw away a line
/// that was harmless — and that is the correct trade, because the field it
/// protects is one the user can fill in three seconds, and the failure it
/// prevents is a person's name in someone's medication list.
enum DispensingLabel {

    // MARK: - Recognising one

    /// Words that only appear on a dispensing label, scored one each.
    private static let signals: [String] = [
        "rx #", "rx#", "qty", "quantity", "refills", "refill", "filled",
        "pharmacy", "apotheke", "pharmacie", "farmacia", "physician",
        "prescriber", "pharmacist", "by mouth", "orig rx", "use by",
        "prescribed", "verordnet",
    ]

    /// Two signals or more. One is not enough: "Qty" alone appears on plenty of
    /// cartons, and misreading a carton as a label costs it the height ranking
    /// that finds its name.
    static func isDispensingLabel(_ lines: [String]) -> Bool {
        let folded = CartonText.fold(lines.joined(separator: "\n"))
        var found = 0
        for signal in signals where folded.contains(signal) {
            found += 1
            if found >= 2 { return true }
        }
        // A phone number counts as one: pharmacies print one, cartons do not.
        return found >= 1 && containsPhoneNumber(folded)
    }

    private static func containsPhoneNumber(_ folded: String) -> Bool {
        folded.range(of: #"\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}"#, options: .regularExpression) != nil
    }

    // MARK: - What must never be read

    /// Markers after which the rest of the line is a person's name.
    ///
    /// Truncated at rather than dropped whole, because a label packs two
    /// columns onto one printed line: `Qty:90    Physician: Test Doctor` holds
    /// the one number that matters and the prescriber's name side by side.
    private static let personMarkers: [String] = [
        "physician", "prescriber", "pharmacist", "prescribed by", "dispensed by",
        "dr.", "arzt", "ärztin", "verordnet von", "apotheker",
    ]

    /// `Dr.` carries its period deliberately. A bare "dr" would truncate
    /// "Doxycycline DR 100mg" — `DR` is delayed release — and take the strength
    /// with it. Prescribers on a real label are named after `Physician:`,
    /// `Prescriber:` or `Dr.`, all of which are covered.

    /// Markers that make a whole line a dispensing record rather than a
    /// medicine. Nothing on such a line is ever wanted: a prescription number,
    /// a fill date and a patient reference are what they carry.
    private static let recordMarkers: [String] = [
        "rx #", "rx#", "orig rx", "refills", "refill", "filled:", "filled ",
        "use by", "ndc", "din ", "din:", "patient", "member id", "insurance",
    ]

    /// Whether this line must be discarded outright.
    static func isPrivate(_ line: String) -> Bool {
        let folded = CartonText.fold(line)
        return recordMarkers.contains { folded.contains($0) }
    }

    /// The line with everything from a person marker onward removed, or nil
    /// when nothing of it survives.
    private static func truncated(_ line: String) -> String? {
        // Searched on the original rather than a folded copy: folding can
        // change a string's length (`ß` becomes `ss`), and an offset taken in
        // one string and applied to the other would cut in the wrong place.
        // `.diacriticInsensitive` gives the same reach without the mapping.
        var cut: String.Index?
        for marker in personMarkers {
            guard let range = line.range(
                of: marker, options: [.caseInsensitive, .diacriticInsensitive]
            ) else { continue }
            cut = min(cut ?? range.lowerBound, range.lowerBound)
        }
        guard let cut else { return line }
        let kept = String(line[..<cut]).trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? nil : kept
    }

    /// Every line the app is allowed to look at, in reading order.
    ///
    /// Applied before ranking, never after: §5.4 requires that these fragments
    /// never enter a candidate list at all, and a filter on the *winner* would
    /// mean the patient's name had already competed for the field.
    static func redacted(_ lines: [String]) -> [String] {
        let kept = lines.compactMap { line -> String? in
            guard !isPrivate(line) else { return nil }
            return truncated(line)
        }
        guard isDispensingLabel(kept) else { return kept }
        guard let drug = kept.firstIndex(where: { drugLineCandidate($0) }), drug > 0 else { return kept }
        // The patient's name is conventionally the line immediately above the
        // drug, and is the one line on a label with no digit, no unit and no
        // dosage form in it — which is also the only description that fits a
        // person's name and nothing else.
        guard looksLikeAPersonName(kept[drug - 1]) else { return kept }
        var result = kept
        result.remove(at: drug - 1)
        return result
    }

    private static func looksLikeAPersonName(_ line: String) -> Bool {
        guard !line.contains(where: { $0.isNumber }) else { return false }
        guard MedicationForm.detect(in: line) == nil else { return false }
        guard !LabelScanParser.containsStrength(line) else { return false }
        return line.contains(where: { $0.isLetter })
    }

    // MARK: - Reading one

    /// Anchors a US label prints directly beneath the drug line.
    private static let drugAnchors: [String] = ["mfg:", "mfg :", "generic for", "manufacturer:"]

    private static func drugLineCandidate(_ line: String) -> Bool {
        LabelScanParser.containsStrength(line)
    }

    /// The one line that names the medicine: `<Name> <strength><unit> <Form>`.
    ///
    /// The *only* name source on a label. Height ranking is right for a carton,
    /// where the largest text is the medicine — and wrong here, where the
    /// largest text is very often the patient.
    static func drugLine(in lines: [String]) -> String? {
        // Preferred: the line an anchor sits under. US labels print
        // "Mfg: ACCORD HEALTHCARE" and "Generic for: Prograf" immediately
        // below the drug, which pins it exactly.
        if let anchor = lines.firstIndex(where: { line in
            let folded = CartonText.fold(line)
            return drugAnchors.contains { folded.contains($0) }
        }), anchor > 0, drugLineCandidate(lines[anchor - 1]) {
            return lines[anchor - 1]
        }
        return lines.first(where: drugLineCandidate)
    }
}
