# Daily Dose — Critical Review

**Reviewed:** 12 August 2026 · **Version:** 0.1 · **Target:** iOS 17.0+ (Swift 5 language mode)
**Scope:** full source audit (20 Swift files, ~3,900 lines), UX, accessibility, App Store readiness, market position
**Method:** static review. No Xcode on this machine — nothing here was verified by running the app, so treat build-level claims as "check this," not "this is broken."

---

## 1. The one-paragraph verdict

Daily Dose is a genuinely well-designed app trapped inside an unreliable engine. The visual craft is real — the ambient sky header, the day-complete pivot, the "one loud button only on the dose that needs you" rule, the Apple Health color palette — this is the work of someone with taste who has actually looked at Apple's apps instead of copying a Dribbble shot. The comments in the source read like design rationale, not filler, and that is rare.

But the app's *core promise* is "you will not miss a dose," and the notification layer cannot currently keep that promise. Reminders are never rescheduled on launch; medications with interval, monthly or end-dated schedules get 20 one-shot notifications and then go permanently silent; and any user with three daily-4× medications will silently blow past iOS's 64-notification ceiling. On top of that, a newly added medication is retroactively marked as having *missed* seven days of doses it was never scheduled for, so the first thing a new user sees is an adherence score near zero. **The fix list below is roughly two weeks of work, and until it's done the app is not shippable — not because it looks unfinished, but because it will quietly fail the people relying on it.**

---

## 2. What is genuinely working

| Area | Why it's good |
|---|---|
| **`isScheduledOn` as single source of truth** (`Models.swift:44`) | One function that DoseEngine, notifications and the calendar all call. This is the correct architecture and most apps in this category get it wrong. |
| **Legacy-tolerant schema** (`Models.swift:31–40`) | Optional `scheduleKindRaw` with a sane fallback means old stores migrate without a migration plan. Thoughtful. |
| **The "day complete" pivot** (`TodayView.swift:129–153`) | Finishing the day and pivoting to *tomorrow's plan* instead of a graveyard of grey cards is a real design insight. Medisafe doesn't do this. |
| **Hero actions only where they belong** (`TodayView.swift:486–489`) | Loud Taken/Skip buttons appear only on the dose that is actually actionable. Restraint most apps lack. |
| **Health palette + dynamic dark mode** (`MedPalette.swift`) | A `UIColor` trait provider lifting colors 12% toward white at night is exactly what Apple Health does. |
| **Read-only HealthKit scope** (`HealthKitManager.swift:21–47`) | Never writing to HealthKit is the right compliance posture and the in-file review notes show you did the homework. |
| **Notification actions without launching** (`NotificationScheduler.swift:222–251`) | Taken/Snooze/Skip straight from the banner, with a fresh `ModelContext` — correct pattern. |
| **Wayfinding "Return to Today"** (`TodayView.swift:91`) | The comment says "elders tap days by accident and get lost." That's real empathy encoded in a button. |

---

## 3. Blocking defects

These will cause user-visible failure, data loss, or App Store rejection. Ordered by severity.

### 🔴 B1 — Dose reminders are never rescheduled after launch
**Files:** `TodayView.swift:414–418`, `NotificationScheduler.swift:65`

`rescheduleAll` is called from exactly four places: saving a medication, pausing/deleting one, logging a refill, and the "enable notifications" buttons. `TodayView.refresh()` — the only thing that runs on launch and on scene-active — calls `refreshFollowUps` but **not** `rescheduleAll`.

Combined with B2 this means: install the app, add a medication with an every-3-days schedule, use it for three weeks without editing anything → reminders stop and never come back. The user has no way to know.

**Fix:** call `rescheduleAll` from `refresh()` (it's idempotent), and add a `BGAppRefreshTask` so the projection is topped up even when the app isn't opened.

### 🔴 B2 — Interval/monthly/end-dated meds get exactly 20 notifications, then silence
**File:** `NotificationScheduler.swift:89–104`

```swift
for offset in 0...60 where added < 20 {
```
A medication with an end date taken 4× daily gets **5 days** of coverage. A monthly med gets 20 months (fine). An every-2-days med gets 40 days (fine). But the daily-with-end-date case — antibiotics, prednisone tapers, the *most safety-critical courses there are* — runs out in under a week and only refills if the user happens to open the app.

**Fix:** raise the cap, prioritise by date rather than iteration order, and combine with B1 + background refresh. Budget the 64 slots explicitly (see B3).

### 🔴 B3 — The 64-notification ceiling is miscounted, and the comment is wrong
**File:** `NotificationScheduler.swift:5–9, 73–88`

The header comment claims repeating weekly triggers mean "meds × times each count once." That is not what the code does — it schedules one request **per weekday per time**:

```
notifications = Σ (times × weekdays)
```

- One med, 4×/day, every day = **28** pending requests
- Three such meds = **84** — iOS silently keeps the 64 soonest and drops the rest
- Plus up to 30 follow-up nags and 3 refill alerts per med, all from the same budget

The failure is silent and non-deterministic. It will look like "sometimes my evening pill doesn't remind me."

**Fix:** for `.daily`, use `UNCalendarNotificationTrigger` with only `hour`/`minute` set (repeats daily, 1 request per time instead of 7). That alone cuts the daily case by 7×. Then add an explicit budget manager that queries `pendingNotificationRequests()` and degrades gracefully — nearest doses first — rather than letting iOS truncate arbitrarily.

### 🔴 B4 — New medications are retroactively marked as 7 days of missed doses
**Files:** `DoseEngine.swift:78–87`, `Models.swift:44–65`

`recordMissedDoses` walks back 7 days and inserts a `.missed` event for every unlogged overdue dose. But `isScheduledOn` has **no floor** — `.daily` returns `true` unconditionally, `.weekdays` checks only the weekday. There is no `createdAt` or `startDate` check.

Add a daily medication at 8pm today → the app immediately records 7 days × N times of missed doses for a medication that did not exist. History opens on "A fresh start" at ~0%, the per-med ring is red, and the log is full of fabricated failures.

This is the worst kind of bug in a health app: it invents negative data about the user.

**Fix:**
```swift
// in isScheduledOn, before the switch:
let floor = cal.startOfDay(for: startDate ?? createdAt)
if dayStart < floor { return false }
```
Then decide deliberately whether `startDate` should be settable for daily/weekly schedules (it currently isn't — see G3).

### 🔴 B5 — Deleting a medication destroys its history, while the dialog promises the opposite
**Files:** `MedicationDetailView.swift:204–211`, `Models.swift:67`

The confirmation says: *"Its history stays in your records, but reminders will stop."*

The relationship says:
```swift
@Relationship(deleteRule: .cascade, inverse: \DoseEvent.medication)
```

Every dose event is cascade-deleted. The dialog is telling the user something false immediately before irreversible data loss. For a medical adherence record this is both a trust failure and, in some jurisdictions, a records problem.

**Fix:** either change the rule to `.nullify` (HistoryView already handles `medication == nil` with a `"(deleted)"` label at line 268) **or** change the copy. `.nullify` is the better product answer — but then also denormalise the med's name/color onto `DoseEvent` so the history stays readable.

### 🔴 B6 — No app icon
`Assets.xcassets/AppIcon.appiconset/` contains only a 177-byte `Contents.json`. Hard submission blocker, and the home screen shows a white square in the meantime.

### 🔴 B7 — Backup is lossy and there is no import
**File:** `SettingsView.swift:125–172`

`MedBackup` stores `name, doseDetail, notes, colorName, times, weekdays, isActive, pillsRemaining, refillWarnAt`. It **omits** `scheduleKindRaw`, `intervalDays`, `startDate`, `dayOfMonth`, `endDate` and `uuid`.

So a backup of an every-21-days injection restores as a daily med, and events are keyed by `medName` — two meds with the same name merge on any future import.

Worse, the footer reads:
> "There is no cloud — by design. Export a backup regularly. Import is coming in a future update; backups are compatible with the Daily Dose web app."

The entire data-safety story rests on an export that silently discards schedule data, into a format that cannot be read back, referencing a web app that (as far as this repo shows) doesn't exist. **"Import is coming in a future update" is also an App Review 2.1 flag** — don't advertise unshipped features in shipping UI.

**Fix:** version the format, include every field plus `uuid`, ship import in the same release, delete the web-app sentence.

### 🔴 B8 — `fatalError` on ModelContainer failure
**File:** `DailyDoseApp.swift:10`

A SwiftData migration failure, a corrupt store, or a full disk crashes the app on launch — permanently, from the user's point of view — with no recovery path and no explanation. For an app someone depends on daily, this is the difference between "annoying" and "I missed my heart medication for three days."

**Fix:** catch, fall back to an in-memory container, and present a recovery screen offering Export / Reset.

---

## 4. Correctness bugs (ship-soon, not ship-blocking)

### 🟠 C1 — Adherence stats and the daily chart measure different things
`DoseEngine.adherence` (`DoseEngine.swift:129`) filters by **`loggedAt`**; `HistoryView.chartData` (`HistoryView.swift:54`) filters by **`scheduledAt`**. The hero ring and the bars underneath it can disagree, and because backfilled `.missed` events carry a `loggedAt` of "whenever the app was next opened," a week's worth of old misses can all land in "today." Pick `scheduledAt` — it's what the user means by "last 7 days."

### 🟠 C2 — Calendar weekday headers are wrong outside Sunday-first locales
**File:** `CalendarSheetView.swift:103, 109`

The grid offset correctly respects `cal.firstWeekday`:
```swift
let firstWeekday = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
```
…but the header row renders `shortStandaloneWeekdaySymbols` **unrotated**, which is always Sunday-first. In Germany (and most of Europe, and your own locale) every column is mislabelled by one day. A user checking "did I take Thursday's dose" reads the wrong column.

**Fix:** rotate the symbols by `cal.firstWeekday - 1`.

### 🟠 C3 — Pill count desyncs on status changes
**File:** `DoseEngine.swift:89–100`

`log()` decrements `pillsRemaining` when status is `.taken`, but the "existing event" branch just overwrites `status` without reversing a previous decrement. Sequence: mark Taken (−1) → change to Skipped (still −1) → back to Taken (−2). Supply drifts down over time and triggers false refill alerts.

**Fix:** compute the delta from `oldStatus → newStatus`.

### 🟠 C4 — Snoozes are wiped on next app foreground
**Files:** `NotificationScheduler.swift:112–113` vs `189–193`

`refreshFollowUps` removes every pending request prefixed `follow-`, `snooze-` or `refill-`. `TodayView.refresh()` calls it on every scene-active. So: snooze a dose from the notification → open the app for any reason → the snooze is gone.

**Fix:** don't sweep `snooze-` in `refreshFollowUps`; give snoozes their own lifecycle keyed to the dose.

### 🟠 C5 — `refreshFollowUps` returns early, skipping refill alerts
**File:** `NotificationScheduler.swift:120` — `guard scheduledCount < maxFollowUps else { return }` exits the whole function, not just the dose loop. A user with 30+ pending doses never gets refill alerts at all. Break out of the loops instead of returning.

### 🟠 C6 — Duplicate times silently collapse
`AddMedicationView.timeStrings` (`:234`) sorts but never de-duplicates, and `DoseEngine.loggedEvent` (`:72`) matches any event within 60 seconds. Set two doses to 08:00 and the list shows two cards; logging either marks both. Validate for uniqueness at save time.

### 🟠 C7 — Camera permission denial has no UI in either scanner
`LabelScannerView.isUsable` (`:35`) checks device *support*, not authorization. `ScannerContainerViewController.viewDidAppear` (`:136–144`) awaits `requestAccess` and, if denied, `return`s silently. The user sees a black rectangle with a shutter button and no explanation. Add a denied state with an "Open Settings" button — you already wrote exactly that UI in `SettingsView` for notifications.

### 🟠 C8 — Imported Health medications are inert and don't look it
`HealthImportView.importSelected` (`:135–150`) creates medications with `times: []`. These never generate a dose and never remind — but `MedCard` displays `scheduleSummary` as **"Every day"** because `weekdays` defaults to all seven. The card actively lies. Add a "Needs schedule" badge and route straight into the edit sheet after import.

### 🟡 C9 — `Dose.id` uses a locale-unsafe `DateFormatter`
`DoseEngine.swift:20–24` — a fixed `"yyyy-MM-dd-HH-mm"` format without `Locale(identifier: "en_US_POSIX")`. On a device set to the Japanese or Buddhist calendar, the year component changes, so notification identifiers (`follow-\(dose.id)`) shift and cancellation misses.

### 🟡 C10 — `scheduleSummary` can crash
`Models.swift:140` — `symbols[$0 - 1]` will trap if `weekdays` ever contains a value outside 1…7. Nothing currently produces that, but it's one bad import or backup restore away. Clamp it.

### 🟡 C11 — `navigationTitle(med.name)` bypasses `displayName`
`MedicationDetailView.swift:190, 204` use raw `name` while everything else uses `LabelScanParser.flatten`. A multi-line scanned name breaks the nav bar and the delete dialog.

### 🟡 C12 — Supply fields accept garbage silently
`AddMedicationView.save():472–473` — `Int(pillsRemaining)` returns `nil` for anything non-numeric, so "thirty" turns supply tracking off without a word. No check that `refillWarnAt < pillsRemaining` either.

---

## 5. Accessibility — the biggest gap between intent and delivery

The code repeatedly says it's designed for older users ("elders tap days by accident"). The accessibility implementation doesn't match that intent.

**Tap targets that VoiceOver and Switch Control cannot reach.** Every one of these is an `.onTapGesture` on a non-button container with no `.isButton` trait:
- `DoseCard`'s tap-to-open-detail (`TodayView.swift:534`) — the *only* route to undo, late-logging, and correcting a mistake
- `WeekStrip` day cells (`TodayView.swift:458`)
- `CalendarSheetView` day cells (`:153`)
- `AddMedicationView` weekday chips (`:249`) and color swatches (`:173`)
- `HealthImportView` selection rows (`:76`)

**Fix:** these should be `Button`s. It's a mechanical change and it fixes VoiceOver, Switch Control, Voice Control and Full Keyboard Access in one pass.

**Dynamic Type.** Fixed frames everywhere — 48×48 and 54×54 med tiles, 34pt day rings, 88pt hero circle — combined with `.lineLimit(1)` on medication names. At AX3 and above, names truncate to "Metfor…" and the week strip overflows. For the stated audience this is the single highest-impact accessibility fix. Use `@ScaledMetric` for the tiles and let names wrap to two lines.

**Contrast.** `MedPalette` renders a white `pill.fill` glyph on solid color tiles. Against `yellow` (0.965, 0.808, 0.275), `mint`, `brown`, `olive` and `sky`, white falls well under the 3:1 non-text minimum. Apple Health uses dark glyphs on light chips for exactly this reason. Pick the glyph color per-swatch by luminance.

**Missing announcements.** Toasts ("Taken", "Skipped", "Undone") are the only confirmation that an action succeeded, and they're pure visual — no `AccessibilityNotification.Announcement`. A VoiceOver user taps Taken and gets silence.

**Charts.** `HistoryView`'s `Chart` has no `.accessibilityChartDescriptor` and no per-mark labels.

---

## 6. Performance

Ranked by when you'll actually feel it.

1. **Calendar sheet** (`CalendarSheetView.swift:133`) — `dayProgress` per day cell, each running the full dose engine and doing a linear scan over the medication's entire event history. Thirteen months of cells. With a year of real data this is a visible stall on open and gets worse as you scroll. Precompute a `[Date: (taken, total)]` map once per sheet presentation.
2. **`MedsView.active`** (`:20–27`) — `nextDose()` is called inside a `sorted` comparator (so O(n log n) times) and again in every `MedCard` body. Each call can walk 61 days × times × a full event scan. Compute once into a dictionary.
3. **`HistoryView`** (`:11`) — unbounded `@Query` loads every event ever recorded, then `chartData` filters it 30 times. Fine at month one, a memory and CPU problem at year two. Use `FetchDescriptor` with a date predicate.
4. **`DayStat.id = UUID()`** (`:33`) — a fresh identity on every recomputation defeats `Chart` diffing and causes the bars to re-animate from scratch on any state change. Use `day` as the id.
5. **`.glassEffect` on every card** without a `GlassEffectContainer` — Apple's guidance is to group sibling glass surfaces. Worth measuring on an older device.

---

## 7. App Store readiness

| Item | Status |
|---|---|
| App icon | ❌ Missing (B6) |
| `MARKETING_VERSION` | ⚠️ `0.1` — set to `1.0` |
| Privacy policy URL | ❌ Not present in-app or referenced |
| Medical disclaimer | ❌ None. Strongly advised: "not a substitute for professional medical advice." |
| `NSCameraUsageDescription` | ✅ Excellent — specific and honest |
| `NSHealthShareUsageDescription` | ✅ Good |
| HealthKit entitlement | ✅ Read-only scope |
| Privacy manifest | ✅ Present and correct (nothing leaves the device) |
| Time-sensitive entitlement | ⚠️ Deliberately omitted — but `SettingsView:44` **promises** alerts that "break through Focus modes." The copy is currently false. Add the entitlement or change the copy. |
| iPad support | ⚠️ Landscape declared, no iPad layout. Either build one or restrict to iPhone. |
| Localization | ❌ None. Every string hardcoded English, no String Catalog. Notable for an EU launch. |
| App Store description | ⚠️ Must mention Health app integration (per your own note in `HealthKitManager.swift:19`) |
| Tests | ❌ **Zero.** No test target at all. |

**On that last point:** `DoseEngine` and `Medication.isScheduledOn` are pure functions with no UIKit dependency. Every single one of B4, C1, C3 and C6 would have been caught by a fifty-line XCTest file. QRFlow — the same author, the same week — has 48 tests. Daily Dose has none, and it's the app where a bug means a missed heart pill. Fix this first; it will pay for itself before you finish the list above.

Specific cases worth pinning: DST spring-forward (a 02:30 dose on a day where 02:30 doesn't exist), a med added mid-day, month-end clamping for "monthly on the 31st," and an every-N-days schedule crossing a DST boundary.

---

## 8. Market position

### Who you're actually competing with

| | Price (2026) | Strengths | Weaknesses you can exploit |
|---|---|---|---|
| **Apple Health** | Free, built in | Drug **interaction warnings** from a real clinical database; Apple Watch; Health Sharing with family/clinicians; zero install friction | No supply/refill tracking; no adherence % or exportable report; interaction data is region-limited; scheduling is rigid |
| **Medisafe** | **Went paid Jan 1, 2026** — free tier capped at **2 medications**; $4.99/mo or $39.99/yr | "Medfriends" caregiver alerts, huge install base, drug interaction checks, polished | **Massive user resentment.** Long-time users are actively churning. Ads on free tier. |
| **MyTherapy** | Free, no subscription | Free and unlimited, health-measurement tracking (BP, weight, glucose), **doctor-ready report generation** | Dated UI, generic notifications, not iOS-native feeling |
| **Pillo / MedTimer / TOM** | Free | Filling the Medisafe gap right now; MedTimer is open-source | Small, rough, mostly Android-first |

### The opening is real and it is *right now*

Medisafe capping its free tier at two medications on January 1st is the single most important fact in this market. Anyone managing three or more medications — which is most of the actual target user — was pushed off a product they'd used for years, and the search results are full of "5 free alternatives" listicles. That window will close as MyTherapy and Pillo absorb the churn.

Your `SettingsView` manifesto — *"Medication reminders are healthcare, not a subscription. Free, unlimited, and private — forever."* — is precisely the right message at precisely the right moment. It's also a promise you'd have to honour permanently, so decide now whether you mean it.

### Where you can't win, and shouldn't try

- **Drug interaction checking.** Apple Health does it with a licensed clinical database. Licensing one (First Databank, Elsevier) is expensive and carries regulatory weight. Don't fake it with a hardcoded list — that's both an App Review 1.4.1 risk and a genuine safety hazard.
- **Raw reminder reliability vs. Apple Health.** Health is in the OS, gets the Watch for free, and has no 64-notification ceiling. Competing on "we remind you better" is competing on their turf.

### Where you can win

**1. The doctor's-appointment report.** This is the biggest gap in your app and one of the biggest in the whole category. MyTherapy's report generation is a headline feature; Apple Health has nothing. You already compute per-day, per-med adherence — a one-tap **PDF: 30/60/90-day adherence, per medication, with a missed-dose calendar**, shareable to Mail or Files, is maybe two days of work using the `pdf` skill's toolchain. It converts "another pill reminder" into "the thing I bring to my cardiologist."

**2. Supply and refill as a first-class feature.** Apple Health doesn't track pill counts at all. You already have `pillsRemaining` and `refillWarnAt`. Push it further: predict the run-out date from the schedule ("you'll run out on the 3rd — order by the 28th"), let the user log a refill by scanning the new box.

**3. Caregiver mode.** Medisafe put "Medfriends" behind the paywall. A read-only shared adherence view — via CloudKit share or even a signed link — for an adult child watching a parent's medications is the highest-value feature in this category and is now paywalled at the incumbent.

**4. The label scanner.** Your `LabelScannerView` is better than what most competitors ship, and the "point at the bottle, tap the shutter" interaction is genuinely grandmother-testable. Lean into it as the onboarding path — first-run should be *camera*, not an empty form.

**5. Europe.** Medisafe's interaction data and Apple's are US-centric. You're in Berlin. German/French/Spanish localization plus EU-appropriate framing is a defensible niche the US-based incumbents don't prioritise.

### What to avoid

- **Don't add a subscription later.** You've written "free forever" into the app. Breaking that is exactly the wound Medisafe just inflicted on itself, and your early adopters will be people who came *because* of that promise.
- **Don't ship "no cloud, by design" without a working import.** Right now the privacy story is "your data is safe and also permanently unrecoverable." Privacy-first must still mean restorable — a lossless local backup file, or optional CloudKit (which is still end-to-end private and costs you nothing).
- **Don't make medical claims.** "Improves adherence," "reduces missed doses by X%" invites both App Review scrutiny and regulatory attention.
- **Don't chase Apple Health feature-for-feature.** Ride it — the import path is a strength — but differentiate on report, supply, and caregiver.

---

## 9. Suggested sequence

**Week 1 — stop the bleeding**
1. Add a test target. Pin `isScheduledOn` and `DoseEngine` first (§7).
2. B4 — schedule floor at `createdAt`/`startDate`. Fabricating missed doses is the worst bug here.
3. B1 + B2 + B3 — reschedule on launch, budget the 64 slots, use daily-repeating triggers, add `BGAppRefreshTask`.
4. B5 — `.nullify` + denormalised name on `DoseEvent`, or fix the copy.
5. B8 — recover from container failure instead of `fatalError`.

**Week 2 — trust and polish**
6. B7 — versioned lossless backup **plus import**, remove the web-app claim.
7. C1–C4 — the `loggedAt`/`scheduledAt` split, the calendar weekday headers, pill-count deltas, snooze survival.
8. Accessibility pass: `.onTapGesture` → `Button` everywhere, `@ScaledMetric` on the fixed frames, glyph contrast, toast announcements.
9. B6 — app icon. `MARKETING_VERSION` → 1.0. Privacy policy URL. Medical disclaimer.

**Week 3 — the wedge**
10. **PDF adherence report.** This is the feature that makes the app worth choosing.
11. Run-out prediction on top of `pillsRemaining`.
12. Camera-first onboarding.
13. German localization.

**Later**
14. Caregiver share (CloudKit).
15. Apple Watch complication + app — Apple Health has this and it matters for adherence.
16. Swift 6 language mode (currently 5.0; the `@MainActor`/`nonisolated` boundaries in `NotificationScheduler` will need attention).

---

## 10. One thing to keep in mind

The gap in this project isn't skill — the design work is better than most shipping health apps and the architecture instincts are sound. The gap is **verification**. Every blocking bug in §3 is in the layer that can't be seen by looking at the screen: notification budgets, cascade rules, retroactive data writes, backup completeness. The app *looks* finished, which is exactly why these are dangerous.

The same author wrote 48 tests for a QR code generator and zero for the app that reminds people to take their heart medication. Inverting that ratio is the highest-leverage change available.

---

## Sources

- [Free Medisafe Alternative: The Best Medication Apps for 2026 — MyTherapy](https://www.mytherapyapp.com/blog/medisafe-alternatives-free)
- [Is Medisafe Still Free in 2026? Top 5 Alternatives — Pillo](https://pillo.care/blog/medisafe-no-longer-free-best-free-alternatives)
- [Track your medications in Health on iPhone — Apple Support](https://support.apple.com/guide/iphone/track-your-medications-iph811670c81/ios)
- [Best Medication Tracker App: 7 Options Compared (2026)](https://www.yougot.ai/blog/health/medication-reminders/medication-tracker-app)
- [5 Best Medication Reminder Apps for Caregivers (2026)](https://be-tended.com/guides/medication-reminder-apps-caregivers/)
