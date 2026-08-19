import Foundation
import Testing
import SwiftData
import SwiftUI
@testable import DailyDose

/// The regression suite for the lossy backup: a format that silently dropped
/// every scheduling field added after v1, keyed history by medication *name*,
/// and had no import at all.
@Suite("Backup")
struct BackupTests {

    let calendar = Fixture.calendar()

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Medication.self, DoseEvent.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test("Every scheduling field survives a round trip")
    @MainActor
    func scheduleSurvivesRoundTrip() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let schedule = DoseSchedule(
            kind: .everyXDays,
            times: [Fixture.time(8), Fixture.time(20)],
            startDate: Fixture.date(2026, 8, 1),
            weekdays: [2, 4],
            intervalDays: 21,
            dayOfMonth: 15,
            intervalHours: 6,
            cycleOnDays: 21,
            cycleOffDays: 7,
            endDate: Fixture.date(2026, 12, 31)
        )
        let medication = Medication(name: "Methotrexate", schedule: schedule, pillsRemaining: 12, refillThreshold: 4)
        context.insert(medication)
        try context.save()

        let archive = BackupService.makeArchive(medications: [medication], events: [])
        let decoded = try BackupService.decode(try BackupService.encode(archive))

        // Restore into a *fresh* store, which is the case that mattered and was
        // never tested.
        let restored = try makeContainer()
        _ = try BackupService.restore(decoded, into: restored.mainContext)

        let fetched = try restored.mainContext.fetch(FetchDescriptor<Medication>())
        #expect(fetched.count == 1)

        let result = fetched[0].schedule
        #expect(result.kind == .everyXDays)
        #expect(result.intervalDays == 21)
        #expect(result.dayOfMonth == 15)
        #expect(result.intervalHours == 6)
        #expect(result.cycleOnDays == 21)
        #expect(result.cycleOffDays == 7)
        #expect(result.times == schedule.times)
        #expect(result.weekdays == schedule.weekdays)
        #expect(result.startDate.timeIntervalSince1970 == schedule.startDate.timeIntervalSince1970)
        #expect(result.endDate?.timeIntervalSince1970 == schedule.endDate?.timeIntervalSince1970)
        #expect(fetched[0].pillsRemaining == 12)
        #expect(fetched[0].refillThreshold == 4)
    }

    @Test("A v2 backup without the new schedule fields still decodes")
    func v2BackupDecodesWithDefaults() throws {
        // Hand-written JSON in the v2 shape: no intervalHours, no cycle days.
        // Optional record fields must decode as absent, not fail the import.
        let json = """
        {
          "app": "Daily Dose",
          "version": 2,
          "exportedAt": "2026-08-01T08:00:00Z",
          "events": [],
          "medications": [{
            "id": "m1", "name": "Metformin", "doseDetail": "", "notes": "",
            "colorName": "teal", "isActive": true,
            "createdAt": "2026-08-01T08:00:00Z",
            "scheduleKind": "daily", "times": ["08:00"],
            "weekdays": [1, 2, 3, 4, 5, 6, 7], "intervalDays": 1,
            "startDate": "2026-08-01T08:00:00Z"
          }]
        }
        """
        let archive = try BackupService.decode(Data(json.utf8))
        #expect(archive.medications.count == 1)
        #expect(archive.medications[0].intervalHours == nil)
    }

    @Test("Importing twice does not duplicate history")
    @MainActor
    func importIsIdempotent() throws {
        let source = try makeContainer()
        let medication = Medication(
            name: "Metformin",
            schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1))
        )
        source.mainContext.insert(medication)
        source.mainContext.insert(
            DoseEvent(medication: medication, scheduledAt: Fixture.date(2026, 8, 11, 8), status: .taken)
        )
        try source.mainContext.save()

        let events = try source.mainContext.fetch(FetchDescriptor<DoseEvent>())
        let archive = BackupService.makeArchive(medications: [medication], events: events)

        let target = try makeContainer()
        let first = try BackupService.restore(archive, into: target.mainContext)
        let second = try BackupService.restore(archive, into: target.mainContext)

        #expect(first.eventsAdded == 1)
        #expect(second.eventsAdded == 0)
        #expect(second.eventsSkipped == 1)
        #expect(try target.mainContext.fetch(FetchDescriptor<DoseEvent>()).count == 1)
    }

    @Test("Two medications sharing a name stay separate")
    @MainActor
    func identicalNamesDoNotMerge() throws {
        // The old format keyed events by name, so two medications called
        // "Ibuprofen" merged their histories on import.
        let source = try makeContainer()
        let a = Medication(id: "a", name: "Ibuprofen", schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1)))
        let b = Medication(id: "b", name: "Ibuprofen", schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1)))
        source.mainContext.insert(a)
        source.mainContext.insert(b)
        source.mainContext.insert(DoseEvent(medication: a, scheduledAt: Fixture.date(2026, 8, 11, 8), status: .taken))
        source.mainContext.insert(DoseEvent(medication: b, scheduledAt: Fixture.date(2026, 8, 11, 20), status: .missed))
        try source.mainContext.save()

        let archive = BackupService.makeArchive(
            medications: [a, b],
            events: try source.mainContext.fetch(FetchDescriptor<DoseEvent>())
        )
        let target = try makeContainer()
        _ = try BackupService.restore(archive, into: target.mainContext)

        let restored = try target.mainContext.fetch(FetchDescriptor<Medication>())
        #expect(restored.count == 2)
        #expect(Set(restored.map(\.id)) == ["a", "b"])
    }

    /// A restore that unlearns every box the user taught the app is a restore
    /// that quietly costs them the feature: the next scan of a familiar pack
    /// creates a duplicate medication instead of offering a refill.
    @Test("The scanned pack's identity and expiry survive a round trip")
    @MainActor
    func scannedPackSurvivesRoundTrip() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let key = ProductKey.pzn(try #require(PZN("12345678")))
        let expiry = Fixture.date(2027, 3, 31)
        let medication = Medication(
            name: "Metformin",
            schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1)),
            productKey: key,
            expiryDate: expiry
        )
        context.insert(medication)
        try context.save()

        let archive = BackupService.makeArchive(medications: [medication], events: [])
        #expect(archive.version == 5)
        #expect(archive.medications.first?.productKeyRaw == "pzn:12345678")

        let decoded = try BackupService.decode(try BackupService.encode(archive))
        let restored = try makeContainer()
        _ = try BackupService.restore(decoded, into: restored.mainContext)

        let fetched = try restored.mainContext.fetch(FetchDescriptor<Medication>())
        let result = try #require(fetched.first)
        #expect(result.productKey == key)
        #expect(result.expiryDate == expiry)

        // And a second restore over the top updates rather than duplicates,
        // keeping both fields.
        _ = try BackupService.restore(decoded, into: restored.mainContext)
        let again = try restored.mainContext.fetch(FetchDescriptor<Medication>())
        #expect(again.count == 1)
        #expect(again.first?.productKey == key)
        #expect(again.first?.expiryDate == expiry)
    }

    /// A medication nobody ever scanned has no barcode and no expiry. The
    /// archive must say that rather than inventing either — and an archive
    /// written before v5 must still decode.
    @Test("An unscanned medication round-trips with no pack, and v4 still decodes")
    @MainActor
    func unscannedMedicationAndOlderArchives() throws {
        let container = try makeContainer()
        let medication = Medication(
            name: "Typed by hand",
            schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1))
        )
        container.mainContext.insert(medication)
        try container.mainContext.save()

        let archive = BackupService.makeArchive(medications: [medication], events: [])
        #expect(archive.medications.first?.productKeyRaw == "")
        #expect(archive.medications.first?.expiryDate == nil)

        // A v4 archive: the two keys simply absent from the JSON.
        var v4 = archive
        v4.version = 4
        v4.medications[0].productKeyRaw = nil
        v4.medications[0].expiryDate = nil
        let decoded = try BackupService.decode(try BackupService.encode(v4))

        let restored = try makeContainer()
        _ = try BackupService.restore(decoded, into: restored.mainContext)
        let result = try #require(try restored.mainContext.fetch(FetchDescriptor<Medication>()).first)
        #expect(result.productKeyRaw == "")
        #expect(result.productKey == nil)
        #expect(result.expiryDate == nil)
    }

    /// A key written by a build that knows a code this one does not must
    /// survive the round trip rather than be dropped in the middle of it.
    /// It reads as "no key" here — never as a crash, and never as a wrong
    /// match — and is still there when that build reads it back.
    @Test("An unreadable product key is preserved, not discarded")
    @MainActor
    func unknownProductKeyIsPreserved() throws {
        let target = try makeContainer()
        let archive = BackupService.Archive(
            exportedAt: .now,
            medications: [BackupService.MedicationRecord(
                id: "future", name: "From a later build", doseDetail: "", notes: "",
                colorName: MedicationColor.navy.rawValue,
                productKeyRaw: "quantum:42",
                isActive: true, createdAt: .now,
                scheduleKind: ScheduleKind.daily.rawValue, times: ["08:00"], weekdays: Array(1...7),
                intervalDays: 1, dayOfMonth: nil, startDate: Fixture.date(2026, 8, 1), endDate: nil,
                pillsRemaining: nil, refillThreshold: nil
            )],
            events: []
        )
        _ = try BackupService.restore(archive, into: target.mainContext)

        let result = try #require(try target.mainContext.fetch(FetchDescriptor<Medication>()).first)
        #expect(result.productKeyRaw == "quantum:42", "kept verbatim for the build that understands it")
        #expect(result.productKey == nil, "and read as nothing by this one")

        // Re-exporting hands it back unchanged.
        let round = BackupService.makeArchive(medications: [result], events: [])
        #expect(round.medications.first?.productKeyRaw == "quantum:42")
    }

    @Test("A backup from a newer format is refused rather than misread")
    func rejectsNewerVersions() throws {
        var archive = BackupService.Archive(exportedAt: .now, medications: [], events: [])
        archive.version = BackupService.currentVersion + 1
        let data = try BackupService.encode(archive)

        #expect(throws: BackupError.self) {
            _ = try BackupService.decode(data)
        }
    }

    @Test("Restoring never deletes existing data")
    @MainActor
    func restoreIsAdditive() throws {
        let target = try makeContainer()
        target.mainContext.insert(
            Medication(id: "local", name: "Local only", schedule: Fixture.schedule(start: Fixture.date(2026, 8, 1)))
        )
        try target.mainContext.save()

        let archive = BackupService.Archive(
            exportedAt: .now,
            medications: [BackupService.MedicationRecord(
                id: "backup", name: "From backup", doseDetail: "", notes: "",
                colorName: MedicationColor.navy.rawValue, isActive: true, createdAt: .now,
                scheduleKind: ScheduleKind.daily.rawValue, times: ["08:00"], weekdays: Array(1...7),
                intervalDays: 1, dayOfMonth: nil, startDate: Fixture.date(2026, 8, 1), endDate: nil,
                pillsRemaining: nil, refillThreshold: nil
            )],
            events: []
        )
        _ = try BackupService.restore(archive, into: target.mainContext)

        let all = try target.mainContext.fetch(FetchDescriptor<Medication>())
        #expect(all.count == 2, "A restore adds; it must never wipe what's already there")
    }
}

@Suite("Label parsing")
struct LabelScanParserTests {

    @Test("Name and strength split at the dosage")
    func splitsNameAndStrength() {
        let result = LabelScanParser.parse("METFORMIN HCL 500 MG TABLET")
        #expect(result.name == "Metformin HCL")
        #expect(result.strength == "500 mg tablet")
    }

    @Test("Clinical abbreviations keep their casing")
    func preservesAbbreviations() {
        // Plain `.capitalized` produced "Metformin Hcl" and "Coq10" — people
        // recognise their own medication by these tokens.
        #expect(LabelScanParser.parse("METFORMIN HCL 500 MG").name == "Metformin HCL")
        #expect(LabelScanParser.parse("METOPROLOL ER 50 MG").name == "Metoprolol ER")
        #expect(LabelScanParser.parse("VITAMIN D3 2000 IU").name.contains("D3"))
    }

    @Test("Multi-line OCR output is flattened")
    func flattensMultilineText() {
        let result = LabelScanParser.parse("PANADOL\nEACH TABLET\nCONTAINS 500 MG")
        #expect(!result.name.contains("\n"))
        #expect(result.strength.contains("500 mg"))
    }

    @Test("A label with no dosage still yields a usable name")
    func handlesMissingStrength() {
        let result = LabelScanParser.parse("ASPIRIN")
        #expect(result.name == "Aspirin")
        #expect(result.strength.isEmpty)
    }

    @Test("Digits inside words are not mistaken for a dosage")
    func doesNotMatchWordInternalUnits() {
        // The old pattern had no trailing word boundary, so "10gauge" matched
        // as "10 g".
        #expect(LabelScanParser.containsStrength("10gauge needle") == false)
        #expect(LabelScanParser.containsStrength("500 mg"))
        #expect(LabelScanParser.containsStrength("2.5mg"))
        #expect(LabelScanParser.containsStrength("0,5 ml"))
    }

    @Test("Empty and whitespace input is safe")
    func handlesEmptyInput() {
        #expect(LabelScanParser.parse("").isEmpty)
        #expect(LabelScanParser.parse("   \n  ").isEmpty)
    }

    @Test("Unit casing is normalised without touching the number")
    func normalisesUnits() {
        #expect(LabelScanParser.parse("IBUPROFEN 400MG CAPSULES").strength.contains("400"))
        #expect(LabelScanParser.parse("IBUPROFEN 400 MG CAPSULES").strength == "400 mg capsules")
    }

    @Test("The label's own form words are detected — and silence stays silence")
    func detectsForm() {
        #expect(LabelScanParser.parse("METFORMIN HCL 500 MG TABLET").detectedForm == .pill)
        #expect(LabelScanParser.parse("IBUPROFEN 400 MG CAPSULES").detectedForm == .capsule)
        #expect(LabelScanParser.parse("PANADOL\nEACH TABLET\nCONTAINS 500 MG").detectedForm == .pill)
        #expect(LabelScanParser.parse("VENTOLIN INHALER 100 MCG").detectedForm == .inhaler)
        // A label that declares no form yields no guess.
        #expect(LabelScanParser.parse("ASPIRIN").detectedForm == nil)
    }

    @Test("Strength is also extracted as structure — amount and unit")
    func extractsStructuredStrength() {
        let metformin = LabelScanParser.parse("METFORMIN HCL 500 MG TABLET")
        #expect(metformin.strengthAmount == 500)
        #expect(metformin.strengthUnit == .mg)

        // European decimal comma, and a unit (`%`) that a trailing word
        // boundary could never match.
        let timolol = LabelScanParser.parse("TIMOLOL 0,5 % EYE DROPS")
        #expect(timolol.strengthAmount == 0.5)
        #expect(timolol.strengthUnit == .percent)

        #expect(LabelScanParser.parse("VENTOLIN 100 MCG INHALER").strengthUnit == .mcg)
        #expect(LabelScanParser.parse("VITAMIN D3 2000 IU").strengthUnit == .iu)
        #expect(LabelScanParser.parse("IBUPROFEN 400MG").strengthAmount == 400)

        // No strength on the label → no structure, and "10gauge" is not 10 g.
        #expect(LabelScanParser.parse("ASPIRIN").strengthAmount == nil)
        #expect(LabelScanParser.parse("10gauge needle").strengthAmount == nil)
    }

    /// Auto-capture waits for a fragment *containing* a strength, and on a
    /// real box the strength is usually set on its own line — so a bare
    /// "500 MG" is the most likely scan there is. It used to arrive as a
    /// medication named "500 Mg", which saves cleanly and is wrong forever.
    @Test("A fragment that is only a strength yields no name, not a name of the strength")
    func strengthAloneIsNotAName() {
        for fragment in ["500 MG", "500mg", "1000 IU", "60 ml", "0,5 %"] {
            let result = LabelScanParser.parse(fragment)
            #expect(result.name.isEmpty, "\(fragment) named the medication after its own dose")
            #expect(result.strengthAmount != nil, "\(fragment) still carries its strength")
            #expect(!result.isEmpty, "A strength alone is still worth pre-filling")
        }
    }

    /// The words a label prints *around* a strength are not a name either.
    @Test("Label boilerplate never becomes the medication name")
    func boilerplateIsNotAName() {
        #expect(LabelScanParser.parse("EACH TABLET CONTAINS 500 MG").name.isEmpty)
        #expect(LabelScanParser.parse("Net 100 g").name.isEmpty)
        #expect(LabelScanParser.parse("Contents: 250 mg").name.isEmpty)
        // …but a real name sitting in front of the strength still survives.
        #expect(LabelScanParser.parse("METFORMIN HCL 500 MG TABLET").name == "Metformin HCL")
        #expect(LabelScanParser.parse("TIMOLOL 0,5 % EYE DROPS").name == "Timolol")
        #expect(LabelScanParser.parse("ASPIRIN").name == "Aspirin")
    }
}

@Suite("Medication draft")
struct MedicationDraftTests {

    @Test("A name and at least one time are required")
    func validation() {
        var draft = MedicationDraft()
        #expect(draft.isValid == false, "An unnamed medication cannot be saved")

        draft.name = "Metformin"
        #expect(draft.isValid)

        draft.times = []
        #expect(draft.isValid == false, "Without a time there is nothing to remind")
    }

    @Test("Weekday schedules need at least one day")
    func weekdayValidation() {
        var draft = MedicationDraft()
        draft.name = "Metformin"
        draft.setKind(.weekdays)
        draft.weekdays = []
        #expect(draft.isValid == false)
    }

    @Test("Two doses can never share a time")
    func timesAreDeduplicated() {
        var draft = MedicationDraft()
        draft.setDaily(dosesPerDay: 2)
        #expect(draft.times.count == 2)

        let sorted = draft.times.sorted()
        draft.replace(sorted[1], with: sorted[0])

        #expect(draft.times.count == 1, "Dragging one time onto another collapses them")
        #expect(draft.hasCollidingTimes, "…and the UI is told, so the snap is explained")
    }

    @Test("Changing frequency keeps the times the user chose")
    func adjustingTimesPreservesChoices() {
        var draft = MedicationDraft()
        draft.times = [Fixture.time(7, 15)]
        draft.setDaily(dosesPerDay: 3)

        #expect(draft.times.count == 3)
        #expect(draft.times.contains(Fixture.time(7, 15)), "A hand-picked time must survive")
    }

    @Test("Sparse schedules drop back to one time a day")
    func sparseSchedulesUseOneTime() {
        var draft = MedicationDraft()
        draft.setDaily(dosesPerDay: 4)
        draft.setKind(.monthly)
        #expect(draft.times.count == 1)
    }

    @Test("Supply values are only stored when tracking is on")
    func supplyIsGatedByToggle() {
        var draft = MedicationDraft()
        draft.name = "Metformin"
        draft.pillsRemaining = 30
        draft.refillThreshold = 5

        #expect(draft.resolvedPills == nil, "Tracking is off — nothing should be stored")

        draft.tracksSupply = true
        #expect(draft.resolvedPills == 30)
        #expect(draft.resolvedThreshold == 5)
    }

    @Test("A warning level above the supply is flagged")
    func thresholdWarning() {
        var draft = MedicationDraft()
        draft.tracksSupply = true
        draft.pillsRemaining = 5
        draft.refillThreshold = 20
        #expect(draft.refillThresholdExceedsSupply)
    }

    @Test("An end date before the start is invalid")
    func endBeforeStartIsRejected() {
        var draft = MedicationDraft()
        draft.name = "Amoxicillin"
        draft.startDate = Fixture.date(2026, 8, 12)
        draft.endDate = Fixture.date(2026, 8, 1)
        #expect(draft.isValid == false)
    }

    @Test("The built schedule matches the draft")
    func buildsSchedule() {
        var draft = MedicationDraft()
        draft.name = "Metformin"
        draft.setKind(.everyXDays)
        draft.intervalDays = 21
        draft.startDate = Fixture.date(2026, 8, 12)

        let schedule = draft.buildSchedule()
        #expect(schedule?.kind == .everyXDays)
        #expect(schedule?.intervalDays == 21)
        #expect(schedule?.times.isEmpty == false)
    }

    @Test("Strength and intake compose the display line")
    func composesDoseDetail() {
        var draft = MedicationDraft()
        draft.form = .inhaler
        draft.strengthText = "100"
        draft.strengthUnit = .mcg
        draft.intakeText = "2"
        #expect(draft.composedDoseDetail == "100 mcg · 2 puffs")
        #expect(draft.resolvedDoseDetail == "100 mcg · 2 puffs")
        #expect(draft.intakeUnitLabel == "puffs")

        // Singular agreement.
        draft.intakeText = "1"
        #expect(draft.composedDoseDetail == "100 mcg · 1 puff")

        // A strength without a unit still shows; a unit without a number
        // is dropped — the number is the fact.
        draft.intakeText = ""
        draft.strengthUnit = nil
        #expect(draft.composedDoseDetail == "100")

        // Nothing structured and never touched → the legacy free text
        // survives untouched.
        var legacy = MedicationDraft()
        legacy.doseDetail = "half a tablet with food"
        #expect(legacy.resolvedDoseDetail == "half a tablet with food")

        // …but once a structured field has been edited, empty means empty —
        // clearing the strength must not resurrect the old words.
        draft.strengthText = ""
        #expect(draft.resolvedDoseDetail == "")
    }

    @Test("A dose number that doesn't parse blocks the save, honestly")
    func invalidDoseNumbers() {
        var draft = MedicationDraft()
        draft.name = "Metformin"
        draft.strengthText = "five hundred"
        #expect(draft.hasInvalidDoseNumbers)
        #expect(!draft.isValid)

        draft.strengthText = "0,5"
        #expect(!draft.hasInvalidDoseNumbers, "European decimal comma parses")
        #expect(draft.parsedStrength == 0.5)
    }

    @Test("A scan pre-fills strength, unit and form")
    func scanPrefill() {
        let result = LabelScanParser.parse("VENTOLIN INHALER 100 MCG")
        let draft = MedicationDraft(medication: nil, prefill: result)
        #expect(draft.strengthText == "100")
        #expect(draft.strengthUnit == .mcg)
        #expect(draft.form == .inhaler)
        #expect(draft.composedDoseDetail == "100 mcg")
    }
}

@Suite("Medication form safety")
struct MedicationFormSafetyTests {

    private func draft(_ configure: (inout MedicationDraft) -> Void) -> MedicationDraft {
        var draft = MedicationDraft()
        draft.name = "Metformin"
        configure(&draft)
        return draft
    }

    /// Turning tracking on and typing nothing used to persist 0 — and
    /// `0 <= 0` made a brand-new medication low on supply, so a refill alert
    /// fired for a box the user had just filled.
    @Test("Supply tracking with a blank count blocks the save rather than storing zero")
    func blankSupplyCountIsNotZero() {
        let empty = draft { $0.tracksSupply = true }
        #expect(empty.isMissingSupplyCount)
        #expect(!empty.isValid, "Save must not commit a count nobody entered")
        #expect(empty.resolvedPills == nil, "Empty is empty — never 0")

        // A blank *warning level* is a legitimate "don't warn me".
        let counted = draft { $0.tracksSupply = true; $0.pillsRemaining = 30 }
        #expect(!counted.isMissingSupplyCount)
        #expect(counted.isValid)
        #expect(counted.resolvedPills == 30)
        #expect(counted.resolvedThreshold == nil)

        // And tracking off stores neither, whatever is left in the fields.
        let off = draft { $0.tracksSupply = false; $0.pillsRemaining = 30; $0.refillThreshold = 5 }
        #expect(off.isValid)
        #expect(off.resolvedPills == nil)
        #expect(off.resolvedThreshold == nil)
    }

    /// Both states greyed the Save button out with nothing on screen saying
    /// why. They are named now, so the footer and the button read the same
    /// source.
    @Test("Every invalid state is a named reason, not an anonymous disabled button")
    func invalidStatesAreNamed() {
        let noDays = draft { $0.setKind(.weekdays); $0.weekdays = [] }
        #expect(noDays.hasEmptyWeekdays)
        #expect(!noDays.isValid)

        let backwards = draft {
            $0.startDate = Fixture.date(2026, 8, 19)
            $0.endDate = Fixture.date(2026, 8, 12)
        }
        #expect(backwards.hasEndBeforeStart)
        #expect(!backwards.isValid)

        // An end date *on* the start day is a one-day course, not an error.
        let sameDay = draft {
            $0.startDate = Fixture.date(2026, 8, 19)
            $0.endDate = Fixture.date(2026, 8, 19)
        }
        #expect(!sameDay.hasEndBeforeStart)
        #expect(sameDay.isValid)
    }

    /// Legacy rows carry their strength as free text, and the editor keeps it
    /// as a fallback so an entry the parser can't read isn't dropped. But
    /// clearing the field used to resurrect the old words on save, which made
    /// the strength impossible to delete.
    @Test("Clearing the strength on a legacy entry actually clears it")
    func clearedStrengthStaysCleared() {
        var untouched = MedicationDraft()
        untouched.name = "Metformin"
        untouched.doseDetail = "half a sachet"
        #expect(untouched.resolvedDoseDetail == "half a sachet",
                "Text the parser can't read is kept until the user replaces it")

        var cleared = untouched
        cleared.strengthText = "500"
        cleared.strengthUnit = .mg
        #expect(cleared.resolvedDoseDetail == "500 mg")

        cleared.strengthText = ""
        #expect(cleared.resolvedDoseDetail.isEmpty,
                "Deleting the strength must delete it, not restore the old words")
    }

    /// The value that was validated is the value that gets stored.
    @Test("A name is validated and saved in the same trimmed form")
    func nameIsTrimmedConsistently() {
        let padded = draft { $0.name = "  Metformin HCL  " }
        #expect(padded.isValid)
        #expect(padded.trimmedName == "Metformin HCL")
    }
}

@Suite("Strength unit")
struct StrengthUnitTests {

    @Test("Every spelling a label or backup might carry resolves")
    func tolerantResolution() {
        #expect(StrengthUnit.named("mg") == .mg)
        #expect(StrengthUnit.named("MG") == .mg)
        #expect(StrengthUnit.named("milligrams") == .mg)
        #expect(StrengthUnit.named("µg") == .mcg)
        #expect(StrengthUnit.named("mcg") == .mcg)
        #expect(StrengthUnit.named("ml") == .mL)
        #expect(StrengthUnit.named("%") == .percent)
        #expect(StrengthUnit.named("IU") == .iu)
        // Unknown spellings read as unspecified, never as a crash.
        #expect(StrengthUnit.named("teaspoon") == nil)
        #expect(StrengthUnit.named("") == nil)
    }

    @Test("Units print exactly as labels print them")
    func displayNames() {
        #expect(StrengthUnit.mg.displayName == "mg")
        #expect(StrengthUnit.mcg.displayName == "mcg")
        #expect(StrengthUnit.mL.displayName == "mL")
        #expect(StrengthUnit.iu.displayName == "IU")
        #expect(StrengthUnit.percent.displayName == "%")
    }
}

@Suite("Medication colour")
struct MedicationColorTests {

    @Test("Every swatch clears the 3:1 non-text contrast minimum in every trait combination")
    func everySwatchMeetsContrast() {
        // The previous version of this test asserted `a == b || a != b`, which
        // cannot fail — so a threshold chosen by eye left coral at 2.46:1 and
        // pink at 2.70:1 unguarded. Then the ratio was measured against the raw
        // swatch while dark mode and high contrast redraw it — white-on-navy in
        // high-contrast dark mode rendered at ~2.5:1. Assert the measured ratio
        // of the rendered colour, in all four trait combinations.
        let styles: [UIUserInterfaceStyle] = [.light, .dark]
        let contrasts: [UIAccessibilityContrast] = [.normal, .high]
        for swatch in MedicationColor.allCases {
            for style in styles {
                for contrast in contrasts {
                    let ratio = swatch.glyphContrastRatio(style: style, contrast: contrast)
                    #expect(
                        ratio >= 3.0,
                        "\(swatch.rawValue) glyph contrast is \(ratio) in style \(style.rawValue), contrast \(contrast.rawValue) — below the 3:1 minimum"
                    )
                }
            }
        }
    }

    @Test("Light swatches take a dark glyph, dark swatches a white one")
    func glyphColorFollowsLuminance() {
        for swatch in [MedicationColor.yellow, .mint, .brown, .olive, .sky, .coral, .pink] {
            #expect(
                swatch.usesDarkGlyph(style: .light, contrast: .normal),
                "\(swatch.rawValue) is too light for white"
            )
        }
        for swatch in [MedicationColor.charcoal, .red, .purple] {
            #expect(
                !swatch.usesDarkGlyph(style: .light, contrast: .normal),
                "\(swatch.rawValue) is dark enough for white"
            )
        }
    }

    @Test("High-contrast dark mode re-evaluates the glyph on the rendered swatch")
    func highContrastDarkChoosesByRenderedLuminance() {
        // Navy's raw luminance says "white glyph", but the rendered swatch is
        // lifted and brightened until a dark glyph wins 6.6:1 over white's
        // 2.5:1. The palette default must not fail the users who asked for
        // more contrast.
        #expect(MedicationColor.navy.usesDarkGlyph(style: .dark, contrast: .high))
        #expect(!MedicationColor.navy.usesDarkGlyph(style: .light, contrast: .normal))
    }

    @Test("Legacy colour keys still resolve")
    func legacyKeysMigrate() {
        #expect(MedicationColor.named("teal") == .mint)
        #expect(MedicationColor.named("blue") == .navy)
        #expect(MedicationColor.named("nonsense") == MedicationColor.default)
    }
}
