# Daily Dose — Settings: Review & Proposed Design

**Date:** 12 August 2026 · **Reviewing:** the Settings screen as it stands on disk

---

## 1. The principle I'm designing against

Settings is not a feature list. It's where someone goes when **the app is behaving in a way they want to change** — and for this app specifically, the people arriving there are often older, often managing something serious, and often mildly anxious about getting it wrong.

That gives three rules:

1. **Every option is a decision, and decisions cost something.** A setting that 5% of people will ever touch makes the screen worse for the other 95%.
2. **Show the current value inline.** Nobody should have to tap a row to find out what it's set to.
3. **The most consequential things go first; the irreversible thing goes last, alone.**

The best benchmark isn't a competitor. It's Apple Health's own Medications settings, which is remarkably small — and Medisafe's, which is bloated and worse for it.

---

## 2. What's wrong with the current screen

It's in decent shape. Five real problems:

| # | Problem | Severity |
|---|---|---|
| 1 | **No privacy policy link.** Required for App Store submission, doubly so for a health app. | 🔴 Blocker |
| 2 | **No support or feedback path.** People using a medication app will have questions, and App Review looks for this. | 🟠 High |
| 3 | **Backup is a two-step dance.** "Create backup" makes a file, then a *second* row appears to share it. One action, one row. | 🟠 High |
| 4 | **The medical disclaimer is buried in a footer.** It's the right words in a place nobody reads. | 🟡 Medium |
| 5 | **The "why we exist" manifesto sits inline as a block of body text.** It's good writing in the wrong shape — it makes About the visually heaviest section on the screen. | 🟡 Medium |

And one thing that isn't in Settings but should be:

**Apple Health import is a permanent card at the top of the Meds tab.** It's a one-time setup action occupying permanent space on a primary screen. It belongs in Settings, with a first-run prompt on Meds only while the library is empty.

---

## 3. Proposed structure

```
Settings                                              Close

┌──────────────────────────────────────────────────────────┐
│  ⚠️  Reminders are off in iOS Settings              ›     │   ← only when
│      Nothing below can reach you                          │     something
└──────────────────────────────────────────────────────────┘     is wrong

  REMINDERS
  🔔  Notifications                                   On  ›

  TRACKING
  ⏱   Dose window                                2 hours  ›
  ❤️   Apple Health                            Connected  ›

  YOUR DATA
  📄  Adherence report                                    ›
  ⬇️   Back up                                             ›
  ⬆️   Restore from a backup                               ›
      Your data stays on this device — no account, no
      server. A backup contains everything, and restoring
      never overwrites what you already have.

  ABOUT
  📖  How Daily Dose works                                ›
  🛡   Privacy Policy                                      ›
  ✉️   Help & Feedback                                     ›
      Version                                     1.0 (1)
      Daily Dose is not a medical device and does not give
      medical advice — always follow your prescriber.

  ┌────────────────────────────────────────────────────┐
  │              Delete All Data                       │
  └────────────────────────────────────────────────────┘
```

Five sections, none longer than three rows. Fits one screen on most phones without scrolling.

### Why this order

- **Reminders first** — the app's core promise and by far the most-visited setting.
- **Tracking second** — how the app *interprets* your behaviour. Second most consequential, and currently invisible.
- **Your Data third** — periodic actions, not daily ones.
- **About fourth** — rarely opened, but must exist.
- **Delete last, isolated** — the standard destructive position, separated by whitespace so it can't be hit by accident.

---

## 4. Row-by-row rationale

### 🔴 Alert banner (conditional, top)

Any "something is wrong" state gets **one** banner at the very top, not a section buried mid-list. Two conditions:

- Notifications denied in iOS Settings → tap opens Settings
- Reminders at capacity (the 64-request ceiling) → tap explains which medications are affected

Right now the capacity warning is an ordinary section sitting between Notifications and Backup, where it reads as informational. It isn't — it means someone is not being reminded.

### ⏱ Dose window — **the strongest new candidate**

`DoseCalculator.missWindow` is currently hardcoded at **2 hours**. That constant decides when an unlogged dose flips from "Late" to "Missed", which means **it silently defines the user's adherence percentage** — the single number the History tab is built around.

Two hours is right for some people and wrong for others. Someone on a strict cardiac regimen wants a tight window. Someone taking a vitamin whenever they get to it does not want a red "Missed" every afternoon.

```
Dose window                                          2 hours ›
  ├─ 1 hour      Strict — good for time-critical medication
  ├─ 2 hours     Balanced (default)
  ├─ 4 hours     Relaxed
  └─ Until end of day
      A dose still unlogged after this counts as missed in
      your history.
```

This is the one hardcoded value where different people genuinely need different answers, and where the current default quietly makes a claim about their behaviour.

### ❤️ Apple Health

Move it here from the Meds tab. Show state inline — `Connected` / `Not connected` / `Requires iOS 26`. Keep a first-run prompt on Meds **only while the library is empty**, because that's the one moment it's genuinely useful.

### 📄 Adherence report

The wedge feature from both audits, and now with evidence behind it: the trial that showed a real adherence effect had **visible adherence feedback** as a core component. A one-tap PDF — 30/60/90 days, per medication, with a missed-dose calendar — is what turns this from a pill reminder into the thing someone brings to their cardiologist.

Put the row here *and* a share button on History. Settings is where people look for "export"; History is where they're already looking at the data.

### ⬇️⬆️ Back up / Restore

Collapse the two-step. **One row → generate → share sheet.** The intermediate "Share backup file" row is an implementation detail leaking into the UI.

### 📖 How Daily Dose works

Move the manifesto here, out of the main list. It's good writing — "medication reminders are healthcare, not a subscription" — but as an inline block it makes About the heaviest thing on screen. As a short page it becomes something people *choose* to read, which is the only way anyone reads it.

Put the medical disclaimer on that same page, prominently, and keep the one-line version in the footer.

### 🛡 Privacy Policy · ✉️ Help & Feedback

Non-negotiable for submission. Feedback can be a `mailto:` with the version and device model pre-filled in the body — it costs nothing and turns vague bug reports into useful ones.

---

## 5. What I'd deliberately leave out

This list matters more than the one above. Each of these is a plausible-sounding setting that would make the app worse.

| Not adding | Why |
|---|---|
| **Light / Dark / System theme** | Follow the system. Adding an override creates a permanent three-way test matrix for zero benefit. Apple's own apps don't offer it. |
| **Text size, language, 12/24-hour, week start** | All system-derived. Duplicating iOS settings is how a settings screen doubles in size while getting less useful. |
| **Analytics opt-out** | There is no analytics. Offering the toggle *implies* there is, which actively damages the privacy positioning. |
| **"Confirm before logging"** | Sounds safe. It doubles the taps on the single most important action in the app, and the adherence evidence says friction on logging is exactly what kills these apps. Undo already exists. |
| **History retention limit** | Nobody wants their medication history auto-deleted, and the setting invites a mistake that can't be undone. |
| **Default reminder times for new medications** | Saves a couple of taps for the rare person adding many medications at once. Not worth a permanent row. |
| **App icon picker** | Pure delight, no utility. WhatsApp charges for it; we'd be adding a decision. Defer indefinitely. |
| **Premium / upgrade** | Contradicts "free forever", which is the app's entire positioning. |
| **Sound at the top level** | Already lives inside Notifications, where it belongs. |

Two that are genuinely valuable but are **features, not settings** — when they exist, they get a row at the top of Your Data:

- **iCloud sync** — the most-requested thing in this category
- **Caregiver sharing** — the feature Medisafe just put behind a paywall

---

## 6. Design details

**Values inline, always.** `Notifications  On ›`, `Dose window  2 hours ›`, `Apple Health  Connected ›`. Never make someone tap to discover state.

**Footers explain consequences, not features.** "A dose still unlogged after this counts as missed in your history" beats "Choose how long a dose stays actionable."

**No Save button.** Every change persists and reschedules immediately — the platform convention, and already how `NotificationSettingsView` behaves.

**Destructive is isolated.** `Delete All Data` in its own section with whitespace above, red, behind a confirmation that names what's lost and points at Backup first.

**Sheet or push?** Settings is currently a sheet from Today's toolbar, with `NavigationStack` inside — that works and matches Apple Health's profile pane. Keep it. But make sure the Close button is always reachable from nested screens.

**Accessibility.** Every row a real `Button` or `NavigationLink` (already true). Inline values must be part of the row's accessibility label, not a separate element — `"Dose window, 2 hours, button"`, not two nodes.

---

## 7. Suggested build order

**First — the blockers**
1. Privacy Policy row (+ a hosted page, which is the real work)
2. Help & Feedback (`mailto:` with version and device pre-filled)
3. Collapse backup into one row

**Second — the real gap**
4. Dose window setting, threaded through `DoseCalculator` (it's currently a `static let`, so this touches the domain layer and needs tests)
5. Alert banner for denied notifications + capacity, replacing the inline section
6. Move Apple Health into Settings; first-run prompt on Meds only

**Third — the wedge**
7. Adherence report (PDF), in Settings and on History
8. "How Daily Dose works" page, with the disclaimer given proper space

---

## 8. One honest caveat

The dose-window setting is the only item here that changes **domain logic** rather than presentation. `DoseCalculator.missWindow` is a `static let` consulted in three places, and turning it into a per-user value means threading it through `DoseCalculator`, `DoseStore`, and the missed-dose sweep — plus tests, because "when does a dose become missed" is exactly the kind of rule that has already caused one data-integrity bug in this app.

It's worth doing. It just isn't a settings row; it's a small feature.
