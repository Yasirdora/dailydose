# Daily Dose — Notification Design

**Date:** 12 August 2026
**Status:** implemented · 30 new tests · 108 total

---

## 1. What the evidence actually says

I went looking for research on whether medication reminders work. The answer is uncomfortable and it changed the design.

### Reminders alone do essentially nothing

The **REMIND trial** ([JAMA Internal Medicine](https://jamanetwork.com/journals/jamainternalmedicine/fullarticle/2605527)) randomised ~53,000 patients across three reminder devices — a pill-bottle toggle strip, a digital timer cap, and a weekly pillbox. Result:

| Group | Optimal adherence (≥80%) |
|---|---|
| Control | 15.1% |
| Pillbox | 15.5% |
| Timer cap | 15.1% |
| Toggle strip | 16.3% |

**No statistically significant difference.** The authors' explanation: the primary barriers were "gaps in knowledge or motivation", not forgetting. There's a sharper detail buried in the subgroups — the timer cap helped people who were *already* adherent (OR 1.07) and slightly *hurt* those who weren't (OR 0.96).

### Reminders plus logging plus feedback do work

A later [RCT of a reminder app](https://pmc.ncbi.nlm.nih.gov/articles/PMC11026187/) found a real effect — Cohen's d = −0.52, with 43% of app users showing reliable adherence improvement versus 10% of controls. The difference from REMIND wasn't the reminder. It was that the app also had **one-tap logging, adherence statistics, and medication information**.

> **The conclusion that drove this work:** a notification's value is in the *action attached to it*, not the ping. A reminder you can't act on from the Lock Screen is close to worthless, and it still spends the same attention.

There's one more finding worth recording: in that same trial, the caregiver feature ("Medfriend") was set up by **exactly one participant out of 30**. Opt-in social features that live behind a settings screen do not get adopted.

### The ceiling is Time Sensitive, not Critical

Apple's **Critical Alerts** entitlement — which overrides both the mute switch *and* Focus — is granted for glucose monitors, patient monitoring, and medications "where missed alerts pose clinical risks". A general-purpose reminder app [would likely not qualify](https://newly.app/articles/critical-alerts-entitlement).

**Time Sensitive** breaks through Focus, respects the ringer switch, and needs no entitlement. That's our ceiling, and the app now says so in plain language rather than implying otherwise.

For reference, Apple Health's own behaviour: follow-up at exactly **30 minutes**, not configurable, on/off only — plus per-medication Critical Alerts, which they can do because it's their entitlement.

---

## 2. The problem in the code

Auditing against that, one thing stood out that I'd under-rated in the last review:

**The planner emitted one notification per medication per dose time.** Three medications at 08:00 produced three separate alerts arriving in the same second. That is simultaneously a budget waste (three of the 64 slots for one moment) and the single most reliable way to train someone to clear a notification stack without reading it — which then breaks the alert that mattered.

There was also **no user control of any kind**. The app decided everything: follow-ups always on, 30-minute delay fixed, refills at 09:00, every medication equally urgent, no concept of night.

---

## 3. What changed

### Bundling — the biggest single reduction

Medications sharing a dose time now collapse into **one** notification.

| Setup | Before | After |
|---|---|---|
| 3 meds at 08:00 | 3 alerts | **1** |
| 10 meds × 4 shared times | 40 alerts | **4** |

A bundled alert deliberately carries **no** Taken/Skip buttons — "Taken" is ambiguous across three medications, and a wrong one-tap log is worse than opening the app. It opens Today instead, where the stacked dose card already puts logging one tap away. A **single** medication keeps its inline actions, because that's the case where one-tap logging is the active ingredient.

Bundling is a toggle. Turning it off restores per-medication actionable alerts — more taps saved, more noise. The trade-off is stated in the footer rather than hidden.

### Three importance levels, per medication

| Level | Sound | Breaks Focus | Follow-up | For |
|---|---|---|---|---|
| **Gentle** | No | No | Never | Vitamins, supplements |
| **Standard** | Yes | Yes | Yes | The default |
| **Important** | Yes | Yes | Even in quiet hours | Where a missed dose matters |

Bundling never mixes levels — a gentle vitamin can't be folded into a standard medication's alert, in either direction.

### Quiet hours, with a deliberate asymmetry

Overnight, the app stops escalating. But the distinction that matters:

> **Scheduled dose reminders still arrive. The user chose those times.**
> Quiet hours only hold back what the *app* decided to send — follow-ups and refill alerts.

A 3 a.m. "you didn't log your 2:30 dose" is the notification that gets an entire app muted at the OS level. A 2:30 a.m. dose reminder is a thing the user explicitly asked for, and suppressing it would break the core promise.

Default 22:00 – 07:00. `Important` medications override it.

### Escalation is bounded

One follow-up. It never chains. It's togglable, the delay is configurable (10/15/30/60 — Apple Health fixes it at 30), and gentle medications never get one at all.

### Everything is honest

- Refill alerts are `.gentle` — supply is never urgent enough to interrupt
- The importance guide says outright: *"all of them respect your phone's silent switch. Daily Dose can't override it."*
- Bundled alerts use a `threadIdentifier` so they collapse in Notification Centre

---

## 4. The settings screen

WhatsApp's grammar — one grouped section per kind of alert, each with its own switch and detail rows, current values shown inline:

```
Notifications
├── Dose reminders
│   ├── Show notifications              ●━━
│   └── Group by time                   ●━━
│       "One alert for everything due at once"
├── Follow-up
│   ├── Remind me again                 ●━━
│   └── After                    30 minutes ›
├── Quiet hours
│   ├── Quiet hours                     ●━━
│   ├── From                          22:00
│   └── To                            07:00
├── Refill alerts
│   ├── Show notifications              ●━━
│   └── Time                          09:00
└── Per-medication importance             ›
```

The organising principle, and the reason the screen exists at all: **a person should be able to silence the part that's bothering them without silencing the part that's keeping them alive.** A single global switch forces that choice, and people resolve it by disabling notifications at the OS level — the outcome this screen exists to prevent.

Per-medication importance lives on each medication's own page, where the context is.

---

## 5. Tests

30 new, 108 total. The ones that matter:

- Overnight quiet windows wrap past midnight correctly — the case a naive `start...end` range gets exactly backwards, and the only window anyone configures
- A zero-length window means *off*, not *always quiet*
- Three medications at one time → one bundled alert; a lone medication keeps its buttons
- Gentle and standard are never bundled together
- Quiet hours suppress a nocturnal follow-up — and **don't** suppress the scheduled dose
- `Important` overrides quiet hours
- Bundling cuts 10 meds × 4 times from 40 alerts to 4
- Every prior invariant still holds: system limit, unique ASCII identifiers, determinism

Two existing tests were rewritten rather than deleted: they asserted un-bundled behaviour and would now pass for the wrong reason.

---

## 6. What I deliberately did not build

- **Critical Alerts.** We wouldn't get the entitlement, and shipping UI that implies we can shout through a silenced phone would be a lie.
- **Escalating chains.** No evidence supports them and every mechanism suggests they backfire.
- **Snooze-until-taken loops.** Same reason.
- **A caregiver notification feature.** One participant in thirty adopted it in the trial. If it's built, it needs to be surfaced during onboarding, not buried in settings — that's a product decision, not a notification one.

---

## 7. Still open

Unchanged, and now more valuable given the evidence that *feedback* is the active ingredient:

- **The PDF adherence report.** The trial that showed a real effect had adherence statistics as a core component. `AdherenceCalculator` already produces everything needed.
- The migration blocker from `AUDIT-2.md` §3 — still the thing that must be fixed before shipping.
- Time-sensitive entitlement, iPad decision, privacy policy, Swift 6.

---

## Sources

- [Effect of Reminder Devices on Medication Adherence: The REMIND Randomized Clinical Trial — JAMA Internal Medicine](https://jamanetwork.com/journals/jamainternalmedicine/fullarticle/2605527)
- [Effects of a medication adherence app among medically underserved adults with chronic illness: a randomized controlled trial](https://pmc.ncbi.nlm.nih.gov/articles/PMC11026187/)
- [How to Get the Apple Critical Alerts Entitlement](https://newly.app/articles/critical-alerts-entitlement)
- [How to set up follow-up medication reminders in iOS 17 — AppleInsider](https://appleinsider.com/inside/ios-17/tips/how-to-set-up-follow-up-medication-reminders-in-ios-17)
- [Send communication and Time Sensitive notifications — WWDC21](https://developer.apple.com/videos/play/wwdc2021/10091/)
