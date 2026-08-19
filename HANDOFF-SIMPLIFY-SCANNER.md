# Implementation brief — Daily Dose: one capture path

You are continuing work on **Daily Dose**, a native SwiftUI/SwiftData iOS medication-reminder app.

**Repository:** `~/Documents/kimi/workspace/DailyDose`
**Deployment target:** iOS 17.0 · Swift 5 language mode · Xcode 16 synchronized folder groups

This is a **deliberate simplification**, decided after device testing. It removes more code than it adds. Work to a professional standard: surgical changes, no patchwork, no scope creep. When it is done and verified, **stop and report**.

---

## 0. The decision, and why

Device testing produced a bug that only exists because two capture paths run at once: the OCR read a DataMatrix's own **printed human-readable text** — `(01) 05437654786045 (17) 210212 (10)…` — and `LabelScanParser` accepted it as a medication *name*.

Rather than patch the interaction, we are collapsing to **one capture path: OCR**.

The reasoning:

- The barcode's data is *also printed on the pack*. Under the EU FMD, prescription packs must carry the product code, batch, expiry and serial in human-readable form (unless the pack is very small); US DSCSA packs carry the same. So OCR can read what the barcode carries.
- The printed form is **easier to parse than the raw payload** — the `(nn)` parentheses mark every field boundary explicitly, so the stripped-`GS` ambiguity that has cost us days simply does not arise.
- The barcode can never supply the **dosing directions**, which are the tedious half of adding a medication. Only the label can.
- The bundled FDA directory is 7.9 MB, US-only, and this app has no US users yet.

**What is being removed:** the VisionKit barcode plumbing, and the FDA drug directory.
**What is being kept:** the pure domain parsers. They are repointed at OCR text, not deleted.

Read §5 carefully — there is a specific instruction *not* to migrate the schema.

---

## 1. Read first

1. `SCANNING-DESIGN.md` §1 and §4 — background. **It is now partly superseded by this brief; where they disagree, this brief wins.**
2. `DailyDose/Features/Scanner/LabelScanParser.swift` — the parser you are extending.
3. `DailyDose/Domain/Barcode/GS1Parser.swift` and `PPNParser.swift` — the parsers you are repointing.
4. `DailyDose/Features/Scanner/LabelScanner.swift` and `ScanTabView.swift` — what you are simplifying.
5. `DailyDose/Domain/DoseSchedule.swift` — the house style exemplar.

## 2. House style

- **The domain layer is pure.** Files in `DailyDose/Domain/` import `Foundation` and nothing else. No Vision, no SwiftUI, no SwiftData.
- **Doc comments explain *why*** — name the bug a decision prevents, or the alternative rejected and the reason. One paragraph of real reasoning beats five lines of narration.
- **Make illegal states unrepresentable.** A code that has not passed its check digit should not be expressible as a validated one.
- **Failure is a value, not a crash.** No force-unwraps outside tests; no `fatalError` on any input path. Malformed input is the normal case when a camera is involved.
- **Tests are sentences describing behaviour**, using Swift Testing (`@Suite`, `@Test`, `#expect`). Assert against literals and known-good vectors, never against the same constant the implementation uses.

---

## 3. Task 1 — Human-readable barcode text

### 3a. It is never a name

A string that is a barcode transcription must not become a medication name. In `LabelScanParser`, reject text that matches `^\s*\(\d{2,4}\)` or contains two or more `(nn)` groups.

The current boilerplate filter missed this because the truncated tail contains a `(21)` serial with letters in it, which read as a word. Fix the rule, and add the observed string as a test vector.

### 3b. Parse it instead

This is the valuable half. `(01)05437654786045(17)210212(10)ABC123` is a complete GS1 element string in HRI form. Strip the parentheses and feed the fields to the existing `GS1Parser` element handling.

Because the parentheses delimit every field explicitly, **you do not need the `GS` separator logic at all** for this path — field boundaries are given. Do not reuse the raw-payload byte scanner where the explicit form is simpler and safer; share the *AI table and validation*, not the byte-level tokeniser.

Verified facts you need (do not re-research):

| AI | Length | Content |
|---|---|---|
| `01` | 14 | GTIN, mod-10 checked |
| `17` | 6 | Expiry `YYMMDD` |
| `10` | ≤20 | Batch / lot — case-sensitive, do not normalise |
| `21` | ≤20 | Serial — **parse then discard** (per-pack tracking vector, no use for it) |
| `710` | ≤20 | NHRN: PZN (Germany) |
| `715` | ≤20 | NHRN: NDC (US), explicit |

Expiry rules are already implemented in `ExpiryDate` — reuse it, do not reimplement. `DD == "00"` means last day of month; the century window is GS1's own sliding rule.

Worked vector from the device, for your tests: GTIN `05437654786045` (check digit 5 ✓), expiry `210212` → 12 February 2021.

### 3c. German labelled form — scope note

German packs also print the same data in a labelled form (`PZN: …`, `Ch.-B.: …`, `Verw. bis: …`). **We have not observed one, so do not implement it speculatively.** Structure `HRIParser` so a second format can be added later, and leave a single failing-free placeholder test documenting the gap. Say so in your report.

---

## 4. Task 2 — Retire the VisionKit barcode path

- Remove `.barcode(symbologies:)` from `recognizedDataTypes` in `LabelScanner.swift`; the session becomes `.text()` only.
- Remove the barcode branch from `RecognizedTextStore.update(with:)`, the `payloadBytes` accessor, the symbology mapping, and `ScannedPack` plumbing that only the scanner fed.
- Remove the barcode auto-capture branch in `ScanTabView` and the shutter's barcode preference. One path in, one stability rule.
- Delete `ScanProbe.swift` and its call sites. It has done its job.
- **Keep** `DailyDose/Domain/Barcode/`: `GS1Parser`, `PPNParser`, `CheckDigit`, `ExpiryDate`, `ProductKey`, `NationalDrugCode`, `ScannedPack`. These now serve the HRI path. `BarcodePayload` and `BarcodeInterpreter`'s dispatch may shrink to what the HRI path needs — keep what is used, delete what is not, and do not leave dead entry points behind.
- Keep the existing barcode parser tests that still exercise reachable code. Delete tests for code you delete; do not keep a green test over a deleted path.

The result should be: **no `import VisionKit` barcode surface, and no loss of GTIN, PZN, batch or expiry when the pack prints its HRI.**

---

## 5. Task 3 — Remove the FDA drug directory

Delete: `DrugDirectory.swift`, `NDCResolver.swift`, the bundled `ndc-index.ddndc` resource, `Tools/build-ndc-index.py`, `Tools/NDC-INDEX-FORMAT.md`, the About → Data sources entry, and the `product:` / `DrugDirectory.Entry` parameters threaded through `ScanCapture`, `MedicationDraft` and `MedicationEditor`.

**Keep `NationalDrugCode`** — `AI(715)` still populates it explicitly, and the type models the 2033 format change correctly.

### Do NOT add a schema version

`productKeyRaw` and `expiryDate` on `Medication` **stay exactly as they are**. They are still written — now from OCR rather than from the scanner. Removing the directory changes nothing about the persisted shape.

Adding a `DailyDoseSchemaV8` here would be pure risk for zero benefit: a migration that touches every existing user's store to remove nothing. **Leave the schema at V7.** If you believe otherwise, say so in your report rather than acting on it.

Record the deletion in your report with the commit SHA that last contained the directory, so it can be restored when a US launch justifies it. Git history is the archive; do not keep a dead copy in the tree.

**Measure and report the app's install size before and after.** That is the concrete result of this task.

---

## 6. Task 4 — Ship blockers

These matter more than anything above.

1. **Prove background refresh actually fires.** The Info.plist keys are now correct in the built product, but that only proves registration is possible. Force a run and confirm the handler executes:
   ```
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.dailydose.ios.refresh"]
   ```
   This is the app's core promise and it has never been observed working.

2. **Settle the Add Medication hang.** It was reported on a build that predated a compile fix, so it may already be gone. Re-test on current `HEAD` first. If it reproduces, the discriminating question is whether it also happens via **Enter Manually** — that separates editor-side (likely a SwiftUI re-render loop in the recent picker-sheet work; confirm by pausing in Xcode and looking for `AG::Graph` frames) from camera-side. Report what you find; only fix what you can reproduce.

3. **The camera keeps running behind a presented sheet.** A sheet over `ScanTabView` does not fire `viewDidDisappear` on the container. Do **not** apply the naive fix of tearing down the scanner while a sheet is up — on dismissal the camera restarts, the same label is still in frame, and the editor reopens in a loop the user cannot escape. If you address it, it needs a "we already captured this" guard keyed on the last capture. Report it either way.

---

## 7. Out of scope

Do **not** start the smart-OCR work: no `RecognizeDocumentsRequest`, no `FoundationModels`, no sig lexicon, no dispensing-label field extraction. That work is real and valuable, but it needs a corpus of real label photographs we do not yet have, and the app has not shipped to anyone.

Do not refactor code you happen to read. Do not add dependencies. Do not commit to git unless asked.

The user edits this repository while you work: re-read a file immediately before writing it, and make surgical anchored edits rather than rewriting whole files.

---

## 8. Definition of done

- [ ] Builds for iOS 17.0 with no new warnings.
- [ ] Full test suite passes — not only your new tests.
- [ ] Scanning a pack whose HRI is printed yields GTIN, expiry and batch, and **never** puts barcode text in the name field.
- [ ] Scanning a pack with a readable product name still fills the name, as before. No OCR regression.
- [ ] No `DrugDirectory`, no bundled index, no probe; no dead entry points left behind.
- [ ] Schema still at V7, with no new migration.
- [ ] Install size measured before and after.
- [ ] Background refresh observed firing on device.

Then **stop** and report:

1. What you removed, what you kept, and why — especially anything you kept that this brief said to delete.
2. Install size before and after.
3. Whether the hang reproduced, and what the evidence showed.
4. What you could not verify without a device or a real pack.
5. The risks you would want a reviewer to look at hardest.

Be accurate about partial completion. An honest account of what is untested is worth far more than a confident claim that everything works — that assumption is what cost this project two days of barcode debugging.
