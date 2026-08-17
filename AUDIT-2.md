# Daily Dose — Second Audit

**Date:** 12 August 2026 · **Version:** 1.0 (unreleased)
**Scope:** the current tree on disk, including every change made since the rebuild
**Codebase:** 36 app source files, 7 test files
**Method:** static review against the deployed tree. No Xcode here — build claims are "verify this", not "this is broken". Where I make a factual claim about SwiftData behaviour I've cited the source.

---

## 1. Verdict in one paragraph

The architecture is holding. I re-checked all seven invariants the rebuild established — schedule floor, nullify delete, daily repeating triggers, adherence-by-`scheduledAt`, reschedule-on-foreground, lossless backup, locale-correct calendar headers — and **every one survived the subsequent edits**. That is the single best signal in this audit: the layering is doing its job, and a week of UI work didn't quietly undo a correctness fix. The interaction design has also moved forward materially — the stacked dose card is the best idea in the app.

But there is one blocker, and it is serious: **the schema migration is written against a SwiftData contract that doesn't hold, and on current evidence it will lose or blank every existing user's data on upgrade.** Everything else in this report is polish. That one is not.

---

## 2. What's genuinely good

### The migration exists at all
Adding a `VersionedSchema` before 1.0 ships is the right instinct and most teams skip it until it's too late. The intent in `SchemaMigration.swift` is correct throughout: `uuid` carried into `id` so notification payloads keep resolving, `startDate ?? createdAt` as the honest floor, name and colour denormalised onto every event so history survives a later delete. The *thinking* is right. The mechanism is wrong (§3).

### `MigrationTests` is the right shape
It writes a real V1 store to disk and reopens it through the plan — an integration test against the actual path a user's phone takes, not a mock. Most migration "tests" don't do this. It needs more cases (§4), but the shape is correct.

### The stacked dose card
`DoseCard` collapsing a 4×/day medication into one card — count badge on the tile, peeking card edges beneath, tap to fan open — is the strongest design decision in the app. It borrows the Lock Screen's grouped-notification grammar, so it reads instantly without instruction. Critically, it's implemented *accessibly*: each stacked dose is a real `Button` with its own label and hint, and the collapsed card's hint says how many are inside. A lot of apps get the visual and lose the accessibility.

### Feedback lands before the card moves
`confirmTaken()` morphs the button to a checkmark, then writes. That ordering is right — the old behaviour confirmed after the card had already left the section, which is confirmation nobody sees. (The 600 ms delay has a cost; see B2.)

### Reverting per-card Liquid Glass
Solid `secondarySystemGroupedBackground` for cards was the correct call, and the comment at `Components.swift:152–160` explains *why* — no `GlassEffectContainer`, one glass pass per card, visible flicker on scroll. That comment is institutional memory. It's what stops someone re-introducing it in six months.

### One landmark, two meanings
The header circle is the day-progress ring on today and the return-to-today button on any other day, with the position fixed and the contents morphing. That's a genuine Apple-grade decision: the eye learns one location instead of two controls.

### `AuroraBloom`
Restrained and correctly engineered — a pure function of elapsed time, no timers, no state to leak, gated on Reduce Motion, and it leaves the view tree entirely when spent so the resting app renders zero animation frames. The "do not regress" design notes are the right way to record hard-won tuning.

### Everything the rebuild fixed is still fixed

| Invariant | Status |
|---|---|
| Schedule can't occur before `startDate` | ✅ `DoseSchedule.swift:66` |
| Delete nullifies, history survives | ✅ `Medication.swift:48` |
| Daily = 1 repeating trigger per time | ✅ `NotificationPlanner.swift:131` |
| Adherence measured by `scheduledAt` | ✅ `AdherenceCalculator.swift:121` |
| Reschedule on launch + foreground | ✅ `AppEnvironment.swift:170–171` |
| Backup carries all schedule fields | ✅ 15 references |
| Calendar headers rotate with locale | ✅ `CalendarSheet.swift:39` |
| No duplicate type declarations | ✅ clean |
| Braces balanced, all 43 files | ✅ |

---

## 3. 🔴 BLOCKER — The migration will lose user data

**File:** `DailyDose/Models/SchemaMigration.swift:104–147`

### What the code does

```swift
didMigrate: { context in
    let legacyMedications = try context.fetch(FetchDescriptor<DailyDoseSchemaV1.Medication>())
    …
}
```

### Why that can't work

SwiftData applies the schema transformation **between** `willMigrate` and `didMigrate`. In `willMigrate` only the *source* model types are valid; in `didMigrate` only the *destination* types are. You cannot fetch the old model type in `didMigrate` — [Donny Wals' deep dive](https://www.donnywals.com/a-deep-dive-into-swiftdata-migrations/) states it plainly: at that point "you only have access to your new model versions."

So `FetchDescriptor<DailyDoseSchemaV1.Medication>` runs after the store is already V2. Because SwiftData resolves entities *by name* and both types are called `Medication`, this doesn't cleanly fail — it reads V2 rows through V1's property map, looking for `uuid`, `times`, `refillWarnAt`, columns that no longer exist.

### The deeper problem: the automatic step can't succeed either

Before `didMigrate` ever runs, SwiftData has to get V1 → V2 on its own. That transformation includes:

| Change | Lightweight-compatible? |
|---|---|
| `uuid` → `id` | ❌ rename, no `@Attribute(originalName:)` |
| `times` → `timesRaw` | ❌ rename, unmapped |
| `weekdays` → `weekdaysRaw` | ❌ rename, unmapped |
| `refillWarnAt` → `refillThreshold` | ❌ rename, unmapped |
| `scheduleKindRaw: String?` → `String` | ❌ optional → required, no default |
| `startDate: Date?` → `Date` | ❌ optional → required, no default |
| `intervalDays: Int?` → `Int` | ❌ optional → required, no default |
| `DoseEvent` gains 3 non-optional `String`s | ❌ no defaults |
| delete rule `.cascade` → `.nullify` | ⚠️ |

I confirmed on disk: **zero `@Attribute(originalName:)` in the models**, and every one of those properties is declared non-optional with no default.

### What a user actually experiences

Someone upgrading from the original build gets one of two outcomes:

1. **The migration throws.** `AppEnvironment` catches it, falls back to an in-memory store, and shows `RecoveryView` — *"Your data couldn't be opened."* Their entire medication list and history appear gone. (The recovery screen working correctly here is genuinely good — it's the difference between a scary screen and a crash loop. But it's still total data loss from the user's point of view.)
2. **The migration "succeeds"** with medications blanked — empty names, epoch start dates, no dose times — and every event orphaned.

There's a third hazard: `@Attribute(.unique) var id`. SwiftData treats a unique-constraint collision as an **upsert**, not an error. So a partially-successful migration can silently overwrite rather than fail loudly.

### The fix (documented pattern)

**1 — Map the renames on the *current* models**, which makes most of this lightweight:

```swift
@Attribute(.unique, originalName: "uuid") var id: String
@Attribute(originalName: "times")        var timesRaw: [String]
@Attribute(originalName: "weekdays")     var weekdaysRaw: [Int]
@Attribute(originalName: "refillWarnAt") var refillThreshold: Int?
```

**2 — Give genuinely-new non-optional properties defaults**, so the automatic step can fill them:

```swift
var scheduleKindRaw: String = ScheduleKind.daily.rawValue
var intervalDays: Int = 1
var startDate: Date = .distantPast      // sentinel, backfilled below
// DoseEvent
var medicationID: String = ""
var medicationName: String = ""
var medicationColorName: String = ""
```

**3 — Backfill in `didMigrate` using the *new* types:**

```swift
didMigrate: { context in
    for medication in try context.fetch(FetchDescriptor<Medication>()) {
        if medication.startDate == .distantPast {
            medication.startDate = medication.createdAt   // the honest floor
        }
        for event in medication.events where event.medicationID.isEmpty {
            event.medicationID        = medication.id
            event.medicationName      = medication.displayName
            event.medicationColorName = medication.colorName
        }
    }
    try context.save()
}
```

Keep `DailyDoseSchemaV1` for `VersionedSchema` bookkeeping — just never fetch it in `didMigrate`.

> **Before changing anything, run `MigrationTests` as it stands.** If it passes, that contradicts the documented behaviour and is worth understanding — it may mean SwiftData is silently doing something the docs don't describe, and you'd want to know that before relying on it either way.

---

## 4. 🟠 High

### H1 — `MigrationTests` covers one shape only
**File:** `DailyDoseTests/MigrationTests.swift`

One medication, one event, happy path. Missing:
- `scheduleKindRaw == nil` — the legacy case the *original* app explicitly handled, and the one most real stores will be in
- Multiple medications
- A `DoseEvent` whose `medication` is nil
- Running the migration twice (idempotency)
- Opening a store that's already V2

Given §3, this suite is exactly the thing that should have caught the problem. Extend it before trusting any fix.

### H2 — Demo seeding ships in Release
**File:** `AppEnvironment.swift:78–160`

~85 lines gated only on a launch argument, not `#if DEBUG`. It's compiled into the shipping binary. Low security risk (launch args need Xcode), but it's dead weight, and each of its ~14 `store.add`/`store.log` calls triggers a full `rescheduleNotifications()` — so `-seedDemo` rebuilds the whole notification plan fourteen times.

Wrap the whole function in `#if DEBUG`.

### H3 — `let course` is never used
**File:** `AppEnvironment.swift:130`

Compiler warning, and a functional gap: the Amoxicillin course is the medication specifically designed to produce an actionable "due now" card for screenshots, and none of its doses are ever logged. The seeded story is incomplete.

---

## 5. 🟡 Medium

### M1 — Two places disagree on "missed"
`DaySummarySheet.missed` counts `.logged(.missed) || .overdue` (`TodayView.swift:448`), while `DayCompleteCard.missed` counts only `.logged(.missed)` (`TodayView.swift:534`). Same day, same data, two different numbers depending on which surface you look at. Pick one definition — `.overdue` *is* missed from the user's point of view — and put it on `DayPlan` so there's one answer.

### M2 — 600 ms where a Taken tap isn't persisted
`DoseCard.confirmTaken()` (`:272–282`) animates, sleeps 600 ms, *then* writes. If the app is killed or crashes in that window, the dose the user just confirmed is silently lost. Write first, animate second — the animation doesn't need to gate the write. Or shorten it substantially.

### M3 — `isConfirmingTaken` never resets
Currently harmless only because the card is destroyed when it moves to the Taken section. If that ever stops being true — an undo that keeps the card in place, a different grouping — the button stays disabled showing a permanent checkmark. Reset it after `onLog`, or key it off the dose state.

### M4 — `cardStyle(interactive:)` is now dead
`CardBackground` ignores the parameter entirely since the glass revert (`Components.swift:161–171`), but three call sites still pass `interactive: true`. Either remove the parameter or honour it — a parameter that silently does nothing is a trap for the next reader.

### M5 — Documentation rot in `TodayView`
- `:22` — "each value is one **BreathBloom**" → the type is `AuroraBloom`
- `:306` — "(see **BreathBloom**)" → same
- `:517–525` — a full doc comment describing the aurora effect, now orphaned directly above `DayCompleteCard`, so it documents the wrong type entirely

Three small things, but this is the exact failure mode that makes a codebase untrustworthy: comments that confidently describe something that isn't there.

### M6 — A medication can appear in two sections at once
`doseSections` splits `due` from `upcoming` *before* grouping, so a medication with one due dose and two upcoming ones renders as a card in "Due now" **and** a stack in "To take". Defensible — the due one genuinely needs action now — but worth a deliberate decision rather than an emergent one.

---

## 6. Carried over, still open

| Item | Note |
|---|---|
| Swift 5 language mode | `SWIFT_VERSION = 5.0`. The code is written Swift 6-clean (actor, `@MainActor`, `Sendable` value types). Try flipping it once it builds. |
| Time-sensitive entitlement | Still omitted so free Personal Teams can run. Settings copy no longer over-promises, so nothing is untrue meanwhile. Add before shipping. |
| iPad | `TARGETED_DEVICE_FAMILY = "1,2"`, no iPad layout. Build one or set it to `"1"`. |
| Localization | Strings are extraction-ready via `String(localized:)`. No catalog yet. |
| Privacy policy URL | Required for submission. |
| **PDF adherence report** | Still the biggest product opportunity — see below. |

---

## 7. What I'd do, in order

1. **Run `MigrationTests` and report what it actually does.** Everything else in the migration discussion depends on that result.
2. **Fix the migration** (§3) — `originalName` mappings, defaults on new properties, backfill against the new types.
3. **Extend the migration tests** (H1) — especially `scheduleKindRaw == nil`, which is the shape most existing stores are in.
4. `#if DEBUG` the seed, use or delete `course` (H2, H3).
5. M1 → M5 — a couple of hours of consistency and hygiene.
6. App Store checklist: entitlement, iPad decision, privacy policy, Swift 6.

Then the thing that actually differentiates the product:

**The PDF adherence report.** Unchanged from the first review and still true. Apple Health has nothing like it, MyTherapy makes it a headline feature, and `AdherenceCalculator` already produces per-day and per-medication summaries over any window — the data work is done. Roughly two days. It's what turns this from a pill reminder into the thing someone brings to their cardiologist.

---

## 8. The honest summary

You have built something good. The design has real judgement in it — the stacked card, the morphing header landmark, the restraint around motion, the decision to *revert* the glass when it didn't hold up. Those are the choices of someone editing rather than accumulating, which is the harder discipline.

The architecture proved itself in this audit: seven correctness fixes survived a week of aggressive UI work untouched, because they live in a layer the UI can't reach. That is exactly what the domain split was for.

And the one blocker is instructive. The migration is *well-intentioned, well-commented, and wrong* — it does the right things in the wrong closure, against an API contract that reads plausibly but doesn't hold. It's also the one area with no real test coverage. That's not a coincidence: **the gap in the tests and the gap in the correctness are in the same place, again.**

---

## Sources

- [A Deep Dive into SwiftData migrations — Donny Wals](https://www.donnywals.com/a-deep-dive-into-swiftdata-migrations/)
- [An Unauthorized Guide to SwiftData Migrations — Atomic Robot](https://atomicrobot.com/blog/an-unauthorized-guide-to-swiftdata-migrations/)
- [SwiftData Migrations: Lightweight vs Custom — Blake Crosley](https://blakecrosley.com/blog/swiftdata-migrations-guide)
