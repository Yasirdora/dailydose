# Implementation brief — Daily Dose: robust carton extraction

**Repository:** `~/Documents/kimi/workspace/DailyDose`
**Deployment target:** iOS 17.0 · Swift 5 · Xcode 16 synchronized folder groups

Device testing found that scanning a pack fills the name and strength but leaves **Form** on "Choose" and **Supply** empty. Form is conservative by design; **supply has never been implemented at all** — nothing in the scan path has ever touched `pillsRemaining`, and there is no pack-size concept anywhere in the codebase.

This brief adds it, and makes name and form extraction solid across the markets the app will launch in.

Work to a professional standard: surgical, testable, no scope creep. **Stop and report when done.**

---

## 0. Scope

**In scope — the product carton only:** medication name, dosage form, pack quantity.

**Out of scope — do not start:** dosing directions, sig parsing (BID/TID/q8h), dispensing-label field extraction, `RecognizeDocumentsRequest`, `FoundationModels`. That work is real but needs a corpus of dispensing-label photographs we do not have, and cartons are what users are actually scanning today.

---

## 1. The organising idea

**A dosage-form word carries two facts at once.** "30 Filmtabletten" tells you the pack holds 30 *and* that the medication is a pill. "200 Hub" tells you 200 doses *and* that it is an inhaler.

So build **one lexicon** with two outputs — a `MedicationForm` and a counting noun — rather than a quantity parser and a form detector that can disagree about the same word. `MedicationForm.detect` should be refactored to read from that lexicon, not keep a second private list.

This matters for correctness, not elegance: today `MedicationForm.detect` uses substring `contains`, so `"gel"` matches inside unrelated words. Move to word-boundary matching against the shared lexicon while you are here.

---

## 2. Quantity extraction

### 2.1 Pattern

The general shape is `<number> <form noun>`, with a multi-pack variant:

```
30 Tabletten          → 30
90 TABLETS            → 90
Qty 60                → 60
3 x 10 Tabletten      → 30      (blister packs — multiply)
100 St.               → 100
200 Hub               → 200     (inhaler actuations)
20 Beutel             → 20
```

Number-first is the norm, but handle a trailing form too (`Tabletten 30`). Accept `x`, `×` and `X` as the multiplier.

### 2.2 Lexicon — start here, this is not exhaustive

| Language | Counting nouns |
|---|---|
| English | tablet(s), capsule(s), caps, tabs, pill(s), softgel(s), lozenge(s), sachet(s), ampoule(s), vial(s), patch(es), suppositor(y/ies), dose(s), puff(s), actuation(s), count, ct, mL |
| German | Tablette(n), Filmtablette(n), Hartkapsel(n), Weichkapsel(n), Kapsel(n), Dragee(s), Zäpfchen, Beutel, Ampulle(n), Pflaster, Stück, St., Hub, ml |
| French | comprimé(s), gélule(s), capsule(s), sachet(s), ampoule(s), suppositoire(s), pastille(s), ml |
| Spanish | comprimido(s), cápsula(s), sobre(s), ampolla(s), supositorio(s), ml |
| Italian | compressa/e, capsula/e, bustina/e, fiala/e, supposta/e, ml |
| Dutch | tablet(ten), capsule(s), zakje(s), ampul(len) |
| Portuguese | comprimido(s), cápsula(s), saqueta(s), sachê(s), ampola(s) |
| Polish | tabletka/i, kapsułka/i, saszetka/i, ampułka/i |
| Nordic | tablett(er), kapsel/kapslar (SV) · tablet(ter), kapsel/kapsler (DA/NO) · tabletti(t), kapseli(t) (FI) |

Match case- and diacritic-insensitively (`String.compare` with `.caseInsensitive` and `.diacriticInsensitive`), so `KAPSELN`, `kapseln` and `Kapseln` all hit.

Every entry maps to a `MedicationForm` as well as being a counting noun. Where a language's word is ambiguous, prefer the more specific form (a "Zäpfchen" is a suppository, not a generic pill).

### 2.3 Safety rules — these are not optional

**German Normgrößen `N1` / `N2` / `N3` must never become a number.** They are package *size classes*, and the actual count varies by drug — N1 might be 20 tablets for one medicine and 10 for another. Detect them, record them as a note if useful, but **do not convert them to a count.** Inventing a supply figure is worse than leaving it blank, because the refill warning is built on it.

**Do not confuse strength with quantity.** `500 mg` is a strength; `30 Tabletten` is a quantity. They are different token classes and separate cleanly — but `20 ml` is genuinely ambiguous for a liquid, where the pack size *is* a volume. Rule: a `ml` figure counts as quantity only when no other quantity was found **and** a strength has already been captured from a different token. When still ambiguous, prefer no answer over a guess.

**Take the largest plausible count when several appear**, but reject anything outside `1...5000` — a lot number or a phone fragment can look like a count.

**AI (30)** in a GS1 HRI string is the exact item count. Prefer it over any OCR reading when present.

---

## 3. Name extraction

Two concrete improvements, both available at iOS 17:

**Use text size as a signal.** The medication name is almost always the largest text on a carton. `VNRecognizedTextObservation.boundingBox` height is a usable proxy — rank candidates by height rather than by the current "longest string" heuristic, which favours legal text and addresses.

**Reject known non-names.** Add a rejection list alongside the existing barcode-transcription rule: manufacturer and pharmacy boilerplate (`Gebrauchsinformation`, `Beipackzettel`, `Packungsbeilage`, `Rezeptpflichtig`, `Apothekenpflichtig`, `verschreibungspflichtig`, `Lot`, `Ch.-B.`, `Verw. bis`, `EXP`, `MFG`, `Keep out of reach of children`, `Store below`), plus any line that is only digits and punctuation.

Keep the existing behaviour that a name is either real or empty. An empty field the user fills is honest; a wrong one pre-filled is a trap they save without re-reading.

---

## 4. Wiring

`MedicationDraft.apply(_ result:)` gains quantity. When a count is found:

- set `pillsRemaining`
- set `tracksSupply = true`
- leave `refillThreshold` **nil** unless you implement §4.1

Mark these as scanned rather than typed, consistent with how the rest of the form treats provenance, so the user can see the number came from the label and check it.

A scan must **never overwrite a value the user has already entered** — the same rule `form` already follows.

### 4.1 Optional: a default refill threshold

If a count and a schedule both exist, a threshold of roughly **seven days of doses** (`dosesPerDay × 7`, clamped to at most a third of the pack) is a defensible default and makes the warning useful immediately. This is a *supply* calculation, not a dose calculation, so it does not touch App Review Guideline 1.4.2 — but it is a product decision. **Propose it in your report rather than shipping it unasked.**

---

## 5. Tests

Pure, no device. `CartonExtractionTests.swift`:

- One vector per language in §2.2, minimum.
- `3 x 10 Tabletten` → 30. `3 × 10` and `3X10` likewise.
- `N1`, `N2`, `N3` → **no count**, with a test that says why.
- `500 mg` alone → no quantity. `500 mg 30 Tabletten` → strength 500 mg **and** quantity 30.
- `20 ml` ambiguity resolves per §2.3, in both directions.
- Counts of `0`, `9999`, `-5` and a 10-digit number → rejected.
- Diacritic and case variants: `KAPSELN`, `cápsulas`, `CÁPSULAS`, `Kapsułki`.
- Form and quantity derived from one token agree — assert both come out of `30 Filmtabletten`.
- `MedicationForm.detect` no longer matches `gel` inside an unrelated word.
- Name ranking prefers the larger observation; the rejection list drops boilerplate.

---

## 6. The honest limitation

**This lexicon is assembled from knowledge, not from photographs of real packs.** It will be wrong in ways nobody can predict from a desk — abbreviations, line breaks mid-phrase, OCR confusions (`O`/`0`, `l`/`1`, `rn`/`m`).

So: structure the lexicon as **data, not code** — one table, easy to extend without touching logic — and say clearly in your report which entries you are confident about and which are educated guesses. When real pack photographs arrive, extending a table is a five-minute job; unpicking a hand-rolled regex is not.

Do not claim coverage you have not tested.

---

## 7. Constraints

- Domain layer stays pure: `Foundation` only. No Vision, SwiftData or SwiftUI in the lexicon or parser.
- No new dependencies. No schema change — `pillsRemaining` already exists.
- Surgical anchored edits; re-read files immediately before writing, the user edits this repo while you work.
- Do not commit. Do not refactor code you merely read.
- Doc comments explain *why* — name the bug a rule prevents.

## 8. Done when

- [ ] Builds for iOS 17.0, no new warnings; full suite passes.
- [ ] Scanning a carton that prints a count fills Supply, and one that does not leaves it blank.
- [ ] Form and quantity derive from the same lexicon and cannot disagree.
- [ ] `N1`/`N2`/`N3` never produce a number.
- [ ] No regression in existing name and strength extraction.

Then **stop** and report: which lexicon entries are verified versus guessed; whether you recommend the §4.1 default threshold; what you could not verify without real pack photographs; and the risks a reviewer should look at hardest.
