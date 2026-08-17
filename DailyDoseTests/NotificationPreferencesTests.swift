import Foundation
import Testing
@testable import DailyDose

@Suite("Quiet hours")
struct QuietHoursTests {

    let calendar = Fixture.calendar()

    private func preferences(from: TimeOfDay, to: TimeOfDay) -> NotificationPreferences {
        var p = NotificationPreferences.default
        p.quietHoursEnabled = true
        p.quietHoursStart = from
        p.quietHoursEnd = to
        return p
    }

    @Test("An overnight window spans midnight correctly")
    func overnightWindowWraps() {
        // The case a naive `start...end` range gets exactly backwards — and it's
        // the only window anyone actually configures.
        let p = preferences(from: Fixture.time(22), to: Fixture.time(7))

        #expect(p.isQuiet(Fixture.date(2026, 8, 12, 23, 30), calendar: calendar))
        #expect(p.isQuiet(Fixture.date(2026, 8, 12, 3, 0), calendar: calendar))
        #expect(p.isQuiet(Fixture.date(2026, 8, 12, 22, 0), calendar: calendar), "start is inclusive")

        #expect(p.isQuiet(Fixture.date(2026, 8, 12, 7, 0), calendar: calendar) == false, "end is exclusive")
        #expect(p.isQuiet(Fixture.date(2026, 8, 12, 12, 0), calendar: calendar) == false)
        #expect(p.isQuiet(Fixture.date(2026, 8, 12, 21, 59), calendar: calendar) == false)
    }

    @Test("A same-day window does not wrap")
    func sameDayWindow() {
        let p = preferences(from: Fixture.time(13), to: Fixture.time(15))
        #expect(p.isQuiet(Fixture.date(2026, 8, 12, 14, 0), calendar: calendar))
        #expect(p.isQuiet(Fixture.date(2026, 8, 12, 2, 0), calendar: calendar) == false)
    }

    @Test("A zero-length window means off, not always-quiet")
    func zeroLengthWindowIsOff() {
        let p = preferences(from: Fixture.time(22), to: Fixture.time(22))
        #expect(p.isQuiet(Fixture.date(2026, 8, 12, 22, 0), calendar: calendar) == false)
        #expect(p.isQuiet(Fixture.date(2026, 8, 12, 3, 0), calendar: calendar) == false)
    }

    @Test("Disabled quiet hours are never quiet")
    func disabledIsNeverQuiet() {
        var p = preferences(from: Fixture.time(22), to: Fixture.time(7))
        p.quietHoursEnabled = false
        #expect(p.isQuiet(Fixture.date(2026, 8, 12, 3, 0), calendar: calendar) == false)
    }

    @Test("Preferences survive a save and load")
    func persistenceRoundTrip() {
        let defaults = UserDefaults(suiteName: "quiet-hours-test-\(UUID().uuidString)")!
        var p = NotificationPreferences.default
        p.followUpEnabled = false
        p.followUpDelay = .sixty
        p.bundleSimultaneousDoses = false
        p.quietHoursStart = Fixture.time(23, 15)

        p.save(to: defaults)
        #expect(NotificationPreferences.load(from: defaults) == p)
    }
}

@Suite("Notification volume and importance")
struct NotificationVolumeTests {

    let calendar = Fixture.calendar()
    let now = Fixture.date(2026, 8, 12, 7)

    private func plan(
        _ medications: [MedicationSnapshot],
        preferences: NotificationPreferences = .default,
        budget: NotificationPlanner.Budget = .default,
        events: LoggedEventIndex = .empty
    ) -> NotificationPlanner.Plan {
        NotificationPlanner.plan(
            medications: medications, events: events, now: now,
            preferences: preferences, budget: budget, calendar: calendar
        )
    }

    private func doses(_ plan: NotificationPlanner.Plan) -> [NotificationPlanner.PlannedNotification] {
        plan.notifications.filter {
            switch $0.category {
            case .dose, .doseBundle: true
            default: false
            }
        }
    }

    private func medication(
        _ id: String,
        times: Set<TimeOfDay>,
        importance: MedicationImportance = .standard
    ) -> MedicationSnapshot {
        MedicationSnapshot(
            id: id, name: "Med \(id)", doseDetail: "", notes: "",
            colorName: MedicationColor.navy.rawValue, isActive: true,
            schedule: Fixture.schedule(kind: .daily, times: times, start: Fixture.date(2026, 8, 1)),
            pillsRemaining: nil, refillThreshold: nil, importance: importance
        )
    }

    // MARK: - Bundling

    @Test("Three medications at the same time become one notification")
    func simultaneousDosesBundle() {
        // The pile-up that trains people to clear the whole stack without
        // reading it: three separate alerts arriving in the same second.
        let meds = ["a", "b", "c"].map { medication($0, times: [Fixture.time(8)]) }
        let result = doses(plan(meds))

        #expect(result.count == 1, "One moment, one alert")
        guard case .doseBundle(let ids, let time) = result[0].category else {
            Issue.record("Expected a bundle, got \(result[0].category)")
            return
        }
        #expect(ids.sorted() == ["a", "b", "c"])
        #expect(time == Fixture.time(8))
    }

    @Test("A bundle carries no inline actions")
    func bundlesDoNotCarryActions() {
        // "Taken" is ambiguous across three medications, and a wrong one-tap
        // log is worse than opening the app.
        let meds = ["a", "b"].map { medication($0, times: [Fixture.time(8)]) }
        #expect(doses(plan(meds))[0].carriesActions == false)
    }

    @Test("A lone medication keeps its one-tap actions")
    func singleDoseKeepsActions() {
        // The active ingredient, per the adherence trials: reminder plus
        // frictionless logging. Never lose it for the common case.
        let result = doses(plan([medication("a", times: [Fixture.time(8)])]))
        #expect(result.count == 1)
        #expect(result[0].carriesActions)
        if case .dose = result[0].category {} else {
            Issue.record("A single medication must not be bundled")
        }
    }

    @Test("Bundling can be switched off, restoring per-medication alerts")
    func bundlingCanBeDisabled() {
        var preferences = NotificationPreferences.default
        preferences.bundleSimultaneousDoses = false
        let meds = ["a", "b", "c"].map { medication($0, times: [Fixture.time(8)]) }
        let result = doses(plan(meds, preferences: preferences))

        #expect(result.count == 3)
        // A loop, not `allSatisfy`: rethrows calls trip #expect's expansion.
        var allCarryActions = true
        for dose in result where !dose.carriesActions { allCarryActions = false }
        #expect(allCarryActions)
    }

    @Test("Different times are never bundled together")
    func differentTimesStaySeparate() {
        let meds = [
            medication("a", times: [Fixture.time(8)]),
            medication("b", times: [Fixture.time(20)]),
        ]
        #expect(doses(plan(meds)).count == 2)
    }

    @Test("A gentle medication is never folded into a standard one")
    func importanceIsNotMixedInABundle() {
        // Otherwise a vitamin inherits a heart medication's urgency, or worse,
        // the heart medication inherits the vitamin's silence.
        let meds = [
            medication("vitamin", times: [Fixture.time(8)], importance: .gentle),
            medication("heart", times: [Fixture.time(8)], importance: .standard),
        ]
        let result = doses(plan(meds))

        #expect(result.count == 2, "Different urgencies cannot share one alert")
        #expect(Set(result.map(\.importance)) == [.gentle, .standard])
    }

    @Test("Bundling cuts the notification budget dramatically")
    func bundlingReducesBudgetPressure() {
        // Ten medications, four doses a day, all on the same four times.
        let times: Set<TimeOfDay> = [Fixture.time(8), Fixture.time(12), Fixture.time(16), Fixture.time(20)]
        let meds = (0..<10).map { medication("med-\($0)", times: times) }

        var bundled = NotificationPreferences.default
        bundled.bundleSimultaneousDoses = true
        var unbundled = NotificationPreferences.default
        unbundled.bundleSimultaneousDoses = false

        #expect(doses(plan(meds, preferences: bundled)).count == 4, "Four moments in the day, four alerts")
        #expect(doses(plan(meds, preferences: unbundled)).count > 4)
    }

    // MARK: - Importance

    @Test("Gentle medications never sound and never break through Focus")
    func gentleIsPassive() {
        #expect(MedicationImportance.gentle.playsSound == false)
        #expect(MedicationImportance.gentle.breaksThroughFocus == false)
        #expect(MedicationImportance.standard.breaksThroughFocus)
        #expect(MedicationImportance.important.breaksThroughFocus)
    }

    @Test("A gentle medication gets no follow-up")
    func gentleGetsNoFollowUp() {
        let meds = [medication("vitamin", times: [Fixture.time(8)], importance: .gentle)]
        let followUps = plan(meds).notifications.filter {
            if case .followUp = $0.category { return true }
            return false
        }
        #expect(followUps.isEmpty, "A supplement does not deserve a second alert")
    }

    // MARK: - Follow-ups and quiet hours

    @Test("Follow-ups can be switched off entirely")
    func followUpsCanBeDisabled() {
        var preferences = NotificationPreferences.default
        preferences.followUpEnabled = false
        let followUps = plan([medication("a", times: [Fixture.time(8)])], preferences: preferences)
            .notifications.filter {
                if case .followUp = $0.category { return true }
                return false
            }
        #expect(followUps.isEmpty)
    }

    @Test("The follow-up delay is honoured")
    func followUpDelayIsConfigurable() {
        var preferences = NotificationPreferences.default
        preferences.followUpDelay = .ten
        let followUps = plan([medication("a", times: [Fixture.time(8)])], preferences: preferences)
            .notifications.filter {
                if case .followUp = $0.category { return true }
                return false
            }
        #expect(followUps.first?.nextFireDate == Fixture.date(2026, 8, 12, 8, 10))
    }

    @Test("Quiet hours suppress a follow-up that would land overnight")
    func quietHoursSuppressNocturnalFollowUps() {
        // A 3 a.m. "you didn't log your 2:30 dose" is the notification that
        // gets an entire app muted.
        var preferences = NotificationPreferences.default
        preferences.quietHoursEnabled = true
        preferences.quietHoursStart = Fixture.time(22)
        preferences.quietHoursEnd = Fixture.time(7)

        let meds = [medication("a", times: [Fixture.time(2, 30)])]
        let followUps = plan(meds, preferences: preferences).notifications.filter {
            if case .followUp = $0.category { return true }
            return false
        }
        #expect(followUps.isEmpty)
    }

    @Test("An important medication still follows up during quiet hours")
    func importantOverridesQuietHours() {
        var preferences = NotificationPreferences.default
        preferences.quietHoursEnabled = true
        preferences.quietHoursStart = Fixture.time(22)
        preferences.quietHoursEnd = Fixture.time(7)

        let meds = [medication("a", times: [Fixture.time(2, 30)], importance: .important)]
        let followUps = plan(meds, preferences: preferences).notifications.filter {
            if case .followUp = $0.category { return true }
            return false
        }
        #expect(!followUps.isEmpty, "That's what Important is for")
    }

    @Test("Quiet hours never suppress the scheduled dose reminder itself")
    func quietHoursDoNotSuppressDoses() {
        // The user chose 2:30. Silencing the thing they asked for would break
        // the app's core promise — quiet hours only hold back what the *app*
        // decided to send.
        var preferences = NotificationPreferences.default
        preferences.quietHoursEnabled = true
        preferences.quietHoursStart = Fixture.time(22)
        preferences.quietHoursEnd = Fixture.time(7)

        let result = doses(plan([medication("a", times: [Fixture.time(2, 30)])], preferences: preferences))
        #expect(result.count == 1)
    }

    // MARK: - Master switches

    @Test("Turning dose reminders off silences dose and follow-up alerts")
    func doseRemindersMasterSwitch() {
        var preferences = NotificationPreferences.default
        preferences.doseRemindersEnabled = false
        let result = plan([medication("a", times: [Fixture.time(8)])], preferences: preferences)

        #expect(doses(result).isEmpty)
        #expect(result.notifications.allSatisfy {
            if case .followUp = $0.category { return false }
            return true
        })
    }

    @Test("Refill alerts have their own switch and their own time")
    func refillAlertsAreIndependent() {
        var preferences = NotificationPreferences.default
        preferences.refillAlertTime = Fixture.time(11, 30)

        let low = MedicationSnapshot(
            id: "low", name: "Low", doseDetail: "", notes: "",
            colorName: MedicationColor.navy.rawValue, isActive: true,
            schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1)),
            pillsRemaining: 2, refillThreshold: 10, importance: .standard
        )

        let refills = plan([low], preferences: preferences).notifications.filter {
            if case .refill = $0.category { return true }
            return false
        }
        #expect(refills.count == 1)
        #expect(refills[0].nextFireDate == Fixture.date(2026, 8, 13, 11, 30))
        #expect(refills[0].importance == .gentle, "Supply is never urgent enough to interrupt")

        preferences.refillAlertsEnabled = false
        #expect(plan([low], preferences: preferences).notifications.allSatisfy {
            if case .refill = $0.category { return false }
            return true
        })
    }

    // MARK: - Invariants preserved

    @Test("The plan still respects the system limit")
    func systemLimitStillRespected() {
        // Distinct times per medication: sharing times lets bundling collapse
        // demand and the assertion passes without the budget doing any work.
        let meds = (0..<30).map { i in
            medication("med-\(i)", times: [Fixture.time(7, i), Fixture.time(19, i)])
        }
        let result = plan(meds)
        #expect(result.notifications.count <= NotificationPlanner.systemLimit)
        #expect(!result.deferredMedicationIDs.isEmpty,
                "60 distinct dose demands must saturate the budget — otherwise this test proves nothing")
    }

    @Test("Identifiers stay unique and ASCII, including bundles")
    func identifiersRemainSafe() {
        let meds = ["a", "b", "c"].map { medication($0, times: [Fixture.time(8), Fixture.time(20)]) }
        let ids = plan(meds).notifications.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.allSatisfy(\.isASCII) })
    }

    @Test("Planning is deterministic")
    func planningIsDeterministic() {
        let meds = ["a", "b", "c"].map { medication($0, times: [Fixture.time(8)]) }
        #expect(plan(meds).notifications.map(\.id) == plan(meds).notifications.map(\.id))
    }
}

@Suite("Notification sound")
struct NotificationSoundTests {

    @Test("Every sound except None resolves to a bundled file")
    func soundsMapToFiles() throws {
        // iOS cannot reference Apple's own tones from a third-party app, so each
        // of these must correspond to a WAV shipped in the bundle. A typo here
        // is silent at runtime — iOS just falls back to the default tone.
        // Assert the file is actually reachable in the app bundle (the tests
        // are app-hosted, so Bundle.main is the app), not merely that the name
        // is computed the same way the implementation computes it.
        for sound in NotificationSound.allCases where sound != .none {
            let file = try #require(sound.fileName)
            let resource = file.hasSuffix(".wav") ? String(file.dropLast(4)) : file
            #expect(
                Bundle.main.url(forResource: resource, withExtension: "wav") != nil,
                "\(file) is named but not shipped — iOS will silently play the default tone"
            )
        }
        #expect(NotificationSound.none.fileName == nil)
    }

    @Test("Filenames are ASCII and lowercase")
    func filenamesAreSafe() {
        for sound in NotificationSound.allCases {
            guard let file = sound.fileName else { continue }
            // `canBeConverted` rather than `allSatisfy(\.isASCII)`: a rethrows
            // call inside #expect's macro expansion trips "call can throw".
            #expect(file.canBeConverted(to: .ascii))
            #expect(file == file.lowercased())
        }
    }

    @Test("A gentle medication stays silent whatever the user picked")
    func gentleOverridesTheChosenSound() {
        // The whole point of the level. Resolving it in one place means no call
        // site can forget the rule.
        #expect(MedicationImportance.gentle.resolvedSound(preferred: .chime) == .none)
        #expect(MedicationImportance.gentle.resolvedSound(preferred: .pulse) == .none)
    }

    @Test("Standard and Important use the chosen sound")
    func audibleLevelsHonourTheChoice() {
        #expect(MedicationImportance.standard.resolvedSound(preferred: .marimba) == .marimba)
        #expect(MedicationImportance.important.resolvedSound(preferred: .glass) == .glass)
    }

    @Test("Choosing None silences even an important medication")
    func noneIsHonoured() {
        // If the user explicitly asked for silence, the app does not override it.
        #expect(MedicationImportance.important.resolvedSound(preferred: .none) == .none)
    }

    @Test("The planner attaches the chosen sound to dose reminders")
    func plannerCarriesTheSound() {
        var preferences = NotificationPreferences.default
        preferences.doseSound = .marimba

        let medication = Fixture.medication(schedule: Fixture.schedule(
            kind: .daily, times: [Fixture.time(8)], start: Fixture.date(2026, 8, 1)
        ))
        let plan = NotificationPlanner.plan(
            medications: [medication], events: .empty,
            now: Fixture.date(2026, 8, 12, 7), preferences: preferences,
            calendar: Fixture.calendar()
        )
        let dose = plan.notifications.first { if case .dose = $0.category { return true }; return false }
        #expect(dose?.sound == .marimba)
    }

    @Test("Refill alerts are silent by default")
    func refillsAreSilentByDefault() {
        #expect(NotificationPreferences.default.refillSound == .none)
        #expect(NotificationPreferences.default.doseSound == .chime)
    }

    @Test("A sound choice survives save and load")
    func soundPersists() {
        let defaults = UserDefaults(suiteName: "sound-test-\(UUID().uuidString)")!
        var p = NotificationPreferences.default
        p.doseSound = .rise
        p.refillSound = .marimba
        p.save(to: defaults)

        let loaded = NotificationPreferences.load(from: defaults)
        #expect(loaded.doseSound == .rise)
        #expect(loaded.refillSound == .marimba)
    }
}

@Suite("Dose window")
struct DoseWindowTests {

    let calendar = Fixture.calendar()

    private func index(_ entries: [(String, Date, DoseStatus)]) -> LoggedEventIndex {
        LoggedEventIndex(entries.map { (medicationID: $0.0, scheduledAt: $0.1, status: $0.2) })
    }

    private func medication(times: Set<TimeOfDay>, start: Date) -> MedicationSnapshot {
        Fixture.medication(schedule: Fixture.schedule(kind: .daily, times: times, start: start))
    }

    @Test("Each window produces the deadline it advertises")
    func deadlines() {
        let scheduled = Fixture.date(2026, 8, 12, 8)
        #expect(DoseWindow.strict.deadline(for: scheduled, calendar: calendar) == Fixture.date(2026, 8, 12, 9))
        #expect(DoseWindow.standard.deadline(for: scheduled, calendar: calendar) == Fixture.date(2026, 8, 12, 10))
        #expect(DoseWindow.relaxed.deadline(for: scheduled, calendar: calendar) == Fixture.date(2026, 8, 12, 12))
    }

    @Test("Until-end-of-day resolves to the calendar day, not a fixed duration")
    func endOfDayIsCalendarBased() {
        // A 23:00 dose must get the last hour of its own day. Adding a fixed
        // number of seconds would push it into tomorrow and quietly give a late
        // dose a longer window than an early one.
        let late = Fixture.date(2026, 8, 12, 23)
        let early = Fixture.date(2026, 8, 12, 6)
        let midnightTonight = Fixture.date(2026, 8, 13, 0)

        #expect(DoseWindow.untilEndOfDay.deadline(for: late, calendar: calendar) == midnightTonight)
        #expect(DoseWindow.untilEndOfDay.deadline(for: early, calendar: calendar) == midnightTonight)
    }

    @Test("A midnight dose still gets a non-zero window")
    func midnightDoseIsNotInstantlyMissed() {
        let midnight = Fixture.date(2026, 8, 12, 0)
        let deadline = DoseWindow.untilEndOfDay.deadline(for: midnight, calendar: calendar)
        #expect(deadline > midnight, "A zero-length window would mark it missed the moment it was due")
    }

    @Test("The window decides when a dose flips from due to overdue")
    func windowDrivesState() {
        let scheduled = Fixture.date(2026, 8, 12, 8)
        let ninetyMinutesLater = Fixture.date(2026, 8, 12, 9, 30)

        #expect(
            DoseCalculator.state(for: "m", at: scheduled, events: .empty,
                                 now: ninetyMinutesLater, window: .strict, calendar: calendar) == .overdue
        )
        #expect(
            DoseCalculator.state(for: "m", at: scheduled, events: .empty,
                                 now: ninetyMinutesLater, window: .standard, calendar: calendar) == .due
        )
    }

    @Test("A strict window marks more doses missed than a relaxed one")
    func stricterWindowsMissMore() {
        // The user-visible consequence: this setting changes the adherence
        // percentage the whole History tab is built around.
        //
        // 12:30, not 12:00: a dose counts as missed only *after* its
        // deadline, so sitting exactly on one (11:00 + 1h, 08:00 + 4h)
        // would assert on the boundary itself rather than the behaviour.
        let now = Fixture.date(2026, 8, 12, 12, 30)
        let meds = [medication(times: [Fixture.time(8), Fixture.time(11)], start: Fixture.date(2026, 8, 12))]

        let strict = DoseCalculator.unloggedOverdueDoses(
            medications: meds, events: .empty, lookbackDays: 7,
            now: now, window: .strict, calendar: calendar
        )
        let relaxed = DoseCalculator.unloggedOverdueDoses(
            medications: meds, events: .empty, lookbackDays: 7,
            now: now, window: .relaxed, calendar: calendar
        )

        #expect(strict.count == 2, "Both 08:00 and 11:00 are past a one-hour window")
        #expect(relaxed.count == 1, "Only 08:00 is past a four-hour window")
    }

    @Test("Until-end-of-day never marks today's doses missed")
    func endOfDayProtectsToday() {
        let now = Fixture.date(2026, 8, 12, 23, 30)
        let meds = [medication(times: [Fixture.time(8)], start: Fixture.date(2026, 8, 12))]

        let overdue = DoseCalculator.unloggedOverdueDoses(
            medications: meds, events: .empty, lookbackDays: 7,
            now: now, window: .untilEndOfDay, calendar: calendar
        )
        #expect(overdue.isEmpty, "The day isn't over yet")
    }

    @Test("Until-end-of-day does mark yesterday's doses missed")
    func endOfDayCatchesYesterday() {
        let now = Fixture.date(2026, 8, 13, 9)
        let meds = [medication(times: [Fixture.time(8)], start: Fixture.date(2026, 8, 12))]

        let overdue = DoseCalculator.unloggedOverdueDoses(
            medications: meds, events: .empty, lookbackDays: 7,
            now: now, window: .untilEndOfDay, calendar: calendar
        )
        #expect(overdue.count == 1)
        #expect(overdue[0].scheduledAt == Fixture.date(2026, 8, 12, 8))
    }

    @Test("A logged dose is never overdue, whatever the window")
    func loggedDosesAreNeverMissed() {
        let now = Fixture.date(2026, 8, 12, 23)
        let scheduled = Fixture.date(2026, 8, 12, 8)
        let meds = [medication(times: [Fixture.time(8)], start: Fixture.date(2026, 8, 12))]

        for window in DoseWindow.allCases {
            let overdue = DoseCalculator.unloggedOverdueDoses(
                medications: meds, events: index([("med-1", scheduled, .taken)]),
                lookbackDays: 7, now: now, window: window, calendar: calendar
            )
            #expect(overdue.isEmpty, "\(window.rawValue) must not re-mark a taken dose")
        }
    }

    @Test("The default stays two hours, matching the old hardcoded behaviour")
    func defaultIsUnchanged() {
        #expect(TrackingPreferences.default.doseWindow == .standard)
        #expect(DoseWindow.standard.interval == DoseCalculator.missWindow)
    }

    @Test("The preference survives save and load")
    func persistence() {
        let defaults = UserDefaults(suiteName: "dose-window-\(UUID().uuidString)")!
        var p = TrackingPreferences.default
        p.doseWindow = .untilEndOfDay
        p.save(to: defaults)
        #expect(TrackingPreferences.load(from: defaults).doseWindow == .untilEndOfDay)
    }
}
