# Implementation brief — dispensing labels, and three bugs from device testing

**Repository:** `~/Documents/kimi/workspace/DailyDose`

Cartons now work well — roughly 90% success on real packs. **Pharmacy dispensing labels do not**, and a real US label produced three distinct faults. Fix those first; they are ranked, and #1 is a privacy defect.

Test case, transcribed from the label that failed (use it as a fixture):

```
AMBER SPECIALTY PHARMACY
10004 S. 152nd St Omaha, NE 68138
For refills call: (888) 370-1724
Rx # 0010140712        Filled: 02/07/2018
                       Use By: 2/7/2019
Jane Doe
Tacrolimus 1mg Cap (ACC)
Mfg: ACCORD HEALTHCARE
Generic for: Prograf
Take 1 capsule by mouth in the morning and
2 capsules in the evening
Qty:90    Physician: Test Doctor
Orig Rx:02/07/2018   Refills: 7   Before 12/03/2018
CAUTION: Federal Law PROHIBITS the transfer of this drug to
any person other than the patient for whom it was prescribed.
Pharmacist Kelli Wyant
```

Produced: name `Rx# 0010140712 Jane Doe Tacrolimus`, strength `1 mg` ✓, form `Capsule` ✓, doses on hand `152` ✗.

---

## 1. The patient's name must never be captured — highest priority

`Jane Doe` reached the name field and would have been saved to disk. `SCANNING-DESIGN.md` §5.4 requires that patient and prescriber names are discarded **at the region level, before any parsing**, and never persisted, logged, or exported. That rule was never implemented.

Implement it now:

- Drop any fragment that follows a prescriber/pharmacist marker (`Physician:`, `Prescriber:`, `Dr.`, `Pharmacist`, `Arzt`, `Verordnet von`).
- Drop any fragment carrying a dispensing identifier (`Rx #`, `Rx#`, `Orig Rx`, `Refills:`, `Filled:`, `Use By:`, `NDC`, `DIN`).
- On a label recognised as a dispensing label (§3), the **patient name line** is conventionally the line immediately before the drug line and contains no digits, no dosage form word and no unit. Exclude it from name candidacy.
- These fragments must be excluded before ranking, not filtered out of the winner afterwards — they must never enter a candidate list at all.

Add a test asserting that no output field of the fixture above contains `Jane Doe`, `Kelli Wyant`, `Test Doctor` or `0010140712`.

**Prefer refusing a name to capturing the wrong one.** An empty field the user fills is already the established behaviour and the correct outcome here.

---

## 2. `St` matched a street address

`152` came from `10004 S. 152nd St Omaha` — the German `St`/`St.` (*Stück*) entry matched "152nd St".

Two changes:

**Language-gate the lexicon.** This is the general fix, and `St` is only the first instance — Polish `po`, Portuguese `sobre`, and other short entries carry the same hazard. Determine the dominant language of the captured text (a simple score over the recognised words against each language's entries is sufficient; `NLLanguageRecognizer` is also available and is Foundation-adjacent — if you use it, keep it out of the pure domain layer behind a protocol). Then apply that language's entries plus a small universal core (`mg`, `ml`, digits).

**Mark short and ambiguous entries as requiring that gate.** Add a field to the table — entries of ≤3 characters, or ones that collide with common non-pharmaceutical words, only match when their language is the dominant one. `St`, `Stk`, `po`, `ct`, `caps` at minimum.

Add a test: the fixture above yields **no** quantity from `152nd St`.

---

## 3. Dispensing labels are a different document type

A carton and a dispensing label do not share a layout, and the current extraction is carton-tuned. Detect which you are looking at, and branch.

**Recognising a dispensing label** — two or more of: `Rx #`, `Qty`, `Refills`, `Filled`, a phone number, `Pharmacy`, `Apotheke`, `Physician`, `Take … by mouth`.

**On a dispensing label:**

- **Quantity comes from `Qty`**, which is *noun-then-number*, optionally with a colon and no space: `Qty:90`, `Qty: 90`, `Quantity 90`, `Menge: 30`, `Anzahl 30`. Add this as a distinct pattern; the existing number-then-noun rule cannot see it. When a `Qty` marker is present it **outranks every other quantity candidate on the label** — it is the authoritative figure.
- **The drug line is regular** and is the name source: `<Name> <strength><unit> <Form>` — "Tacrolimus 1mg Cap". It is bracketed by `Mfg:` and `Generic for:` on US labels, which are useful anchors. Take the name from that line only, and stop at the strength.
- **Do not use largest-text ranking here.** The patient's name is often the largest text on a dispensing label. That heuristic is correct for cartons and wrong here.

---

## 4. The line-break assumption needs verifying before anything is built on it

`Rx # 0010140712`, `Jane Doe` and `Tacrolimus 1mg Cap (ACC)` are three separately printed lines, and they arrived as one fragment: `Rx# 0010140712 Jane Doe Tacrolimus`.

That is direct evidence that DataScanner merges visually separate lines — which is the condition under which the "a quantity must share a line with its noun" rule silently stops working, and the `Ibuprofen AL 400` bug returns with no signal.

**Verify before building further.** Add a temporary `#if DEBUG` log of every `RecognizedItem.Text.transcript` with newlines escaped as `\n`, point it at a real label and a real carton, and report exactly what arrives. If lines are merged with spaces, the line rule must be replaced with a geometric one — fragments whose `bounds` share a vertical band are one line — or abandoned in favour of something that does not depend on transcript formatting.

Do not skip this. Everything the German carton path does rests on it.

---

## 5. Capture supply independently of the tracking toggle

Reported: the count only appears if tracking was already on; scanning first and toggling afterwards shows `0`.

The model currently couples two different things. Separate them:

- **`pillsRemaining` is an observation** — what the pack says. Capture and persist it whenever it is read, regardless of `tracksSupply`.
- **`tracksSupply` is a preference** — whether the user wants refill warnings.

So: `apply` sets `pillsRemaining` unconditionally; `resolvedPills` must stop returning `nil` merely because tracking is off; and turning tracking on later must reveal the number that was already captured rather than starting at zero. Keep `isMissingSupplyCount` — it should now only fire when tracking is on and **nothing** was ever captured or typed.

Setting `tracksSupply = true` automatically on a successful scan is still fine and desirable; the point is that the number must not be lost when it is off.

---

## 6. Constraints

- Domain layer stays pure — `Foundation` only. Language detection, if it uses `NaturalLanguage`, goes behind a protocol at the boundary.
- No new dependencies. No schema change.
- Surgical anchored edits; re-read files immediately before writing them.
- Do not commit. Do not start directions/sig parsing — "Take 1 capsule in the morning and 2 in the evening" is out of scope, though §3's detection may make it the obvious next step.

## 7. Done when

- [ ] Builds for iOS 17, no new warnings; full suite passes.
- [ ] The fixture in this brief yields: name `Tacrolimus`, strength `1 mg`, form capsule, quantity **90**, and **no** patient, prescriber, pharmacist or Rx number in any field.
- [ ] `152nd St` yields no quantity.
- [ ] Scanning with tracking off still captures the count; toggling on afterwards shows it.
- [ ] Carton extraction is not regressed — the existing tests still pass unchanged.

Then **stop** and report: what the transcript log actually showed about line merging, whether the line rule survived, which lexicon entries you language-gated, and what you could not verify without more real labels.
