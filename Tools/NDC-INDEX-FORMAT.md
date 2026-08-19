# `DDNDCIDX` — the bundled FDA drug directory

The on-device form of the FDA National Drug Code Directory. Built by
[`build-ndc-index.py`](build-ndc-index.py), read by `Services/DrugDirectory.swift`,
and shipped as an app resource — **the app never fetches it, and never sends
anything to ask what a code means.**

## Why a binary file and not JSON

The source dataset is 234 MB of JSON for 137,198 products. Even trimmed to the
four fields the editor needs it is megabytes of text that would have to be
parsed into memory before the first lookup could happen. This format is
`mmap`-ed instead: opening it costs one syscall and no allocation, and a lookup
touches two or three pages.

## Why the builder is dumb

It trims, deduplicates and sorts. It does **no interpretation** — it does not
decide that `"TABLET, FILM COATED"` is a pill or that `"10 mg/1"` is 10 mg.
Those strings are carried through verbatim and read by the same Swift code that
reads a scanned label, so there is exactly one place where an FDA dosage form
becomes a `MedicationForm`, and it is the one covered by tests. A build script
that quietly disagreed with the app would be very hard to notice.

## Layout

Little-endian throughout. All offsets are absolute, from the start of the file.

### Header — 64 bytes

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | magic, ASCII `DDNDCIDX` |
| 8 | 4 | `formatVersion` u32, currently 1 |
| 12 | 4 | `exportDate` u32, as `yyyymmdd` — the FDA export this was built from |
| 16 | 4 | `packageCount` u32 |
| 20 | 4 | `productCount` u32 |
| 24 | 4 | `keysOffset` u32 |
| 28 | 4 | `packagesOffset` u32 |
| 32 | 4 | `formatsOffset` u32 |
| 36 | 4 | `productsOffset` u32 |
| 40 | 4 | `stringsOffset` u32 |
| 44 | 4 | `stringsLength` u32 |
| 48 | 16 | reserved, zero |

### Keys — `u64 × packageCount`, strictly ascending

Each key is a package NDC's ten digits read as an integer, with its hyphens
removed: `50090-6441-0` → `5009064410`. Ten digits fit in 34 bits.

Strictly ascending, so a lookup is a binary search — eighteen comparisons over
217k packages. The design doc says "a single hash probe"; a sorted array is
within noise of that at this size and has no hash function to choose wrongly,
no load factor to tune, and an ordering the builder can assert.

**Keys are unique.** Across the entire 2026-08-18 directory, all 255,178
package NDCs produce 255,178 distinct ten-digit forms — zero collisions. This
is what makes GTIN → NDC resolution deterministic rather than a guess, and the
builder fails loudly rather than silently dropping a row if it ever stops being
true.

### Packages — `u32 × packageCount`

Index into the products section, parallel to the keys.

### Formats — `u8 × packageCount`

The package NDC's native segmentation, parallel to the keys:
`0` = 4-4-2, `1` = 5-3-2, `2` = 5-4-1, `3` = 6-4-2. Kept because the
segmentation is meaning: it is what turns ten digits back into the code the FDA
publishes, and it is not recoverable from the digits.

### Products — 24 bytes each

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `nameOffset` u32 |
| 4 | 2 | `nameLength` u16 |
| 6 | 2 | `genericLength` u16 |
| 8 | 4 | `genericOffset` u32 |
| 12 | 4 | `strengthOffset` u32 |
| 16 | 2 | `strengthLength` u16 |
| 18 | 2 | `dosageFormLength` u16 |
| 20 | 4 | `dosageFormOffset` u32 |

A zero length means the field is absent. Every offset is relative to
`stringsOffset`.

`name` is the brand name, falling back to the generic name when the record has
no brand — 21,710 of 137,198 do not. `strength` is present **only for products
with exactly one active ingredient**: a two-ingredient tablet has two strengths
and no single one is the truth, so the field is left empty rather than filled
with the first.

### Strings — UTF-8, deduplicated, not terminated

Read by explicit `(offset, length)`. Deduplication matters more than it looks:
61,348 distinct strings back 115,697 products.

## What is filtered out

`product_type` outside `HUMAN PRESCRIPTION DRUG`, `HUMAN OTC DRUG`, `VACCINE`,
`PLASMA DERIVATIVE` and the two allergenic types — which removes bulk
ingredients and drugs for further processing. Those are raw materials with no
consumer package, so a match against one would be a false positive on a shelf
nobody's medicine came from.

## Rebuilding

```
python3 Tools/build-ndc-index.py --download --output DailyDose/Resources/ndc-index.ddndc
```

Downloading is the only step that touches the network, it happens on a
developer's machine, and it fetches a public-domain file. Nothing in the
shipped app makes a request.

## Licence

The source data is the FDA National Drug Code Directory, released as **CC0 1.0
Universal** (public domain). Redistribution is explicitly permitted. The
attribution and the FDA's own disclaimer are shown in the app under
**Settings → About → Data sources**.
