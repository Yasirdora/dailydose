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
