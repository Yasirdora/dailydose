# Implementation brief — Daily Dose, barcode scanning (Phase 1)

You are picking up work on **Daily Dose**, a native SwiftUI/SwiftData iOS medication-reminder app. This brief is self-contained: every fact and test vector you need is below, already researched and verified. You should not need to search the web.

**Repository:** `~/Documents/kimi/workspace/DailyDose`
**Deployment target:** iOS 17.0 · Swift 5 language mode · Xcode 16 synchronized folder groups
**Your deliverable:** Phase 1 of `SCANNING-DESIGN.md` — barcode identity and expiry. Nothing else.

Work to a professional standard: clean, well-structured, maintainable code. No patchwork, no speculative abstraction, no scope creep. When Phase 1 is complete and verified, stop and report. Do not begin Phase 2.

---

## 1. Read these first, in this order

1. **`SCANNING-DESIGN.md`** in the repo root — sections 1–4 and 8 (Phase 1). This is the agreed architecture. Do not redesign it. If you believe something in it is wrong, say so in your report rather than silently deviating.
2. **`DailyDose/Domain/DoseSchedule.swift`** — the exemplar for how a domain type is written here.
3. **`DailyDose/Domain/MedicationForm.swift`** and **`StrengthUnit.swift`** — small, recent, and the closest structural analogues to what you are building.
4. **`DailyDose/Features/Scanner/LabelScanParser.swift`** — an existing pure parser; match its shape.
5. **`DailyDose/Models/SchemaMigration.swift`** — read this carefully before touching the model. See §5.
6. **`DailyDoseTests/MedicationFormTests.swift`** and **`DoseScheduleTests.swift`** — the testing voice.

---

## 2. House style — this matters as much as correctness

This codebase has a distinctive and deliberate style. Match it.

**The domain layer is pure.** Files in `DailyDose/Domain/` import `Foundation` and nothing else. No SwiftUI, no SwiftData, no Vision, no UIKit. This is what makes the logic exhaustively testable without a device. Your parsers belong here and must honour it.

**Doc comments explain *why*, not *what*.** The convention is to name the bug a decision prevents, or the alternative that was rejected and the reason. Compare:

```swift
// Wrong — restates the code
/// Parses the GS1 element string.

// Right — the house voice
/// Parses a GS1 element string into its Application Identifiers.
///
/// Variable-length fields run to the next `GS` (0x1D) or to end-of-data. When a
/// scanner strips that byte — routine in HID keyboard-wedge mode — the boundary
/// between a batch number and whatever follows it is formally unrecoverable. We
/// reject the scan rather than guess: a wrong lot number on a medicine is a
/// safety event, and asking someone to scan again costs two seconds.
```

Be economical. One paragraph of real reasoning beats five lines of narration. Not every function needs a doc comment — the ones carrying a non-obvious decision do.

**Make illegal states unrepresentable.** `TimeOfDay` is a type rather than a `"HH:mm"` string, and dose times are a `Set` so two doses can never share a minute. Follow that instinct: a check digit that has not been validated should not be expressible as a validated code.

**Failure is a value, not a crash.** No force-unwraps outside tests. Parsers return optionals or throw; they never trap on malformed input, because malformed input is the normal case when a camera is involved.

**Tests are named as sentences describing behaviour**, using Swift Testing (`@Suite`, `@Test`, `#expect`, `#require`):

```swift
@Test("A stripped group separator is rejected rather than guessed")
func strippedSeparatorIsRejected() { … }
```

Assertions must be able to fail for the right reason. Do not derive a test's expected value from the same constant the implementation uses — assert against literals and known-good vectors.

---

## 3. What to build

Create `DailyDose/Domain/Barcode/` containing:

| File | Responsibility |
|---|---|
| `BarcodePayload.swift` | Raw bytes + symbology + optional AIM symbology identifier, as handed over by the scanner |
| `CheckDigit.swift` | GTIN mod-10, PZN mod-11, PPN mod-97 |
| `GS1Parser.swift` | GS1 Application Identifier element stream → elements |
| `PPNParser.swift` | ISO/IEC 15434 Format 06 (IFA) → elements |
| `NationalDrugCode.swift` | Segmented, format-versioned NDC |
| `ProductKey.swift` | Market-agnostic identity: `.ndc` / `.pzn` / `.gtin` |
| `ScannedPack.swift` | The canonical parse result |
| `BarcodeInterpreter.swift` | Dispatch + normalisation. The one public entry point. |

Then integrate (§5, §6) and test (§7).

### 3.1 The canonical result

```swift
/// Everything a medicine pack's barcode can tell us without a database.
struct ScannedPack: Equatable, Sendable {
    let key: ProductKey
    let gtin: String?          // 14 digits, zero-padded, check-digit verified
    let pzn: String?           // 8 digits, check-digit verified
    let ndc: NationalDrugCode? // US only; Phase 1 leaves this unresolved
    let batch: String?
    let expiry: ExpiryDate?
    let syntax: Syntax         // .gs1 | .ifaPPN | .linear
}
```

**Do not carry the serial number (`AI 21` / DI `S`) beyond parsing.** It must be parsed — the fields around it cannot be located otherwise — and then discarded. It is a unique per-pack identifier and therefore a tracking vector we have no use for. Put that reasoning in a comment so nobody helpfully "restores" it later.

---

## 4. The specification

This is verified. Implement it exactly.

### 4.1 Dispatch

```
1. Payload starts with [0x5B,0x29,0x3E,0x1E,0x30,0x36,0x1D]  → "[)>" RS "06" GS → PPN parser
2. Symbology identifier is "]d2", or first byte is 0x1D       → GS1 parser
3. Payload starts with "9N"                                    → PPN body parser (envelope stripped)
4. Payload matches ^01\d{14}                                   → GS1 parser
5. All digits, length 8/12/13/14, valid mod-10                 → plain linear: GTIN only
6. Otherwise                                                   → nil
```

Order matters at steps 3–4: `01` is also a legal start to a PPN *value*, so test `9N` first.

### 4.2 GS1 element parsing

Fixed-length AIs are read by byte count and are **never** followed by a separator. Variable-length AIs run to the next `GS` (0x1D) or to end-of-data.

| AI | Length | Content |
|---|---|---|
| `01` | fixed 14 | GTIN, mod-10 checked |
| `17` | fixed 6 | Expiry `YYMMDD` |
| `10` | variable, ≤20 | Batch / lot |
| `21` | variable, ≤20 | Serial — parse, then discard |
| `710` | variable, ≤20 | NHRN: PZN (Germany) |
| `715` | variable, ≤20 | NHRN: NDC (US), explicit — **prefer over GTIN inference** |

Rules:
- `10` and `21` are GS1 CSET-82: case-sensitive alphanumeric. **Never upper-case, trim, or coerce them.**
- A `GS` immediately after a fixed-length field is non-conformant but very common. Tolerate and skip.
- A trailing `GS` after the final field is legal and redundant. Emit no empty field.
- **Reject unknown AIs rather than guessing their length.** A wrong length guess silently corrupts every field after it.
- If a variable-length field is followed by more data and no `GS` appears, the boundary is unrecoverable: **return nil.** Do not heuristically split.

### 4.3 PPN / ISO/IEC 15434 Format 06

```
[)>{RS}06{GS}9N111234567842{GS}1T1A234B5{GS}D151231{GS}S1234567890123456{RS}{EOT}
```
- Header required; trailer (`RS EOT`) optional in the wild.
- Fields `GS`-delimited, **order is arbitrary** — index by Data Identifier, never by position.
- Data Identifiers: `9N` product (PPN, 11–28 chars, `[0-9A-Z]`), `1T` batch, `D` expiry (exactly 6 numeric), `S` serial.
- Match DIs **longest-first** (`9N` before `N`, `1T` before `T`).

**PZN extraction — two routes:**
```swift
// A. PPN syntax: PPN = PRA code "11" + 8-digit PZN + 2-digit check.
if ppn.hasPrefix("11"), ppn.count >= 10 { pzn = String(ppn.dropFirst(2).prefix(8)) }

// B. NTIN syntax: GTIN-13 = "4150" + 8-digit PZN + mod-10 check → GTIN-14 "04150…"
if gtin14.hasPrefix("04150") { pzn = String(gtin14.dropFirst(5).prefix(8)) }
```
Gate route A on the `"11"` prefix — other Product Registration Agency codes exist and are not PZNs.

### 4.4 Check digits — with verified vectors

**GTIN (8/12/13/14):** mod-10, weights 3 and 1 alternating **from the right** (rightmost data digit gets 3), then `(10 - sum % 10) % 10`. The final `% 10` is required — when `sum % 10 == 0` the check digit is 0, not 10.
Vector: `00312345678906` → check digit **6** ✔

**PZN-8:** mod-11, weights 1…7 applied left-to-right to the first 7 digits; the remainder **is** the 8th digit. **A remainder of 10 means the input is not a valid PZN** — such numbers are never issued, and there is no substitution character.
Vectors: `2758089` → **9** ✔ · `1234567` → **8** ✔

**PPN:** mod-97 over the **ASCII values** of every character of the body (PRA code + article number), weights starting at 2 and incrementing, zero-padded to two digits.
Vectors: `1103752864` → **14** ✔ · `1112345678` → **42** ✔

> The PPN algorithm operating on ASCII values rather than digit values is the classic implementation bug. Both vectors above must be in your tests.

### 4.5 Expiry dates

`YYMMDD`. `DD == "00"` means the last day of that month.

Two market-specific rules that a single code path gets wrong:

- **Accept `DD = 00` from both syntaxes.** GS1 has prohibited it for healthcare since 1 January 2025, but German PPN syntax still permits it and legacy stock is in circulation. Normalise to the month's last day; flag non-conformance only for GS1.
- **Century differs by syntax.** IFA states PPN dates are always 21st century: `year = 2000 + YY`. GS1 specifies a ±50-year sliding window — but that window resolves `YY = 25` to **1925** in 2026, which is absurd on screen for a pack that expired last year. **For medicine expiry, override to a forward-biased window** of `[today − 2 years, today + 97 years]`.

Validate the result is a real calendar date. Reject month 13, day 31 of February, and so on.

### 4.6 NDC — Phase 1 scope

Model the type now; **do not attempt resolution** (that is Phase 2, and it requires the local FDA directory).

```swift
struct NationalDrugCode: Hashable, Sendable {
    enum Format: String, Sendable { case f442, f532, f541, f642 }
    enum Confidence: Sendable { case explicit, inferred }
    let labeler: String, product: String, package: String
    let format: Format
    let confidence: Confidence
}
```

Why segmented and format-versioned rather than an 11-character string: FDA's final rule of 5 March 2026 moves the NDC to a uniform 12-digit **6-4-2** format effective 7 March 2033, and a 12-digit NDC does not fit in a GTIN-12 — so the GTIN↔NDC embedding relationship ends. Cheap to model correctly now, expensive to retrofit.

In Phase 1: if `AI(715)` is present, construct the NDC from it with `.explicit` confidence. Otherwise leave `ndc` as `nil` — do **not** guess a segmentation. The three candidates (4-4-2, 5-3-2, 5-4-1) are genuinely ambiguous from the digits alone and require a directory lookup to disambiguate.

---

## 5. Persistence — read this before touching the model

**The schema is currently at V6.** `SchemaMigration.swift` holds `DailyDoseSchemaV1` through `V6`, with a custom V1→V2 stage and lightweight stages thereafter.

Adding a persisted `productKey` to `Medication` therefore requires **a new `DailyDoseSchemaV7`** and a **lightweight** `migrateV6toV7` stage. Follow the existing pattern exactly:

- Store it raw and defaulted: `var productKeyRaw: String = ""`. A defaulted property is what makes the stage lightweight — CoreData fills the column and no row is read or rewritten.
- Expose a computed `productKey: ProductKey?` projection, tolerant of unknown values: an unparseable raw string must read as `nil`, never crash. `MedicationForm` in this repo is the model to copy.
- Add the new version to `schemas` and the new stage to `stages`.
- **Add a migration test.** `MigrationTests.swift` writes a real store at an older version to a real file URL and reopens it through the actual `ModelContainer(migrationPlan:)`. Extend that pattern: a V6 store must open as V7 with existing data intact and the new field at its default.

Getting this wrong is data loss on app update for every existing user. Treat it as the highest-risk part of the task.

---

## 6. Integration

Keep this minimal and surgical. Phase 1 earns its place through three user-visible behaviours:

1. **Barcodes are recognised.** Add `.barcode(symbologies:)` alongside the existing `.text()` in the `DataScannerViewController` session in `LabelScanner.swift`. Both recognised data types are supported simultaneously — this is a set. Symbologies: `.dataMatrix`, `.ean13`, `.ean8`, `.upce`, `.code39`, `.code128`, `.gs1DataBar`, `.gs1DataBarExpanded`, `.gs1DataBarLimited`. Note the symbology itself is reached via `barcode.observation.symbology` (a `VNBarcodeObservation`), not a property on `RecognizedItem.Barcode`.

2. **A barcode is the better auto-capture trigger.** `ScanTabView` currently waits for a *strength fragment* to hold steady for one second. A barcode carries a check digit, so it is unambiguous — when one parses successfully, capture immediately. No stability window needed.

3. **A known pack auto-fills.** Persist the `ProductKey` on save. On a later scan, look for an existing medication with the same key; if found, offer to top up supply rather than create a duplicate. If not found, the user names it once and every subsequent scan of that pack is instant.

Also surface the expiry date on the medication detail screen when present. Keep the presentation consistent with the existing `StatusChip` / `EditorChip` vocabulary — do not invent a new component.

**Do not** modify unrelated files. **Do not** refactor code you happen to be reading.

---

## 7. Tests

Add `DailyDoseTests/BarcodeParsingTests.swift`. Required coverage:

- All check-digit vectors in §4.4, including the **PZN remainder-10 rejection**.
- A full US GS1 DataMatrix payload: `(01)00312345678906(21)12345678(10)ABC123(17)180630` → GTIN, batch `ABC123`, expiry 2018-06-30, serial parsed and **absent from the result**.
- The German PPN payload in §4.3 → PPN `111234567842`, PZN `12345678`, batch `1A234B5`, expiry 2015-12-31.
- NTIN route: GTIN-14 `04150123456782` → PZN `12345678`.
- `DD = 00` → last day of month, both syntaxes.
- Century: PPN `D` always 2000+YY; GS1 forward-biased window.
- Malformed input: truncated fixed-length field, over-long variable field, unknown AI, empty variable field, a payload of pure noise. **Each must return nil, not crash.**
- The stripped-`GS` case must be **rejected**, not guessed.
- Batch and serial preserve case exactly.
- The V6→V7 migration test (§5).

Every parser test must be pure — no camera, no container, no `Date.now`. Pin dates explicitly; `Fixture` in `TestSupport.swift` pins `Europe/Berlin` and a Monday first-weekday for exactly this reason.

---

## 8. Constraints

- **No network. At all.** Phase 1 has no lookup. `Domain/Barcode/` must not import anything that could make a request.
- **No third-party dependencies.** Vision and VisionKit are sufficient. Do not add a barcode library.
- **Nothing about the user leaves the device**, and nothing is written to disk beyond the medication they explicitly save.
- **The user edits this repository while you work.** Re-read a file immediately before you write it, and make surgical anchored edits rather than rewriting whole files. There is uncommitted work in the tree — inspect `git status` before you start and do not discard it.
- **Do not commit to git** unless asked.

---

## 9. Definition of done

- [ ] The project **builds** for an iOS 17 deployment target with no new warnings.
- [ ] The **full test suite passes**, not only your new tests.
- [ ] The V6→V7 migration is tested against a real on-disk V6 store.
- [ ] No force-unwraps outside test fixtures; no `fatalError` on any input path.
- [ ] Every new public type carries a doc comment explaining a decision, in the house voice.
- [ ] Scanning a real pharmacy box on a device fills the name (via existing OCR) and the expiry (via the new barcode path), and a second scan of the same box matches the existing medication.

Then **stop** and report:

1. What you built, and any point where you deviated from `SCANNING-DESIGN.md` and why.
2. Anything in this brief that turned out to be wrong when you implemented it.
3. What you could not verify (for example, real-device scanning if you had no device).
4. The specific risks you would want a reviewer to look at hardest.

Be honest about what is untested or uncertain. An accurate report of partial completion is far more useful than a confident claim that everything works.
