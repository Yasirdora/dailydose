# Daily Dose — Audit 3

**Date:** 17 August 2026
**Scope:** the full tree as it stands on disk (46 app sources, 12 test files), including the uncommitted work in progress.
**Lenses:** QA, product/interaction design, Apple-platform engineering.
**Method:** every finding below is quoted from the current source. Where I could not confirm something, it is marked *unverified* and says why.

---

## 0. Verdict

The architecture is now genuinely good. The domain layer is pure, testable and honest; the schedule engine handles cases most shipping medication apps get wrong; and **the migration blocker from AUDIT-2 §3 is fixed** — properly, not papered over.

What has changed since then is that the app grew a lot of new surface very fast: timeline cards, a day sheet, a dose sheet, a calendar rework, two new schedule kinds, and a PDF doctor report. The domain layer absorbed that growth well. The **view layer did not** — most of the defects below are in view state, and three of them will bite a real user on day one.

There are **3 blockers**, **9 high**, and a set of medium items. None is architectural. All are a day or two of work.

The honest summary: *the engine is close to shippable; the cockpit isn't.*

---

## 1. What has genuinely improved since AUDIT-2

Not padding — these are the things that were wrong and are now right.

**The V1→V2 migration is fixed, and fixed the right way.** `willMigrate` reads V1 rows into `Sendable` value snapshots and empties the store; the structural stage then maps zero rows, so renamed attributes lose nothing to mapping-model inference; `didMigrate` re-inserts using the **frozen `DailyDoseSchemaV2` models**, never the live ones. That last detail is the one almost everybody gets wrong, and the comment at `SchemaMigration.swift:191-200` explains exactly why. `MigrationTests.v1StoreMigrates` writes a real V1 store to a real file URL and re-opens it through the actual `ModelContainer(migrationPlan:)` — that is a real migration test, not a fake one.

**V3 was added as a lightweight stage, correctly.** `intervalHours`, `cycleOnDays`, `cycleOffDays` all carry defaults, so CoreData fills the columns and no row is rewritten. Adding V2 as a frozen copy rather than mutating V1 shows the versioning discipline has actually been internalised.

**The two new schedule kinds are modelled coherently end to end.** `.everyXHours` is computed as `anchor + k · interval` rather than by stepping a clock, so a DST jump shifts the wall-clock time but never the number of real hours between doses — which is what a prescriber means by "every 8 hours". `.cycle` and `.everyXDays` count with `calendar.dateComponents([.day],…)`, not seconds, so they are DST-correct in both directions. And `NotificationPlanner.repeatingCost` correctly refuses to express either as a calendar trigger and routes them through the projected one-shot path.

**`BackupService` was versioned properly for the new fields** — `currentVersion` bumped to 3, new fields optional with defaults, and the `archive.version <= currentVersion` guard already in place. Round-tripping a cycle schedule through a backup works, and an older build reading a v3 file refuses it with a real message instead of silently mangling the schedule.

**The doctor report is the right product bet**, and drawing its chart by hand instead of using SwiftUI Charts inside `ImageRenderer` is a correct, non-obvious call.

**The toolbar grammar held.** `AddMedicationToolbarButton`, `ToolbarGlyphButton` and `SettingsToolbarButton` are used consistently on all three chrome-bearing screens, and Meds search is wired through `searchable(when:)` with a proper `ContentUnavailableView.search` no-results state.

---

## 2. Blockers

### B1 — The Taken/Skip buttons permanently disable themselves after one log

**`Features/Today/MedicationDayCardView.swift:32, 259-289`**

```swift
@State private var isConfirmingTaken = false
...
withAnimation(...) { isConfirmingTaken = true }
Task { @MainActor in
    try? await Task.sleep(for: .milliseconds(600))
    onLog(dose, .taken)
}
```

`isConfirmingTaken` is set to `true` and **never set back to `false`** anywhere in the file. Both action buttons are `.disabled(isConfirmingTaken)`.

**Repro.** Metformin at 08:00 and 12:00. At 12:05 both are actionable, so the card sits in the same section (`tier == 0`). Tap **Taken** → the 08:00 dose is logged → the card's `actionable` advances to the 12:00 dose → same tier, same `ForEach`, same `id: medication.id` → SwiftUI reuses the view and preserves `@State`. The 12:00 dose now renders with a permanent checkmark and **both buttons dead**. There is no lazy container here to recycle the view and rescue it. The user cannot log their noon dose from the card at all. Same repro inside `CalendarSheet`'s day view, where every card is in one `ForEach` so any tier change preserves the stuck state too.

**Fix.** Key the confirmation on the dose, not a bare `Bool`:

```swift
@State private var confirmingDoseID: String?
...
.onChange(of: card) { _, _ in confirmingDoseID = nil }
```

or simply clear it in the `Task` immediately after `onLog`.

---

### B2 — Background refresh can leave the user with zero pending reminders

**`App/DailyDoseApp.swift:40-43`, `App/AppEnvironment.swift:168-172`, `Services/DoseStore.swift:312-327`, `Services/NotificationService.swift:92-106`**

```swift
.backgroundTask(.appRefresh(Self.refreshTaskIdentifier)) {
    await MainActor.run { environment.refresh() }   // returns immediately
    scheduleBackgroundRefresh()
}                                                   // ← iOS suspends here
```

`refresh()` is synchronous. It calls `rescheduleNotifications()`, which is **also synchronous** and does all its real work inside an un-awaited `Task { … }`. So the background-task closure completes and the system suspends the app while that task is still in flight — and `apply()` is destructive-first:

```swift
center.removePendingNotificationRequests(withIdentifiers: removable)   // all of them
for planned in plan.notifications {
    guard let request = makeRequest(planned) else { continue }
    try? await center.add(request)                                     // up to 64 awaits
}
```

The most likely suspension point is *after* the removal and *partway through* the re-adds. Net result: a user who doesn't open the app has **fewer, or zero, scheduled reminders** — which is precisely the failure the background task exists to prevent. The same hole opens on a fast app-switch, since `refresh()` also runs on every `.active` transition.

**Fix, two parts.**
1. Make the chain awaitable: `func rescheduleNotifications() async`, `func refresh() async`, `await environment.refresh()` inside `backgroundTask`.
2. Make `apply()` non-destructive: compute add-set and remove-set, **add first, remove stale second**. The current remove-then-add is defensible when the app is in the foreground and cannot be suspended; it is not defensible in a background task.

---

### B3 — The selected day never rolls over at midnight

**`Features/Today/TodayModel.swift:23, 41-42`**

```swift
var selectedDay: Date = .now { didSet { rebuildIfDayChanged(oldValue) } }
var now: Date = .now
...
func rebuild(now: Date = .now) {
    self.now = now        // `selectedDay` is never advanced
```

`selectedDay` is written only by user interaction — the week strip, the calendar, and `returnToToday()`. Nothing advances it with the clock. Worse, `log()` and `rebuildIfDayChanged()` both call `rebuild(now: now)`, re-passing the *stale* value, so only `TodayView`'s 60-second ticker ever moves `now` at all.

**Repro.** Open the app at 23:55 for a bedtime dose, put the phone down, pick it up at 00:10. `isToday` is now false: the greeting is replaced by a weekday name, the progress ring is replaced by a "Return to today" arrow, the Tomorrow section empties, and the list still shows **yesterday's** doses. Tapping Taken logs against yesterday's `scheduledAt` while the user believes it is today's dose. Today's dose stays unlogged and is later swept to `.missed`.

**Fix.** In `rebuild(now:)`, follow the day boundary when the user hasn't deliberately navigated away — track whether `isToday` was true at the previous `now`, and if so set `selectedDay = now` before recomputing. Also feed the ticker's date through `log()` rather than re-passing `self.now`.

---

## 3. High

### H1 — The doctor report silently mangles itself at five or more medications

**`Features/History/DoctorReport.swift:45-47, 103, 212, 282`**

```swift
var pages: [AnyView] = [AnyView(OverviewPage(data: data))]
if !data.timingNotes.isEmpty { pages.append(AnyView(TimingPage(data: data))) }
...
ForEach(data.medications) { medication in     // unbounded
...
ReportFooter(page: 1, totalPages: data.timingNotes.isEmpty ? 1 : 2)
```

There is no pagination. The page count is hardcoded to 1 or 2, and the medication list is an unbounded `ForEach` inside a fixed `.frame(width:height:)`. Budgeting the 842pt A4 page — 88 padding, ~53 header, 96 ring, ~139 chart, ~20 footer, 140 of inter-section spacing — leaves roughly 280pt for medications at ~65pt per row. **That is about four.**

A fixed `.frame` *centres* an oversized child, so at 5+ medications the title bleeds off the top **and** the footer off the bottom simultaneously, with rows missing from the middle and no indication anything was lost. The user who most needs this document is exactly the polypharmacy patient it breaks for. `TimingPage` has the same shape and survives only while every note fits on one line.

**Fix.** Chunk `data.medications` and `data.timingNotes` into page-sized slices before building `pages`, derive `totalPages` from the chunk count, and add `.clipped()` so any residual overflow truncates rather than mangles. Add a snapshot test at 1 / 5 / 12 medications.

---

### H2 — Tapping a bundled notification does nothing

**`Services/NotificationCoordinator.swift:54-55` vs `Services/NotificationService.swift:184-189`**

```swift
// Coordinator — the guard every tap passes through
guard let medicationID = userInfo[NotificationPayload.medicationID] as? String else { return }
```
```swift
// Service — what a bundle actually carries
case .doseBundle(let medicationIDs, let time):
    return [NotificationPayload.bundledMedicationIDs: medicationIDs,
            NotificationPayload.time: time.rawValue]
```

`bundledMedicationIDs` is **written and never read anywhere in the tree**. `bundleSimultaneousDoses` defaults to `true`, so this is the *default* path for anyone with two medications at the same time. Three pills at 08:00 → one notification → tap → the app opens on whatever tab it was left on, with nothing highlighted. Both the settings footer ("Tap it to log them on the Today screen") and the planner's own comment describe behaviour that isn't implemented.

**Fix.** Handle the bundle case before the guard: read `bundledMedicationIDs`, resolve the time, deep-link to the first (or add a `DeepLink` case carrying the set so Today can scroll to that time slot).

---

### H3 — A medication whose course starts in the future is reminded about tonight

**`Domain/NotificationPlanner.swift:151-175`, `241-282`**

```swift
func repeatingCost(_ medication: MedicationSnapshot) -> Int? {
    let schedule = medication.schedule
    guard schedule.endDate == nil else { return nil }   // no startDate check
```

`endDate` correctly forces a finite course onto the one-shot path. `startDate` is not considered anywhere in the repeating path, and `RepeatingGroup.notifications` emits an unbounded `.daily(time)` trigger. `nextFireDate` *is* computed correctly via `nextOccurrence` (which does respect `startDate`), so the plan looks right in a test while the trigger is wrong.

A prescription entered on 12 August to start 1 September says "Time for Warfarin" every evening for three weeks before the course begins — an active invitation to take medication early.

**Fix.** Treat a future `startDate` like an `endDate`: return `nil` from `repeatingCost` when `schedule.startDate > now`, so it goes through the projected one-shot path (which already handles bounds correctly).

---

### H4 — Tapping "Taken" on an old banner logs the wrong day's dose

**`Services/NotificationCoordinator.swift:129-132`**

```swift
guard let from = calendar.date(byAdding: .day, value: -45, to: now) else { return nil }
return schedule.occurrences(from: from, to: now, calendar: calendar)
    .last { TimeOfDay(from: $0, calendar: calendar) == time }
```

Repeating dose reminders carry only a `TimeOfDay`, so the tapped dose is reconstructed by scanning back from `Date.now` — ignoring `response.notification.date`, which is exactly the missing information. Two concrete failures:

1. **Stale banner.** Monday's 08:00 reminder is ignored and sits in Notification Centre. Tuesday at 09:00 the user pulls down the shade and taps **Taken**. `now` is Tuesday 09:00, so `.last` resolves to **Tuesday 08:00**. Tuesday's dose is marked taken, Monday's is later swept to missed, and supply is decremented against the wrong day.
2. **Early tap.** `occurrences(from:to:)` has an exclusive upper bound, so a banner tapped a few seconds *before* the scheduled instant resolves to **yesterday's** dose.

For an app whose stated promise is "an honest record", this is silent corruption of the data the doctor report is built from.

**Fix.** Anchor on `response.notification.date` instead of `Date.now`, falling back to `now` only when unavailable. Extract the resolution into a pure function over `(schedule, time, deliveredAt, calendar)` so it can be tested.

---

### H5 — `.timeSensitive` is claimed in two places and cannot be delivered

**`Services/NotificationService.swift:118-137`, `DailyDose.entitlements`**

```swift
content.interruptionLevel = planned.importance.breaksThroughFocus ? .timeSensitive : .active
```
```xml
<dict>
  <key>com.apple.developer.healthkit</key><true/>
</dict>
```

The entitlements file declares HealthKit and nothing else. `.timeSensitive` requires the **Time Sensitive Notifications** capability (`com.apple.developer.usernotifications.time-sensitive`); without it iOS silently downgrades the level. The comment at `:118-121` states `.timeSensitive` "needs no entitlement" — that is the one factual error in an otherwise carefully-researched file. Meanwhile the UI promises it twice: `NotificationPreferences.swift:34` ("breaks through Focus modes") and `NotificationSettingsView.swift:249`.

**Fix.** Add the entitlement and enable the capability on the target — it is granted freely for medication reminders, unlike Critical Alerts. If you'd rather not, delete the Focus claim from both strings.

---

### H6 — Three different definitions of "missed" on one screen

**`Features/Today/TodayModel.swift:236`, `TodayView.swift:469-471`, `TodayView.swift:555`, plus `MedicationDayCardView.swift:327-366`**

```swift
// card — today's overdue is NOT missed
dose.state == .logged(.missed) || (dose.state == .overdue && !dose.needsAction())
// DaySummarySheet — today's overdue IS missed
$0.state == .logged(.missed) || $0.state == .overdue
// DayCompleteCard — only explicit logs
day.doses.filter { $0.state == .logged(.missed) }
```

One dose at 08:00, 2-hour window, it is 11:00 and nothing is logged. The card sits under **"Due now"** with a red **"Missed"** chip beside live Skip/Taken buttons; the tile shows no warning badge; the header says **"1 left"**; the summary sheet says **"1 missed"**. Four contradictory statements about one pill, on one screen. For an app whose promise is honesty about adherence, this is the failure mode it set out to prevent.

**Fix.** One predicate on `DoseCalculator` — `isMissed(dose:now:window:)` — used by all four call sites. Then decide once whether "still correctable today" reads as *Late* (my recommendation, and `DoseTimingTag.late` already exists) rather than *Missed*, and make the section heading agree with the chip.

---

### H7 — A save failure on the logging screen is invisible; the toast plumbing is dead

**`Features/Today/TodayView.swift:17, 56`** vs **`Services/DoseStore.swift:331-340`**

`TodayView` declares `@State private var toast: Toast?` and attaches `.toast($toast)`, and **never assigns to it**. It also never observes `store.lastError`, which is read in exactly one place in the app (`SettingsView.swift:379`). Meanwhile `DoseStore.persist()` carries the comment:

```swift
// Surfaced, never swallowed. A silent failure in a medication app
// means someone believes they logged a dose that was never stored.
lastError = .saveFailed(error.localizedDescription)
```

On a failed `context.save()` the user still gets the success haptic, the confirmation animation and the aurora bloom. The comment promises the opposite of what the UI does.

**Fix.** Have `log`/`undoLog` report success back to the caller so the view can suppress the success feedback, and surface `store.lastError` on Today. The same swallow exists in `HistoryView.swift:134`, where a failed PDF export is reported as `Haptics.error()` and nothing else.

---

### H8 — The exported PDF can carry pre-correction numbers

**`Features/History/HistoryView.swift:86-93`**

```swift
private var reloadKey: String {
    "\(period.rawValue)-\(allEvents.count)-\(medications.count)"
}
...
.task(id: reloadKey) { reload() }
```

`DoseStore.log` updates an existing event in place (`existing.status = status`) when one is already there — no insert, no count change, so `reloadKey` is identical and `reload()` never runs.

**Repro.** Tap Taken (count +1, History reloads, ring shows 100%). Realise you actually skipped it and log Skipped — the row is mutated, the count is unchanged, History still shows 100%, and `exportSummary()` puts that stale `data.summary` straight into the PDF. The wrong number is the one that leaves the device.

**Fix.** Recompute from the `@Query` results directly, or key on a store-level change token bumped in `persist()`. At minimum, recompute inside `exportSummary()` rather than trusting cached view state.

---

### H9 — The 30-day report structurally inflates adherence

**`Services/DoseStore.swift:174`**

```swift
func recordMissedDoses(now: Date = .now, lookbackDays: Int = 7)
```

Unlogged doses only become `.missed` records if the app is opened within 7 days of them. Anything older never enters the denominator at all.

**Repro.** A patient takes doses reliably for a week, disengages for 12 days while missing most doses, then opens the app and exports a 30-day report. Those 12 days were never written, so the ring reads ~95% over "30 days" against a denominator of only the doses that happened to get recorded. **The user who disengaged — clinically the one you most want flagged — scores higher than one who engaged daily.** The chart compounds it: those days render through the `bucket.total == 0` branch as neutral grey, visually identical to "nothing was prescribed".

**Fix.** Floor the sweep at the longest report period (30 days), ideally `max(30, daysSinceLastSweep)` persisted in defaults. Separately, the report must distinguish "no doses scheduled" from "no data recorded", in the chart and in the denominator, and should decline to print a percentage for a period it cannot vouch for.

---

## 4. Medium

**M1 — The "not a medical document" disclaimer no longer ships.** `AdherenceSummary` is now referenced *only by its own tests* — nothing in the app calls it. `AdherenceSummaryTests:84` ("It states plainly that it is not a medical document") is green while guarding a string that reaches no user. The PDF's footer says only "Recorded by the patient in Daily Dose." An A4 page titled "Medication Adherence Report" with a 26pt percentage ring reads as a clinical instrument. Put the disclaimer in `ReportFooter` on every page, and either delete `AdherenceSummary` or re-wire it.

**M2 — Timing notes are sorted alphabetically, then truncated to 20.** `HistoryView.swift:112` sorts the *formatted strings*, which begin with abbreviated weekday names. In English that keeps every Friday and Monday and zero Wednesdays, and the page never says "showing 20 of 57". A doctor sees an apparently systematic weekday pattern that is a sorting artefact. Sort the `DoseEvent`s by `scheduledAt` before formatting.

**M3 — Deleted medications' doses stay in the headline but vanish from the table.** `HistoryView.swift:172` `compactMap`s per-medication rows against currently-existing `Medication` objects while `data.summary` counts every record, so the PDF's rows don't sum to its own headline with no explanation. `DoseEvent` denormalises `medicationName` specifically so this can't happen; this call site throws it away.

**M4 — `RecoveryView`'s "Start Fresh" is destructive-looking and does nothing.** In `.degraded` the container is in-memory (`AppEnvironment.swift:51-55`), so `deleteAllData()` wipes an empty scratch store and leaves the on-disk file untouched. `status` is `private(set)` and assigned only in `init`, so it can never leave `.degraded`. The user confirms "your medications and history will be cleared", and lands on the same error screen. Add `AppEnvironment.startFresh()` that removes the store file, rebuilds the container and sets `status = .ready`.

**M5 — The report and the screen colour the same percentage differently.** `DoctorReport.reportTint` uses 70/90 bands with hardcoded RGB; `Theme.adherenceColor` uses 60/90; `Summary.verdict` uses a third set (50/70/90). A medication at 64% is amber on screen and red on the printout. One ramp.

**M6 — A single dose prints a 96pt "100%" ring.** `AdherenceCalculator.percent` is gated only on `total > 0`. The visual hierarchy inverts the evidence: the largest number on the page is the least reliable thing on it. Suppress the ring below a threshold and say "not enough data yet" — the codebase already has this instinct at `AdherenceCalculator.swift:20`, it just stops one step short.

**M7 — "Adherence" counts a deliberate skip identically to a missed dose.** `taken / (taken + skipped + missed)`. A patient told to hold a diuretic on dialysis days scores 73% and gets painted red. Either define the headline as `taken / (taken + missed)` with skips reported separately, or label the ring "Doses taken as scheduled" and print the formula.

**M8 — Snooze ignores importance, sound policy and quiet hours.** `NotificationService.scheduleSnooze` hardcodes `.timeSensitive` and takes the global dose sound. Mark a vitamin **Gentle** (documented as "arrives quietly, without a sound"), snooze it, and ten minutes later it chimes at time-sensitive priority. Pass the medication's `MedicationImportance` in and derive both fields the way `makeRequest` does.

**M9 — The budget is spent exactly, leaving no headroom for snoozes.** `Budget.default` sums to exactly `systemLimit` (52 + 8 + 4 = 64) while `apply()` deliberately preserves `snooze-` requests. Two snoozed doses push the total to 66; the last two `try? await center.add` calls fail and the error is swallowed. Reserve headroom, and stop swallowing add failures — a failed add should land in `deferredMedicationIDs`.

**M10 — `.notDetermined` has no state on the notification settings screen.** Only `.denied` gets a banner. On a fresh install the screen shows a fully-configured set of reminders that will never be delivered, with no way to grant permission from there — while `SettingsView.swift:210` *does* offer exactly that button. Mirror it. Related: neither settings screen refreshes its status on `scenePhase == .active`, so both banners go stale after a round trip to iOS Settings. `TodayView.swift:62-65` already does this correctly.

**M11 — `.denied` is silent on Today.** `TodayView.swift:133` shows the nudge only for `.notDetermined`. Deny the permission and the screen looks like a healthy install forever. Add a distinct card with a route to `UIApplication.openSettingsURLString`.

**M12 — The camera priming screen is unreachable.** `ScanTabView.swift:61-66` requests access in `.task` the instant the sheet appears, so the `.undetermined` explanation ("Nothing is saved or sent anywhere") fires *behind* the system alert. A cold prompt is the single biggest cause of permanent camera denial, and denial here is one-way. Drop the auto-request; let the button do it. Also refresh on `scenePhase` — with `interactiveDismissDisabled()` on the sheet, a user who fixes permission in Settings has no path back to a working scanner.

**M13 — Deep links lose their day and never clear.** `RootView.swift:57` forwards `link.medicationID` and discards `link.scheduledAt`, which `DeepLink`'s own doc comment says exists "so the app can open on the right day". And nothing ever writes `deepLinkedMedicationID = nil`, so the accent ring stays on that card for the session — making the *next* deep link's highlight indistinguishable from the stale one.

**M14 — The day sheet resolves by medication id across two days.** `TodayView.swift:93-95` searches `model.day.cards + tomorrow.cards` with `first(where:)`, so tapping tomorrow's card for a medication that also runs today opens **today's** card. The user concludes tomorrow's doses are already taken.

**M15 — Two sheets disagree about what you can do to a dose.** `DoseDetailSheet` offers only "Mark as taken" for a skipped dose; `MedicationDaySheet` offers "Undo — back to unlogged". Skip is one tap with no confirmation, and the card's only route back is the chip → `DoseDetailSheet`. The user's visible escape from an accidental skip is to record a pill they didn't take. Also: the card header opens the whole-day sheet on Today but a single-dose sheet in the calendar — same component, two behaviours.

**M16 — Tap targets.** Calendar day cells are `minHeight: 34` with a 10pt gutter (`CalendarSheet.swift:147`), and timeline chips land around 27–30pt with `.contentShape(.capsule)` confining the hit test (`MedicationDayCardView.swift:406-419`) — despite a comment claiming they are "a comfortable fingertip target". These are the primary controls for correcting doses, used by the population most likely to have tremor. 44pt minimum.

**M17 — `cardStyle(interactive:)` accepts a parameter it ignores.** `Components.swift:163-173`. The two most-tapped surfaces in the app pass `interactive: true` and get nothing. Implement or delete.

**M18 — `appSettingsToolbar()` is the one dead symbol in `AppToolbar.swift`.** All three screens hand-roll `ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }` instead. (The button structs and `searchable(when:)` *are* used — I initially mis-scored this because the `searchable` call is split across lines; a naïve grep misses it.) Also unreferenced: `NotificationSettingsStore`, `NotificationPlanner.doseIdentifier`, `NotificationPreferences.quietHoursSummary`. `NotificationSettingsStore` is a complete parallel implementation of the persist-and-reschedule loop the view does by hand — delete it before someone extends the wrong one.

**M19 — Glyph contrast is measured against `base`, not against the colour actually drawn.** `MedicationColor.onColor` reads `relativeLuminance` of the raw swatch, while `color` adapts for dark mode and `accessibilityContrast == .high`. Applying the file's own maths to the rendered variants, **navy — the palette default — lands at ~2.49:1 in high-contrast dark mode**, below the 3:1 non-text minimum, in the exact setting a low-vision user enabled to get more contrast. Make `onColor` trait-aware and extend the test to all four trait combinations. *(Ratios computed from the file's own formula; worth re-deriving before you act on the exact numbers.)*

**M20 — `existingEvent`'s ±60s window is inclusive on both ends.** `DoseStore.swift:152-164`. A `Set<TimeOfDay>` guarantees distinct *minutes*, i.e. exactly 60s minimum separation — which this range includes. A schedule with 08:00 and 08:01 (the editor permits it) will have one log overwrite the other. `LoggedEventIndex.minuteKey` keeps them distinct, so read and write disagree. Make the window exclusive, or match on the same `minuteKey`.

**M21 — Two toggles share the VoiceOver label "Show notifications".** `NotificationSettingsView.swift:77` and `:160`. Section headers are not part of a control's label; a VoiceOver user hears the same phrase twice and turning off the wrong one silences every dose reminder.

**M22 — Future days in the week strip look like fully-missed days.** `WeekStrip.swift:21` draws an empty ring and announces "0 of 3 doses taken" for a day that hasn't happened, while `CalendarSheet.swift:130` correctly dims and zeroes future days. Two surfaces, contradictory.

**M23 — `onChange(of: medications)` won't fire on an edit.** `TodayView.swift:65`. `[Medication]` equality is by persistent identity, so changing a schedule produces an equal array. It self-heals within 60s via the ticker, but for that minute Today shows a time the store no longer holds and a tap logs against the old `scheduledAt` — creating a `DoseEvent` no future dose will ever match. Observe a derived key or a store revision counter. Same class of staleness on Meds, where `nextDoses` recomputes only when the medication *set* changes (`MedicationsView.swift:126`).

**M24 — Export runs on the main actor over an unbounded query, with no progress and no re-entrancy guard.** `HistoryView.swift:16` materialises every `DoseEvent` ever recorded (two years at 4/day ≈ 2,900 objects) just to draw a 7-day chart, and `reloadKey` reads `allEvents.count` on every render. Tapping share then blocks the UI for two A4 renders plus a disk write with zero feedback; tapping twice writes two files to the same URL.

**M25 — Temp PDFs are never deleted, and the filename omits the period.** `DoctorReport.swift:79-82`. Export Week then Month on the same day and both resolve to `Medication-Report-2026-08-17.pdf` — the second overwrites the first while an in-flight AirDrop may still hold that URL. `HistoryShareSheet` has no `completionWithItemsHandler`, so nothing is cleaned up on share or cancel. Note the text export this replaced got it right: `daily-dose-adherence-30d-….txt`.

**M26 — The report is half-localized and bidi-hostile.** `HistoryView.swift:156` builds the timing note by raw interpolation with untranslated English ("scheduled", "taken", hand-built "h"/"min"), and `DoctorReport.swift:90-94` concatenates two dates around a bare en-dash outside any localization call — which renders in reversed order in RTL. `String(localized: "of \(total) scheduled doses")` has no plural variants, so N=1 prints "of 1 scheduled doses".

**M27 — The PDF chart encodes everything in hue.** `barHeight` returns 4pt for "nothing scheduled" and ≥6pt for "all missed", with the difference carried by grey-at-18% vs red-at-55%. Printed on a monochrome office laser — the normal fate of a doctor report — those are the same mark. There is also no legend and no axis.

**M28 — The PDF flip is a double negative with a hardcoded constant.** `DoctorReport.swift:68` translates by `pageSize.height` and discards the size `ImageRenderer.render` hands back. It is right today only because content height happens to equal page height; the moment that stops being true (Letter, a continuation page, the overflow in H1) the page shifts vertically rather than obviously inverting — a much harder bug to spot. Use the callback's `size`, or render straight into `CGContext(url:mediaBox:)` and delete the transform.

**M29 — Still outstanding from AUDIT-2.** The demo seed is not `#if DEBUG` (it is launch-argument-guarded, which is *mostly* safe); `let course = store.add(…)` in `seedDemoDataIfRequested` is still unused; `DayCompleteCard`'s `.symbolEffect(.bounce)` has no Reduce Motion guard while every other animation in that file does; the day summary sheet is unreachable for any day but today; Today has no navigation title while the other two tabs have large ones.

---

## 5. The test suite

The suite is 12 files and materially better than it was — `MedicationColorTests` names the tautology it replaced, `BackupTests.importIsIdempotent` asserts counters *and* row counts, and `DoseTimingTagTests` uses literal clock times at the boundaries. But several tests currently guarantee less than they appear to.

**Tests that cannot fail:**

- **The three "never exceeds 64" assertions.** `NotificationPlannerTests:85` and `:104` build 10 and 30 medications that all share dose times — bundling collapses them to 12 and **2** notifications respectively, then asserts `<= 64` and `<= 20`. `NotificationPreferencesTests:334` is the same shape. The headline invariant of the whole planner is guarded by three assertions that would pass if the budget accounting were deleted. Fix: assert `Budget.default.total <= systemLimit` directly, and rebuild the saturation test with *distinct* times per medication so the ceiling is actually reached.
- **`dueGrace` / `missWindow` boundaries** (`DoseCalculatorTests:16`) derive their inputs from the same constants the implementation uses. Change `dueGrace` from 15 minutes to 15 seconds and both still pass. Use literals, as `DoseTimingTagTests` does.
- **The V2→V3 assertions** (`MigrationTests:140-142`) read back the exact literals declared as defaults on the live `Medication`. They pass whether or not the store migrated.
- **`verdictReflectsAdherence`** (`AdherenceTests:132`) asserts only that two strings differ. Invert the bands entirely and it passes.
- **The sound test** (`NotificationPreferencesTests:360`) comments that "a typo here is silent at runtime", then recomputes the filename the same way the implementation does. Assert `Bundle.main.url(forResource:withExtension:) != nil` instead — that is the risk it names.
- **"Fall-back does not duplicate"** (`DoseScheduleTests:159`) asserts a count of 1, which is structural given `occurrences` walks one day and resolves each time once. The interesting question — *which* of the two ambiguous instants is chosen, and whether it matches the one a logged event was recorded at — is not asked.
- **The interval DST test** (`DoseScheduleTests:72`) picks the autumn fall-back transition, the direction a naive seconds-based day count survives. The implementation is correct (it uses `dateComponents([.day],…)`), so this isn't a live bug — but the test would not catch a regression to seconds. Move it to the March transition, or keep both.

**Flakiness:** `DayPlanCardsTests:21` builds fixtures by adding absolute hours to `startOfDay(.now)` and asserts by wall-clock hour, so it goes red on 29 March and 25 October for reasons unrelated to any code change. `TestSupport.swift:30` force-unwraps in `Fixture.date`/`time`/`calendar`, so one bad date traps the whole process rather than failing one test — exactly when you're adding DST coverage. `DeleteAllDataTests:46` waits on a 100 ms sleep rather than a signal.

**Highest-value missing tests, ranked by user harm:**

1. **Timezone change.** Schedule + logs created in `Europe/Berlin`; re-run `unloggedOverdueDoses` under `America/Los_Angeles`. Today, schedules are re-resolved in `Calendar.current` while logs are matched by absolute minute — I believe a user who flies from Berlin to LA gets a week of fabricated `.missed` rows over doses they actually took. I have not run this, so it is *unverified* — but it is the first test I would write, and if it fails it is a data-integrity blocker.
2. **Migration with adversarial V1 data.** 3 medications × 5 events, one orphaned event (`medication == nil` survives the `willMigrate` delete loop and lands with `medicationID = ""`), one row with an explicit `startDate`, one with `weekdays: []` (which becomes a `.weekdays` schedule that can never occur, silently). `willMigrate` **deletes every row before `didMigrate` re-inserts** — the current test would not see a defect in that handoff, and the blast radius is total data loss on update.
3. **Crash-safety of that same handoff.** `LegacyCarry` is in-memory only. If the process dies between `willMigrate`'s `save()` and `didMigrate`, the rows are gone and the snapshots with them. Consider writing the snapshots to a JSON sidecar before deleting, and removing it only after `didMigrate` succeeds. (`LegacyCarry.shared` is also a process-global, so parallel test suites can drain each other's snapshots.)
4. **Re-opening an already-migrated store** twice through the plan — counts unchanged, no duplicates. This is what happens on every launch after the update.
5. **`DoseStore.log` supply arithmetic.** taken → skipped → taken must consume exactly one pill; `undoLog` returns it. This is a documented, previously-shipped bug with zero regression coverage.
6. **`delete(medication)` keeps history.** The app says so in its own copy; the promise rests on a `deleteRule` nothing asserts.
7. **A saturating notification plan** at distinct times: `count <= 64`, every unplanned medication in `deferredMedicationIDs`.
8. **`resolveScheduledAt`** (H4) — early tap, stale-banner tap, DST-gap dose.
9. **Hostile backup import.** `restore` coerces rather than rejects: an unknown `scheduleKind` becomes `.daily` (a weekly methotrexate turning into daily dosing), an unknown status becomes `.taken` (inflated adherence on a document shown to a doctor). `BackupError.unreadable` is declared and never thrown. Add a rejected-record count to `ImportSummary` so partial imports are visible.
10. **`NotificationService.apply`** against a fake centre — the "opening the app cancelled the user's snooze" fix has no regression test.

---

## 6. Ship checklist (unchanged from AUDIT-2, still open)

- Privacy policy URL is still the placeholder `dailydose.app/privacy`.
- Time Sensitive Notifications capability (H5).
- `TARGETED_DEVICE_FAMILY = "1,2"` with no iPad layout — either build one or drop to iPhone.
- Swift 6 language mode not yet enabled.
- No localization catalog, and several strings bypass `String(localized:)` entirely (M26).

---

## 7. What I could not verify

- **The tree does not compile here** — there is no Swift toolchain in this environment, so nothing below is a compile check. Every finding is a source reading.
- **The test suite has not been run.** Where I say a test "cannot fail", that is derived from reading the assertion against the implementation, not from mutating the code and watching it stay green.
- **The five `.wav` files** are present on disk at `DailyDose/Resources/Sounds/` and their names match `NotificationSound.rawValue` exactly. Because the target uses a synchronized folder group, they should flatten to the bundle root and resolve — but I could not confirm that from a build. Worth one manual check, since `SoundPreviewPlayer.play` returns silently on a nil URL with no feedback at all.
- **M19's contrast ratios** were computed from the formula in `MedicationColor.swift` applied to the trait-adapted values; re-derive them before acting on the exact figures. The structural point — that `onColor` is computed from a colour that is not the one drawn — is certain.
