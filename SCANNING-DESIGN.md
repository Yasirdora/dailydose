# Scanning Architecture — Barcode + Label OCR

**Status:** design proposal
**Date:** 19 August 2026
**Scope:** international launch, US as a key market, Germany/EU as home market
**Constraint accepted:** no paid data licences. Free and open sources only.
**Current deployment target:** iOS 17.0, Swift 5 mode

---

## 0. The decision that shapes everything else

There is one architectural choice here that determines the privacy posture, the App Store posture, the GDPR posture, the offline behaviour and the running cost, and it is this:

> **The scan path makes no network requests. Ever.**

Not "minimal requests." Not "anonymised requests with consent." **None.** The US drug database is public-domain data that we ship as a file and refresh in the background like any other app resource — we never send a medication identifier anywhere to ask what it is.

This is available to us because the FDA's National Drug Code Directory is released under **CC0 1.0 Universal** — public domain, redistribution explicitly permitted. So the question "how do we send an NDC to openFDA safely?" has a better answer than any amount of consent UI: **don't send it.** Ship the answers instead of asking the questions.

What that single decision buys:

| Problem | How it disappears |
|---|---|
| GDPR Art. 44–49 international transfer to a US federal agency | No transfer occurs. Not a hard question answered carefully — a question that never arises. |
| Medication data is GDPR Art. 9 special-category data | Never processed by us as a controller. It stays on the user's device. |
| API key embedded in a shipped binary | No key exists. |
| openFDA rate limits (1,000/day/IP unauthenticated) | Not on the critical path. |
| Apple App Privacy "collect" disclosure | Apple: *"Data that is processed only on device is not 'collected' and does not need to be disclosed."* Nothing to declare. |
| Guideline 5.1.2(i) — disclose sharing with third-party AI | Nothing is shared. Apple's on-device model is not a third party. |
| Scanning works on a plane / in a basement pharmacy | It just works. |
| The privacy claim already in our camera usage string | Stays true, verbatim, forever. |

Our `NSCameraUsageDescription` currently promises the image *"is analyzed on this device and never saved or shared."* Every other design I considered required weakening that sentence. This one lets us strengthen it.

---

## 1. What a barcode can and cannot tell us

A barcode is a number. Its value depends entirely on whether we can resolve that number — and that varies enormously by market.

### 1.1 What is free, everywhere, with no database at all

This is the part most teams miss. The **GS1 DataMatrix on every EU prescription pack, and on every US prescription pack under DSCSA, carries the expiry date and batch number inside the code itself.** No lookup. No network. No licence.

| Element | GS1 AI | IFA/PPN DI | Value to us |
|---|---|---|---|
| Product code | `01` GTIN-14 | `9N` PPN | Stable identity key |
| **Expiry date** | `17` YYMMDD | `D` YYMMDD | **Free, universal, and nobody else does this well** |
| Batch / lot | `10` | `1T` | Recall matching, later |
| Serial | `21` | `S` | Deliberately discarded — see §5.4 |

Expiry alone justifies barcode support in every market. *"This pack expires in 3 weeks and you have 40 doses left at 2/day"* is a genuinely useful, genuinely novel warning, and it costs us one parser and zero data licences.

### 1.2 What is free in the US

The FDA NDC Directory: **137,153 product records**, CC0, updated daily, downloadable in bulk as zipped JSON. Each record carries `brand_name`, `generic_name`, `dosage_form`, `route`, `labeler_name`, `active_ingredients[].strength`, and a `packaging[]` array with package-level NDCs. That is everything the Add Medication form needs except the schedule.

So in the US, a scan of a retail pack can fill name, strength, and form deterministically.

### 1.3 What is not free (and which we are therefore not doing)

Germany's **PZN → product name** mapping lives in IFA GmbH's commercial article database. Per the constraint, we do not licence it. Same for most other national registries.

**But — and this is the important nuance — the *encodings* are free.** The IFA specifications for the PPN structure, the Data Identifier layout and the check-digit algorithms are published. So in Germany we can, for free:

- parse the DataMatrix correctly (PPN or NTIN syntax),
- extract and validate the **8-digit PZN**,
- extract the **expiry date** and batch,
- use the PZN as a stable identity key.

What we cannot do for free is turn `PZN 12345678` into `"Metformin HCl 500 mg Filmtabletten"`. **The OCR does that instead** — and the box is right there in front of the camera with the name printed on it in 14pt type.

That is the whole design in one sentence: **the barcode gives us identity and dates; the camera gives us meaning.**

### 1.4 Market summary

| Market | Identity | Expiry | Product name from barcode | Name from OCR |
|---|---|---|---|---|
| **US** | GTIN → NDC | ✅ free | ✅ **free, offline (FDA CC0)** | ✅ fallback |
| **Germany** | PPN/NTIN → PZN | ✅ free | ❌ not free — skipped | ✅ **primary** |
| **Rest of EU** | GTIN | ✅ free | ❌ | ✅ primary |
| **UK** | GTIN if present* | ✅ if present | ❌ | ✅ primary |
| **Everywhere** | Barcode-as-identity (§4.3) | — | ✅ after first scan | ✅ |

\* FMD no longer applies in the UK — Great Britain since Dec 2020, Northern Ireland since 1 Jan 2025. A UK pack may carry no DataMatrix and no serial at all. **Absent codes are normal there, not an error.**

---

## 2. Architecture

The shape follows the codebase's existing rule: **the domain layer imports Foundation and nothing else.** Every parsing, validation and normalisation decision is a pure function over values, testable without a camera, a device, or a network.

```
Domain/                          ← Foundation only. No Vision, no SwiftData, no UIKit.
  Barcode/
    BarcodePayload.swift         Raw bytes + symbology, straight from the scanner
    GS1Parser.swift              AI stream → elements
    PPNParser.swift              ISO/IEC 15434 Format 06 → elements
    BarcodeInterpreter.swift     Dispatch + normalisation → ScannedPack
    ScannedPack.swift            The canonical result value
    CheckDigit.swift             GTIN mod-10, PZN mod-11, PPN mod-97
    NationalDrugCode.swift       Segmented, version-tagged (see §3.4)
    ProductKey.swift             The market-agnostic identity key
  Label/
    SigLexicon.swift             Pharmacy shorthand → structured directions
    LabelFields.swift            The typed result of reading a dispensing label
    LabelInterpreter.swift       Structured OCR regions → LabelFields
    SigParser.swift              Directions text → ScheduleProposal
    ScheduleProposal.swift       A *proposal*, never a saved schedule

Services/
  DrugDirectory.swift            Local NDC index. Read-only, offline, no network in scan path.
  DirectoryUpdater.swift         Background refresh of the dataset file (the ONLY network use)
  ScanPipeline.swift             Orchestrates capture → interpret → propose

Features/Scanner/
  ScanSession.swift              Vision/VisionKit adapters (the only impure layer)
  ScanReviewView.swift           The confirmation screen (§6)
```

`ScanPipeline` is the only type that knows about both halves. Everything below it is pure and unit-testable; everything above it is a view.

### 2.1 Capability ladder

We target iOS 17. The best tools require iOS 26 and, for the language model, an Apple Intelligence device in a supported region. So the pipeline is a **ladder where every rung produces a usable result**, and the higher rungs only ever improve confidence and reduce typing.

| Tier | Requires | Barcode | Text | Structure | Sig understanding |
|---|---|---|---|---|---|
| **0 — Baseline** | iOS 17 | `DataScannerViewController` (iOS 16+) | `VNRecognizeTextRequest` (iOS 13+) | geometric heuristics | `SigLexicon` (deterministic) |
| **1 — Structured** | iOS 26 | same | `RecognizeDocumentsRequest` | real paragraphs, lines, words, tables, bounding regions | `SigLexicon` |
| **2 — Assisted** | iOS 26 + Apple Intelligence | same | `RecognizeDocumentsRequest` | same | `SigLexicon` **then** `FoundationModels` for the residue |

**Non-negotiable rule: Tier 2 is never load-bearing.** The on-device model is available only on Apple Intelligence hardware, in supported regions, when the user has it enabled and the assets have downloaded. `RecognizeDocumentsRequest` has no such gate, so Tier 1 is available on strictly more devices than Tier 2. If the model is unavailable the feature does not degrade — it simply asks the user to confirm one more field.

```swift
switch SystemLanguageModel.default.availability {
case .available:                            tier = .assisted
case .unavailable(.deviceNotEligible):      tier = .structured   // permanent — hide the affordance
case .unavailable(.appleIntelligenceNotEnabled),
     .unavailable(.modelNotReady):          tier = .structured   // transient — re-check, never disable
case .unavailable:                          tier = .structured
}
```

`.modelNotReady` is transient — the assets download after a user enables Apple Intelligence. Treat it as "not yet", re-check on `scenePhase`, and never permanently disable a feature because of it. Only `.deviceNotEligible` is permanent.

---

## 3. Barcode: the parser specification

This is the piece where being sloppy produces a *silently wrong* lot number or expiry date on a medicine, so it is specified precisely and tested against known vectors.

### 3.1 Dispatch

Two syntaxes reach us, and they are distinguishable from the payload alone — which matters, because the symbology identifier is not always transmitted.

```swift
func interpret(_ payload: BarcodePayload) -> ScannedPack? {
    let raw = payload.bytes

    // 1. ISO/IEC 15434 Format 06 — the IFA/PPN envelope. Definitive test.
    if raw.starts(with: [0x5B, 0x29, 0x3E, 0x1E, 0x30, 0x36, 0x1D]) {   // "[)>" RS "06" GS
        return PPNParser.parse(raw)
    }
    // 2. GS1: leading FNC1 is transmitted as the symbology id "]d2", never as data.
    if payload.symbologyIdentifier == "]d2" || raw.first == 0x1D {
        return GS1Parser.parse(dropSymbologyID(raw))
    }
    // 3. Envelope-stripped fallbacks. Order matters — test PPN's "9N" before GS1's "01",
    //    because "01" is also a legal start to a PPN *value*.
    if raw.starts(with: Array("9N".utf8)) { return PPNParser.parseBody(raw) }
    if matchesGS1Opening(raw)             { return GS1Parser.parse(raw) }
    // 4. Plain linear code: UPC-A / EAN-13 / ITF-14.
    if let gtin = GTIN(digits: raw), gtin.hasValidCheckDigit { return ScannedPack(gtin: gtin) }

    return nil
}
```

### 3.2 GS1 element string parsing

The rules that matter, and the two that bite:

- **Fixed-length AIs are never followed by a separator.** `01` is 14 digits, `17` is 6. Read by byte count.
- **Variable-length AIs run to the next `GS` (0x1D) or end-of-data.** `10` (batch) and `21` (serial) are 1–20 characters of GS1 CSET-82 — **case-sensitive and alphanumeric. Never upper-case them, never trim them, never coerce to digits.**
- A `GS` immediately after a fixed-length field is technically non-conformant and **extremely common in the wild**. Tolerate and skip it.
- A trailing `GS` after the final field is legal and redundant. Emit no empty field.

Restrict ourselves to the AIs a medicine pack actually carries, and **reject unknown AIs rather than guessing their length** — a wrong length guess corrupts every field after it, silently:

| AI | Length | Content |
|---|---|---|
| `01` | fixed 14 | GTIN, mod-10 checked |
| `17` | fixed 6 | Expiry YYMMDD |
| `10` | var ≤20 | Batch / lot |
| `21` | var ≤20 | Serial |
| `710` | var ≤20 | NHRN — PZN (Germany) |
| `715` | var ≤20 | NHRN — **NDC (US), explicit.** Prefer this over GTIN inference when present. |

**Failure rule:** if a variable-length field is followed by more data and no `GS` appears, the boundary is formally unrecoverable. Do not guess. **Reject the scan and ask for a re-scan.** A wrong batch number on a medicine is a safety event, and "please scan again" costs the user two seconds.

### 3.3 PPN / Germany

Format 06 envelope, `GS`-delimited fields, **arbitrary field order** — index by Data Identifier, never by position. Match DIs longest-first (`9N` before `N`, `1T` before `T`).

```
[)>{RS}06{GS}9N111234567842{GS}1T1A234B5{GS}D151231{GS}S1234567890123456{RS}{EOT}
```

The trailer is optional in the wild; require the header, tolerate a missing trailer.

**Extracting the PZN — two routes, both free:**

```swift
// Route A — PPN syntax. PPN = PRA code "11" + 8-digit PZN + 2-digit check.
if ppn.hasPrefix("11"), ppn.count >= 10 {
    pzn = String(ppn.dropFirst(2).prefix(8))
}
// Route B — NTIN syntax. GTIN-13 = "4150" + 8-digit PZN + mod-10 check.
if gtin14.hasPrefix("04150") {
    pzn = String(gtin14.dropFirst(5).prefix(8))
}
```

Gate route A on the `"11"` prefix — other Product Registration Agency codes exist and their payloads are not PZNs.

### 3.4 US: GTIN → NDC, and why it needs the local directory

The convention: `GTIN-12 = "3" + NDC-10 + mod-10 check digit`, zero-padded to GTIN-14 as `003…`.

Steps 1–3 are deterministic. **Step 4 is not, and this is the single most important correctness point in the barcode work.**

```
1. Reduce to GTIN-12   (strip "00" from a GTIN-14, "0" from a GTIN-13)
2. Require g[0] == "3" (otherwise this GTIN does not embed an NDC — not an error, just
                        not resolvable this way; fall back to AI(715) or OCR)
3. Verify mod-10, extract ndc10 = g[1..<11]
4. SEGMENT — cannot be done from the digits alone.
```

The 10 digits carry no delimiter recording where the labeler code ends. `1234567890` is a syntactically valid **4-4-2**, **5-3-2** *and* **5-4-1** NDC, producing three different 11-digit strings. We generate all three candidates and resolve against the local FDA directory index; exactly one should match a real package NDC. If zero match, the product is unlisted or the GTIN isn't NDC-derived — say so and fall back to OCR. If we ever inferred rather than matched, the result is tagged `confidence: .inferred` and the UI never presents it as certain.

**Prefer `AI(715)` when present** — it carries the NDC explicitly and needs no inference at all.

**Design for 2033 now.** FDA published a final rule on 5 March 2026 moving the NDC to a uniform **12-digit 6-4-2 format**, effective **7 March 2033** with a transition to 2036. A 12-digit NDC **does not fit in a GTIN-12**, so the "3 + NDC-10 + check" convention has a hard end-of-life and the structural GTIN↔NDC relationship simply ceases. Therefore:

```swift
/// Never an 11-character String. The segmentation is meaning, and the format changes in 2033.
struct NationalDrugCode: Hashable, Sendable {
    enum Format: String, Sendable { case f442, f532, f541, f642 }
    let labeler: String, product: String, package: String
    let format: Format
    let confidence: Confidence   // .explicit (AI 715 / directory match) | .inferred
}
```

### 3.5 Check digits — all three, with verified vectors

| Code | Algorithm | Verified against |
|---|---|---|
| **GTIN** 8/12/13/14 | mod-10, weights 3,1 alternating **from the right**; `(10 - sum % 10) % 10` | `00312345678906` → 6 ✔ |
| **PZN-8** | mod-11, weights 1…7 over the first 7 digits; **remainder 10 ⇒ not a valid PZN** (no substitution — such numbers are never issued) | `2758089` → 9 ✔ · `1234567` → 8 ✔ |
| **PPN** | mod-97 over the **ASCII values** of every character of the body, weights from 2, zero-padded to two digits | `1103752864` → 14 ✔ · `1112345678` → 42 ✔ |

The PPN algorithm operating on ASCII values rather than digit values is the classic implementation bug — both worked examples above are in the test vectors.

### 3.6 Expiry dates — two rules, not one

`YYMMDD`. `DD == "00"` means "last day of that month".

Two market-specific wrinkles that a single code path gets wrong:

- **GS1 healthcare has prohibited `DD = 00` since 1 January 2025.** German **PPN syntax still permits it.** So we must *accept* `00` on input from both (legacy stock is still in circulation) and normalise to the month's last day, while only flagging it as non-conformant for newly-issued GS1 codes.
- **Century window differs by syntax.** GS1 specifies a ±50-year sliding window. IFA states PPN dates are always 21st century, i.e. `year = 2000 + YY`.

The GS1 window has a nasty edge for us: in 2026, `YY = 25` resolves to **1925**, not 2025 — technically correct, and absurd on screen for a pack that expired last year. **For medicine expiry we override to a forward-biased window** (`[today − 2 years, today + 97 years]`) and log the deviation. Shelf lives beyond a decade do not exist in this category.

---

## 4. Identity: the feature that works in every market for free

### 4.1 One key, whatever the market

```swift
/// A market-agnostic product identity, in preference order.
enum ProductKey: Hashable, Sendable {
    case ndc(NationalDrugCode)   // US, resolvable against the local directory
    case pzn(String)             // Germany, validated but not resolvable — a key, not a name
    case gtin(String)            // anywhere
}
```

### 4.2 The local FDA directory

A read-only index built from the CC0 bulk dataset, refreshed in the background. **This is the only network call in the entire feature, it fetches a static file from our own CDN, and it carries no query, no identifier, and no user data.** It is indistinguishable from an app resource update, because that is what it is.

Two things the directory build must get right:

1. **openFDA stores NDCs hyphenated in their native segmentation** (`50090-6441-0`), not normalised. A raw 11-digit string from a barcode will not match. Normalise both sides to 5-4-2 when building the index.
2. **`active_ingredients[].strength` is free text with a denominator** — `"40 mg/1"`. Parse it into our existing `StrengthUnit` model; keep the raw string for display when parsing fails.

We ship a trimmed index — the fields the editor needs, not the whole record — so the download stays small and the on-device lookup is a single hash probe.

### 4.3 Barcode-as-identity: the part that needs no database at all

Store the `ProductKey` on the medication. The first time a user scans an unknown pack, they confirm the name once — as they do today. **Every subsequent scan of that pack is instant, offline, in any country, with no database whatsoever.**

That gives us, for free and everywhere:

- **Refill:** scan the new box, it matches an existing medication, supply tops up. No typing.
- **Safety check:** "Is this the right box?" — scan and confirm. This is a real use case for someone managing eight medications, and it is the kind of thing that makes an app trusted.
- **Expiry warnings**, straight from the code (§1.1).

**Explicit non-goal: we do not crowdsource the barcode→name mapping to a server.** It would re-open every privacy question this design closes, and it would make us the publisher of drug identity data we cannot validate — which is precisely the accuracy exposure App Review Guideline 1.4.1 targets. The mapping stays on the user's device.

---

## 5. OCR: making the label read well

This is where the remaining value is, and it splits into two very different jobs.

| Target | What it gives | Where it matters |
|---|---|---|
| **Product carton** | name, strength, form | Everywhere the barcode can't be resolved — i.e. Germany and most of the world |
| **Pharmacy dispensing label** | **the directions** — "take one tablet twice daily" | **Everywhere.** No barcode carries this. It is patient-specific. |

The second is the prize. The barcode identifies the drug; only the dispensing label knows how *this person* was told to take it — and the schedule is the tedious half of adding a medication.

### 5.1 Structure before text

On iOS 26+, `RecognizeDocumentsRequest` returns a hierarchy — paragraphs, lines, words, tables, lists, detected data — each with a bounding region, rather than a flat string. Apple's own documentation names *"receipts, nutritional labels, forms"* as the target; a dispensing label is the same shape of problem.

This matters because a dispensing label has **stable geometry**:

```
┌─────────────────────────────────┐
│ CITY PHARMACY · 555-0100        │  ← pharmacy block (top, small)
│ Rx 4417822          Dr. A. Chen │  ← identifiers
│ JANE DOE                        │  ← PATIENT NAME — see §5.4
├─────────────────────────────────┤
│ METFORMIN HCL 500 MG TABLET     │  ← product line (bold, often largest)
│                                 │
│ TAKE 1 TABLET BY MOUTH          │  ← THE SIG (largest body text)
│ TWICE DAILY WITH MEALS          │
├─────────────────────────────────┤
│ Qty 60   Refills 2   Exp 03/27  │  ← trailer, often tabular
└─────────────────────────────────┘
```

We classify **regions**, not lines: relative font size, vertical order, and the presence of an imperative verb are far stronger signals than any regex over a flat dump. `boundingRegion(for:)` lets us anchor a specific character range back to a rectangle on screen — which is how the review screen highlights *"this is where I read that."*

On iOS 17–25 we fall back to `VNRecognizeTextRequest` and reconstruct rough structure from observation bounding boxes. Less precise, still workable.

### 5.2 Two recognition passes, deliberately

There is a real, documented tension in Vision: `customWords` **only applies when `usesLanguageCorrection` is true** — and language correction is exactly what mangles alphanumeric codes like `Rx 4417822` or an NDC.

You cannot have both in one pass. So don't:

| Pass | `usesLanguageCorrection` | `customWords` | Reads |
|---|---|---|---|
| **A — language** | `true` | drug name lexicon, sig vocabulary | product name, directions, warnings |
| **B — literal** | `false` | — | Rx number, NDC, dates, quantities |

Two passes over the same captured frame, each configured for what it is actually reading. The drug-name lexicon comes free from the FDA dataset we already ship — 137k product records is a very good `customWords` source for US labels, and generic names (`metformin`, `atorvastatin`) are near-universal across markets.

### 5.3 The sig lexicon — deterministic, testable, no model required

Pharmacy directions are a **closed vocabulary**. This is not a job for a language model; it is a job for a lookup table and a parser, which is faster, works on every device, and can be exhaustively tested.

| Shorthand | Expansion | Schedule meaning |
|---|---|---|
| `QD`, `OD`, `once daily` | once a day | `.daily`, 1 time |
| `BID`, `b.i.d.`, `twice daily` | twice a day | `.daily`, 2 times |
| `TID`, `three times daily` | three times a day | `.daily`, 3 times |
| `QID`, `four times daily` | four times a day | `.daily`, 4 times |
| `QHS`, `HS`, `at bedtime` | at bedtime | `.daily`, 1 time @ 22:00 |
| `QAM` / `QPM` | morning / evening | `.daily`, 1 time @ 08:00 / 20:00 |
| `Q8H`, `every 8 hours` | every 8 hours | **`.everyXHours`, 8** |
| `QOD`, `every other day` | every other day | **`.everyXDays`, 2** |
| `Q wk`, `weekly` | weekly | `.weekdays`, 1 day |
| `PRN`, `as needed` | as needed | **no schedule — see below** |
| `PO` | by mouth | form hint: oral |
| `1 tab`, `2 caps`, `5 mL` | amount per dose | `intakeText` + form |
| `with meals`, `with food` | — | note text |

Note how cleanly this maps onto schedule kinds we already have — `.everyXHours` and `.everyXDays` exist precisely because prescriptions are written this way.

**`PRN` is a hard stop.** "As needed" is not a schedule and must never become one. We record it as a note and create the medication with **no reminders**, because inventing a reminder cadence for a rescue inhaler or a painkiller would be putting words in a prescriber's mouth. The UI says so plainly.

### 5.4 What we deliberately throw away

**The patient's name and the prescriber's name are discarded at the region level, before any parsing, and never persisted or logged.**

This is not incidental. A dispensing label is the most PII-dense object in this entire flow — name, prescriber, pharmacy, Rx number. We need exactly none of it. Discarding it at the earliest possible point means it never enters our data model, never reaches a crash log, never appears in an export, and never needs a consent dialog.

Same for the barcode **serial number** (`AI 21` / DI `S`): it is a unique per-pack identifier and therefore a tracking vector. We parse it — because we must, in order to parse the fields around it correctly — and then drop it. We keep the batch number only if we later ship recall matching, and that will be its own opt-in decision.

### 5.5 Where the language model helps — and its hard limits

After the lexicon has done its deterministic work, a residue remains: unusual phrasings, tapers ("2 tablets for 3 days, then 1 tablet"), combined instructions, non-English labels. That residue is what `FoundationModels` is for on Tier 2 devices.

Used with **guided generation**, so the output is a typed Swift value rather than prose to re-parse:

```swift
@Generable
struct SigInterpretation {
    @Guide(description: "Doses per day stated on the label. 0 if the label says as-needed.")
    @Guide(.minimum(0), .maximum(12))
    var dosesPerDay: Int

    @Guide(description: "Hours between doses, only if the label says 'every N hours'.")
    var intervalHours: Int?

    @Guide(description: "Amount taken per dose, exactly as printed. 1 for 'one tablet'.")
    var amountPerDose: Double?

    @Guide(description: "Verbatim quote of the sentence this came from. Do not paraphrase.")
    var sourceQuote: String
}
```

**Five constraints that shape how we use it, all verified:**

1. **4,096-token context window** — total, including instructions, the schema, and the output. A full label transcript plus a schema can consume a large fraction of it. This is the strongest argument for feeding the model **only the sig region** identified in §5.1, never the whole page.
2. **Guardrails cannot be relaxed under guided generation.** The `.permissiveContentTransformations` option applies to string generation only. Medical text will sometimes trigger `guardrailViolation` or `refusal` — these are **expected error paths**, not exceptional ones, and must fall back to Tier 1 silently.
3. **Apple explicitly advises against using the model for arithmetic and logical reasoning.** All dose maths, unit conversion and schedule construction happen in Swift. The model proposes structure; it never computes.
4. **One request per session at a time**; check `isResponding`.
5. **The error type was renamed in iOS 27** (`LanguageModelSession.GenerationError` → `LanguageModelError`, with `.exceededContextWindowSize` → `.contextSizeExceeded`). Since we deploy to iOS 17 and progressively enhance, this needs `#available`-gated handling or an iOS 27 floor for that file.

### 5.6 The grounding rule — non-negotiable

> **No number reaches the user that does not appear in the recognised text.**

Every field the model proposes is re-validated in Swift against the OCR output before it is shown:

```swift
func ground(_ proposal: SigInterpretation, in text: String) -> SigInterpretation? {
    guard text.localizedCaseInsensitiveContains(proposal.sourceQuote) else { return nil }
    if let amount = proposal.amountPerDose, !text.containsNumber(amount) { return nil }
    if let hours  = proposal.intervalHours, !text.containsNumber(hours)  { return nil }
    return proposal
}
```

If the model proposes "twice daily" and the label does not contain a phrase supporting it, we discard the proposal and fall back to the lexicon result — or to asking the user. A hallucinated dosing frequency is the single worst failure this feature could produce, and this rule makes it structurally impossible rather than statistically unlikely.

### 5.7 Cross-validation between the two channels

When barcode and OCR both speak, they check each other:

| Barcode | OCR | Behaviour |
|---|---|---|
| 500 mg | 500 mg | Agree → high confidence, field pre-filled and marked verified |
| 500 mg | 50 mg | **Disagree → present both, ask. Never silently pick one.** |
| 500 mg | — | Use barcode, mark `.scanned` |
| — | 500 mg | Use OCR, mark `.read`, require confirmation |

Disagreement is information, not an error. Surfacing it is what a careful pharmacist would do.

---

## 6. User experience

### 6.1 One surface, two engines

The user does not learn about barcodes and OCR. They point the camera at the box. The scanner requests both `.text()` and `.barcode()` in the same `DataScannerViewController` session — this is supported and is a single line — and whichever resolves first begins filling the form.

This also fixes a defect in the current scanner: auto-capture presently triggers on a *strength fragment*, which is why a standalone `"500 MG"` line was the most likely scan. **A barcode is checksummed and unambiguous.** When one is in frame it becomes the auto-capture trigger, and the one-second stability window is unnecessary — we can fire immediately, because a mod-10 check digit is a far stronger signal than any amount of OCR stability.

### 6.2 The review screen, and provenance

**Nothing auto-saves.** The scan produces a review screen — the confirmation step Apple uses everywhere for consequential actions — and every field shows where it came from:

```
Metformin HCl                    ✓ scanned
500 mg                           ✓ scanned
Twice a day · 08:00, 20:00       ⓘ read from the label — please check
60 doses on hand                 ⓘ read from the label — please check
Expires 31 Mar 2027              ✓ scanned
```

Three provenance states, three visual treatments:

- **`✓ scanned`** — from a check-digit-validated barcode, or an exact directory match. Trustworthy.
- **`ⓘ read from the label`** — OCR. Plausible. **Always needs a human glance**, and the field is styled to invite one.
- *(unmarked)* — typed by the user. Never overwritten by a later scan.

Tapping a field marked `ⓘ` highlights the region of the captured image it came from, using `boundingRegion(for:)`. That is the feature that makes this trustworthy rather than magical: **the user can see what the camera saw.**

Green stays reserved for *done* — consistent with the app's existing colour language, where green means a dose is taken. Provenance ticks use the accent colour.

### 6.3 Accessible to everyone, including at 80

- **Scanning is never the only path.** *Enter Manually* stays exactly where it is, at the same prominence. Every scanned field is editable.
- **VoiceOver gets a running commentary.** The current scanner's "locked on" cue is a colour change on a border — invisible to a blind user. An `AXAnnouncement` on state change ("Barcode found. Metformin, 500 milligrams.") makes the whole flow usable without sight, and it is a handful of lines.
- **A torch control.** Pharmacy labels get read in dim kitchens, at night, by people reaching for a bedtime dose. This will improve the real-world hit rate more than any parser change.
- **Hit targets at 44pt**, Dynamic Type throughout, Reduce Motion honoured — the review screen is a form, and it must behave like one at AX5.
- **No time pressure.** Nothing expires, nothing auto-advances, and the captured frame is held so the user can review at their own pace.

---

## 7. Privacy and compliance safeguards

### 7.1 The safeguards themselves

| Safeguard | Implementation |
|---|---|
| **No network in the scan path** | Architectural, not a policy. `ScanPipeline` has no URLSession dependency — it cannot make a request. |
| **Directory refresh is a static file** | No query string, no identifier, no user data. Our CDN, or a direct CC0 mirror. |
| **PII discarded at source** | Patient/prescriber regions dropped before parsing (§5.4). Serial numbers parsed then dropped. |
| **No frame ever persisted** | The captured image lives in memory for the review screen and is released on dismiss. Never written to disk, never in a crash report. |
| **On-device inference only** | `SystemLanguageModel.default` is the on-device model. We never construct a `PrivateCloudComputeLanguageModel`, and we do not request the entitlement. |
| **No iCloud for medication data** | Guideline 5.1.3(ii) prohibits storing personal health information in iCloud. Our `ModelConfiguration` must stay non-CloudKit. Backup remains explicit user-initiated export. |
| **Encryption at rest** | Also potentially takes us outside the FTC Health Breach Notification Rule's trigger, which turns on information *"not secured through technologies specified by HHS."* |
| **Privacy manifest** | `PrivacyInfo.xcprivacy` already exists — verify `NSPrivacyAccessedAPICategoryUserDefaults` (`CA92.1`) and `FileTimestamp` (`C617.1`) are declared. Enforced since May 2024; a gap is `ITMS-91053` and a blocked upload. SwiftData touches both whether we call them directly or not. |
| **App Privacy label** | Apple: on-device-only processing is not "collection". With this design, **nothing to declare.** |
| **No tracking domains** | `NSPrivacyTracking = false`. Do not list our CDN — it would ATT-gate the directory refresh for no reason. |

### 7.2 Lines we do not cross

Two guidelines and one EU regulation draw the same line, and it is worth naming it explicitly because it is a *product* boundary, not a technical one:

- **App Store 1.4.2:** *"Drug dosage calculators must come from the drug manufacturer, a hospital, university, health insurance company, pharmacy or other approved entity, or receive approval by the FDA or one of its international counterparts."*
- **EU MDR Rule 11:** software providing information used for diagnostic or therapeutic decisions can be a **Class IIa medical device** — notified body, technical file, CE marking. A different kind of company.

**Therefore, permanently out of scope:** dose calculation of any kind, "you missed one, take 1.5×" logic, drug interaction checking, renal/weight-based adjustment, and any clinical advice.

We transcribe what a prescriber wrote and remind the user of it. We never compute a dose. That boundary is what keeps this a consumer app.

### 7.3 What we say, and where

- **Guideline 1.4.1 requires** apps to *"remind users to check with a doctor."* The scan review screen is exactly the right place: *"Read from the label — check it matches what your doctor told you."*
- **The FDA disclaimer travels with the data.** openFDA's own `meta.disclaimer` reads: *"Do not rely on openFDA to make decisions regarding medical care… you should assume all results are unvalidated."* Since we ship their dataset, we ship their disclaimer, in About → Data sources, with attribution: *"Drug data provided by the U.S. Food and Drug Administration (open.fda.gov)."* Attribution is requested rather than required, and we should give it.
- **We never claim "HIPAA compliant."** A direct-to-consumer app is not a covered entity or a business associate; the claim would be meaningless, and under **FTC Act §5** a meaningless privacy claim is a deceptive practice. What we say instead is simply true and stronger: *"Your medications never leave your iPhone."*

### 7.4 Where the German position leaves us

Skipping the IFA licence has a real cost and it should be stated honestly, not buried: **a German user scanning a box gets the expiry date and a stable identity, but types the name once.** After that, that box is recognised forever.

Given the alternative is a recurring commercial data licence for a feature that saves one name entry per medication, and that OCR reads the name off the same box anyway, this is the right trade. The architecture leaves the door open — `ProductKey.pzn` is already a case, and a resolver could be added later without touching anything else.

---

## 8. Roadmap

Five phases. **Each one ships on its own and leaves the app better than it found it** — no phase depends on a later phase to be worth having.

### Phase 1 — Barcode identity and expiry *(≈1 week)*
The whole-market win, zero data dependencies.

- `Domain/Barcode/`: GS1 and PPN parsers, check digits, `ScannedPack`, `ProductKey`.
- Add `.barcode(symbologies:)` to the existing `DataScannerViewController` session; barcode becomes the auto-capture trigger.
- Persist `ProductKey` on `Medication`; second-scan auto-fill.
- Expiry surfaced on the medication detail screen and in refill warnings.
- **Tests:** the verified vectors in §3.5, the US and German DataMatrix payloads, `DD = 00` normalisation, both century rules, malformed and truncated payloads, the stripped-`GS` rejection path.
- **Ships:** refill-by-scan and expiry warnings, in every market, offline.

### Phase 2 — US drug directory *(≈1.5 weeks)*
- Build pipeline: FDA bulk JSON → trimmed, normalised, indexed binary resource.
- `DrugDirectory` (read-only, memory-mapped) and `DirectoryUpdater` (background static-file refresh).
- GTIN → NDC candidate generation and directory resolution (§3.4), with `.explicit` / `.inferred` confidence.
- Attribution and FDA disclaimer in About → Data sources.
- **Tests:** the three-candidate segmentation, `AI(715)` precedence, unlisted products, a GTIN that doesn't start with `3`.
- **Ships:** US users scan a box and get name, strength and form — offline, no account, no network.

### Phase 3 — Label OCR, deterministic *(≈2 weeks)*
- `RecognizeDocumentsRequest` on iOS 26+, `VNRecognizeTextRequest` fallback below.
- Region classification for dispensing labels; **PII regions discarded at source**.
- Two-pass recognition (§5.2) with the FDA-derived `customWords` lexicon.
- `SigLexicon` + `SigParser` → `ScheduleProposal`. `PRN` → no reminders, explicitly.
- Cross-validation between barcode and OCR (§5.7).
- **Tests:** a corpus of transcribed real labels (US and German), every lexicon entry, taper and PRN cases, the disagreement path.
- **Ships:** the schedule fills itself — the tedious half of adding a medication.

### Phase 4 — The review screen *(≈1 week)*
- Provenance model and the three-state presentation (§6.2).
- Tap-to-highlight source region via `boundingRegion(for:)`.
- VoiceOver announcements, torch, 44pt targets, Dynamic Type, Reduce Motion.
- "Check it matches what your doctor told you."
- **Ships:** the trust layer. Arguably the most important phase in the plan.

### Phase 5 — Assisted interpretation *(≈1 week, iOS 26 + Apple Intelligence)*
- `FoundationModels` with guided generation for the sig residue only.
- Availability ladder and silent Tier-1 fallback; `guardrailViolation` / `refusal` treated as ordinary paths.
- **The grounding rule (§5.6) implemented and tested with adversarial inputs.**
- **Tests:** grounding rejects fabricated numbers; unavailable model degrades without user-visible failure; context-window overflow handled.
- **Ships:** the last few percent — unusual phrasings and non-English labels.

### Explicitly not on the roadmap
Server-side OCR. Crowdsourced barcode databases. Live API calls from the device. Commercial data licences. Dose calculation. Interaction checking. Any form of clinical advice.

---

## 9. Open items to resolve before Phase 1

1. **Confirm `PrivacyInfo.xcprivacy` is complete** for required-reason APIs — this is already enforced at upload and is independent of this feature.
2. **Verify the openFDA bulk file size** against `https://api.fda.gov/download.json` before committing to a bundle-vs-download strategy (estimated low tens of MB compressed for ~137k records).
3. **Decide the directory hosting**: bundle in the app, or first-run download from our CDN. Bundling makes the first scan work offline out of the box; downloading keeps the binary small. My recommendation: **bundle a compact index, refresh from CDN.**
4. **`RecognizeDocumentsRequest` on iOS 27** may conform to `DownloadableAssetsRequest`, implying a first-run asset download. Check `assetStatus` defensively if we raise the floor.
5. **Confirm no CloudKit** in `ModelConfiguration` — Guideline 5.1.3(ii). I believe we are clean here; worth an explicit check.
6. **Legal review** of the GDPR position. My reading is that a local-only architecture means we are not processing personal data as a controller at all, which is by far the cleanest posture — but German **TDDDG §25** governs storing information on a user's device independently of GDPR and deserves a specific look. *This document is engineering analysis, not legal advice.*

---

## 10. Sources

**Apple frameworks**
- [DataScannerViewController](https://developer.apple.com/documentation/visionkit/datascannerviewcontroller) · [RecognizedDataType.barcode](https://developer.apple.com/documentation/visionkit/datascannerviewcontroller/recognizeddatatype/barcode(symbologies:)) · [VNBarcodeSymbology](https://developer.apple.com/documentation/vision/vnbarcodesymbology)
- [RecognizeDocumentsRequest](https://developer.apple.com/documentation/vision/recognizedocumentsrequest) · [DocumentObservation.Container](https://developer.apple.com/documentation/vision/documentobservation/container) · [WWDC25 — Reading documents with Vision](https://developer.apple.com/videos/play/wwdc2025/272/)
- [RecognizeTextRequest](https://developer.apple.com/documentation/vision/recognizetextrequest) · [customWords](https://developer.apple.com/documentation/vision/recognizetextrequest/customwords) · [RecognizedText](https://developer.apple.com/documentation/vision/recognizedtext)
- [Foundation Models](https://developer.apple.com/documentation/foundationmodels) · [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel) · [Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window) · [Improving safety of generative output](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output) · [WWDC25 — Foundation Models](https://developer.apple.com/videos/play/wwdc2025/286/)

**Barcode standards**
- [GS1 Barcode Syntax Dictionary](https://github.com/gs1/gs1-syntax-dictionary) · [GS1 DataMatrix Guideline](https://ref.gs1.org/guidelines/datamatrix/) · [GS1 General Specifications](https://www.gs1.org/docs/barcodes/GS1_General_Specifications.pdf)
- [GSCN 21-040 — Expiry date for Healthcare](https://www.gs1.org/docs/barcodes/GSCN_21-040_HealthcareExpDate.pdf) · [GSCN 21-289 — AI (715) US NDC](https://www.gs1.org/docs/barcodes/GSCN_21-289_US_FDA_NHRN.pdf)
- [IFA PPN Code Specification](https://www.ifaffm.de/mandanten/1/documents/04_ifa_coding_system/IFA_Spec_PPN_Code_Handelspackung_EN.pdf) · [IFA check digits (PZN/PPN/UDI)](https://www.ifaffm.de/mandanten/1/documents/04_ifa_coding_system/IFA-Info_Pruefziffer_PZN_PPN_UDI_DE.pdf) · [securPharm Coding Rules 2025](https://www.securpharm.de/wp-content/uploads/2025/10/securPharm-Codierregeln-en-GB.pdf)
- [Delegated Regulation (EU) 2016/161 Art. 5](https://www.legislation.gov.uk/eur/2016/161/article/5/adopted) · [Windsor Framework medicines guide](https://assets.publishing.service.gov.uk/media/677fc96e6f01ae28ab5c0562/Windsor_Framework_Pharmacists___Medicines_Procurers_Guide__Jan_2025_.pdf)

**US drug data**
- [FDA — National Drug Code Format](https://www.fda.gov/drugs/electronic-drug-registration-and-listing-system-edrls/national-drug-code-format) · [openFDA NDC dataset](https://open.fda.gov/data/ndc/) · [openFDA licence (CC0)](https://open.fda.gov/license/) · [openFDA terms](https://open.fda.gov/terms/) · [Bulk downloads](https://open.fda.gov/apis/downloads/)
- [FDA — Product Identifiers Under the DSCSA](https://www.fda.gov/media/116304/download) · [HDA Bar Coding Guidelines](https://www.amerisourcebergen.com/-/media/assets/amerisourcebergen/manufacturer/hda-bar-code-guidelines-2022.pdf)
- [Federal Register — Revising the NDC Format (final rule, 5 Mar 2026)](https://www.federalregister.gov/documents/2026/03/05/2026-04368/revising-the-national-drug-code-format-and-drug-label-barcode-requirements)

**Privacy and review**
- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) · [App privacy details](https://developer.apple.com/app-store/app-privacy-details/) · [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files) · [Required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [GDPR Art. 9](https://gdpr-info.eu/art-9-gdpr/) · [Recital 35 — health data](https://gdpr-info.eu/recitals/no-35/) · [EDPB Guidelines 05/2021 on transfers](https://www.edpb.europa.eu/system/files/documents/2023-02/edpb_guidelines_05-2021_interplay_between_the_application_of_art3-chapter_v_of_the_gdpr_v2_en_0.pdf)
- [FTC — Health Breach Notification Rule](https://www.ftc.gov/business-guidance/blog/2024/04/updated-ftc-health-breach-notification-rule-puts-new-provisions-place-protect-users-health-apps) · [HHS — HIPAA and the FTC Act](https://www.hhs.gov/hipaa/for-professionals/special-topics/hipaa-ftc-act/index.html)
