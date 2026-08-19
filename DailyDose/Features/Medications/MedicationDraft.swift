import Foundation

/// The editable form state, and the only place that decides whether a
/// medication is valid.
///
/// A value type on purpose: it can be constructed in a test, poked at, and
/// asserted against without a view, a store or a simulator.
struct MedicationDraft: Equatable {
    var name = ""
    var doseDetail = ""
    var notes = ""
    var color = MedicationColor.default
    /// Physical form — drives the tile glyph and the supply unit language.
    /// Nil until the user chooses (or a label declares it): there is no
    /// silent pill default, because a wrong icon is worse than a neutral one.
    var form: MedicationForm?

    // MARK: Structured strength

    /// Strength as the user types it — "500" — kept as text so the field
    /// never fights the keyboard. Parsed (comma-tolerant) at save.
    var strengthText = "" { didSet { if strengthText != oldValue { didEditDose = true } } }
    var strengthUnit: StrengthUnit?
    /// How much is taken per dose, as typed — "2". The unit is not asked:
    /// it comes from the form (inhaler → puffs), so one choice answers both
    /// questions and they can never disagree.
    var intakeText = "" { didSet { if intakeText != oldValue { didEditDose = true } } }

    /// Whether the user has touched a structured dose field in this session —
    /// including *clearing* one.
    ///
    /// Legacy rows carry their strength as free text. That text is offered to
    /// the parser on open and kept as a fallback so an entry the parser can't
    /// read ("half a sachet") isn't silently dropped on the first save. But
    /// once someone edits the structured fields their intent wins: clearing
    /// the strength on an older medication used to resurrect the old words on
    /// save, which made the field impossible to empty.
    private(set) var didEditDose = false

    var kind: ScheduleKind = .daily
    /// A `Set`, so two doses can never occupy the same minute — the condition
    /// that used to render duplicate cards where logging one logged both.
    var times: Set<TimeOfDay> = [.morning]
    var weekdays: Set<Int> = Set(1...7)
    var intervalDays = 2
    var dayOfMonth = Calendar.current.component(.day, from: .now)
    /// For `.everyXHours`: the gap between doses. The single entry in `times`
    /// is the first dose — the anchor the whole sequence counts from.
    var intervalHours = 8
    /// For `.cycle`: this many days on, then this many days off.
    var cycleOnDays = 21
    var cycleOffDays = 7
    var startDate = Calendar.current.startOfDay(for: .now)
    var endDate: Date?

    var tracksSupply = false
    var pillsRemaining: Int?
    var refillThreshold: Int?

    /// How much this medication may interrupt. Defaults to standard, so the
    /// common case needs no decision from the user.
    var importance: MedicationImportance = .standard

    // MARK: The pack it came in

    /// The scanned barcode identity. Carried, never edited: there is no field
    /// for it and no reason for one — it exists so the *next* box the user
    /// scans finds this medication instead of creating a second copy of it.
    /// Loaded from the medication on open so an ordinary edit cannot erase it.
    var productKey: ProductKey?

    /// The scanned pack's expiry date, on the same terms.
    var expiryDate: Date?

    /// Set when an edit collapsed two times into one, so the UI can explain
    /// why a picker appeared to snap.
    private(set) var hasCollidingTimes = false

    init() {}

    init(
        medication: Medication?,
        prefill: LabelScanParser.Result? = nil,
        pack: ScannedPack? = nil,
        product: DrugDirectory.Entry? = nil
    ) {
        productKey = pack?.key
        expiryDate = pack?.expiry?.day
        guard let medication else {
            if let prefill {
                name = prefill.name
                doseDetail = prefill.strength
                // A label that says "tablets" may pre-select the form; the
                // user still sees it in the picker and can overrule it.
                form = prefill.detectedForm
                // And "500 MG" pre-fills the strength row — amount and unit —
                // so a scan means confirming, not retyping.
                if let amount = prefill.strengthAmount {
                    strengthText = Self.format(amount)
                    strengthUnit = prefill.strengthUnit
                }
            }
            // The directory speaks last, because it speaks from a check digit
            // rather than from pixels: where it and the camera disagree about a
            // name or a strength, the code is the one that cannot have misread
            // a 5 as an S.
            if let product { apply(product) }
            // Seeding is not editing: a scan that filled the field must still
            // be clearable without the free text coming back.
            didEditDose = false
            return
        }
        let schedule = medication.schedule
        // A scan of a new box replaces what the old one said; opening the
        // editor to change a dose time does not.
        productKey = pack?.key ?? medication.productKey
        expiryDate = pack?.expiry?.day ?? medication.expiryDate
        // `product` is deliberately not applied here. The user has already
        // named this medication; a directory entry must not rewrite what they
        // chose to call their own medicine just because they scanned a refill.
        name = medication.displayName
        doseDetail = medication.doseDetail
        notes = medication.notes
        color = MedicationColor.named(medication.colorName)
        form = medication.form
        if let amount = medication.strengthAmount {
            strengthText = Self.format(amount)
            strengthUnit = medication.strengthUnit
        }
        if let intake = medication.intakeAmount {
            intakeText = Self.format(intake)
        }
        // Legacy free text: offer it to the parser, so "500 mg" typed before
        // structured strength existed becomes amount + unit the next time
        // the editor opens — upgraded, never discarded.
        if strengthText.isEmpty && !medication.doseDetail.isEmpty {
            let parsed = LabelScanParser.parse(medication.doseDetail)
            if let amount = parsed.strengthAmount {
                strengthText = Self.format(amount)
                strengthUnit = parsed.strengthUnit
            }
        }
        kind = schedule.kind
        times = schedule.times.isEmpty ? [.morning] : schedule.times
        weekdays = schedule.weekdays.isEmpty ? Set(1...7) : schedule.weekdays
        intervalDays = schedule.intervalDays
        dayOfMonth = schedule.dayOfMonth ?? Calendar.current.component(.day, from: schedule.startDate)
        intervalHours = schedule.intervalHours
        cycleOnDays = schedule.cycleOnDays
        cycleOffDays = schedule.cycleOffDays
        startDate = schedule.startDate
        endDate = schedule.endDate
        tracksSupply = medication.pillsRemaining != nil
        pillsRemaining = medication.pillsRemaining
        refillThreshold = medication.refillThreshold
        importance = medication.importance
        didEditDose = false
    }

    // MARK: - Validation

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Every reason a draft can be unsaveable is a named property, not a
    /// clause buried in `isValid`. The Save button and the footer that
    /// explains it then read the same source, so the button can never grey
    /// out with nothing on screen saying why.
    var isValid: Bool {
        !trimmedName.isEmpty
            && !times.isEmpty
            && !hasInvalidDoseNumbers
            && !hasEmptyWeekdays
            && !hasEndBeforeStart
            && !isMissingSupplyCount
    }

    /// "Specific days" with every day deselected: a schedule that can never
    /// occur, and the picker happily allows it.
    var hasEmptyWeekdays: Bool { kind == .weekdays && weekdays.isEmpty }

    /// A course that ends before it starts.
    var hasEndBeforeStart: Bool {
        guard let endDate else { return false }
        return endDate < Calendar.current.startOfDay(for: startDate)
    }

    /// Tracking supply with the count left blank.
    ///
    /// An empty field is `nil`, and `nil` used to persist as `0` — which made
    /// `0 <= 0` true and fired a refill alert on a box the user had just
    /// filled. The warning level may stay blank (it means "don't warn me");
    /// the count cannot, because tracking supply without one is meaningless.
    var isMissingSupplyCount: Bool { tracksSupply && pillsRemaining == nil }

    var refillThresholdExceedsSupply: Bool {
        guard tracksSupply, let threshold = refillThreshold, let remaining = pillsRemaining else { return false }
        return threshold > remaining
    }

    /// Supply values are only stored when tracking is on, and are clamped to a
    /// sane range so a typo can't put the counter into a state the UI can't
    /// represent.
    ///
    /// An empty field resolves to `nil`, never `0`. Coercing it to zero is how
    /// a brand-new medication arrived already low on supply.
    var resolvedPills: Int? {
        guard tracksSupply, let pillsRemaining else { return nil }
        return max(0, min(pillsRemaining, 9999))
    }

    /// Blank means "don't warn me" — `isLowOnSupply` needs both values, so a
    /// nil threshold simply never triggers.
    var resolvedThreshold: Int? {
        guard tracksSupply, let refillThreshold else { return nil }
        return max(0, min(refillThreshold, 9999))
    }

    // MARK: - Mutation

    mutating func setDaily(dosesPerDay count: Int) {
        kind = .daily
        weekdays = Set(1...7)
        adjustTimeCount(to: count)
    }

    mutating func setKind(_ newKind: ScheduleKind) {
        kind = newKind
        // Sparse schedules take a single time of day; carrying four over from a
        // "4× daily" selection produces a plan nobody asked for.
        if newKind != .daily { adjustTimeCount(to: 1) }
        if newKind == .weekdays, weekdays.isEmpty { weekdays = Set(1...7) }
    }

    /// Grows or shrinks the time list, keeping what the user already chose.
    private mutating func adjustTimeCount(to count: Int) {
        let target = max(1, min(count, 4))
        if times.count > target {
            times = Set(times.sorted().prefix(target))
        } else if times.count < target {
            // Merge in suggestions, skipping any that would collide with an
            // existing choice.
            for suggestion in TimeOfDay.suggested(forDosesPerDay: target) where times.count < target {
                times.insert(suggestion)
            }
            // If suggestions collided, fill forward from the latest time.
            var cursor = times.max() ?? .morning
            while times.count < target {
                guard let next = TimeOfDay(hour: (cursor.hour + 4) % 24, minute: cursor.minute) else { break }
                times.insert(next)
                cursor = next
            }
        }
    }

    mutating func replace(_ old: TimeOfDay, with new: TimeOfDay) {
        var updated = times
        updated.remove(old)
        hasCollidingTimes = updated.contains(new)
        updated.insert(new)
        times = updated
    }

    /// Folds in what the FDA directory knows about a scanned pack.
    ///
    /// This overwrites the name and strength the OCR guessed, and it should:
    /// the directory was reached through a check digit, so it cannot have
    /// misread a 5 as an S or a 0 as an O. It fills nothing it does not know —
    /// a combination tablet has no single strength, and the field is left empty
    /// rather than filled with the first of two.
    mutating func apply(_ product: DrugDirectory.Entry) {
        if !product.name.isEmpty { name = product.name }
        if let strength = product.strength {
            strengthText = Self.format(strength.amount)
            strengthUnit = strength.unit
        }
        if let detected = product.form { form = detected }
        // The FDA's own wording, kept when we cannot turn it into a number —
        // "12 [hp_X]/mL" is meaningless to our strength field and perfectly
        // meaningful to the person holding the bottle.
        if product.strength == nil, !product.strengthText.isEmpty {
            doseDetail = product.strengthText
        }
    }

    /// Folds in what a barcode said. The key and the dates are the barcode's
    /// to state — nothing on the label can contradict them, and nothing the
    /// user typed is overwritten by them.
    mutating func apply(_ pack: ScannedPack) {
        productKey = pack.key
        if let expiry = pack.expiry { expiryDate = expiry.day }
    }

    mutating func apply(_ result: LabelScanParser.Result) {
        if !result.name.isEmpty { name = result.name }
        if !result.strength.isEmpty { doseDetail = result.strength }
        if let amount = result.strengthAmount {
            strengthText = Self.format(amount)
            strengthUnit = result.strengthUnit
        }
        // A scan never overrules a form the user already chose.
        if form == nil, let detected = result.detectedForm { form = detected }
    }

    /// The form the entry itself declares, for when the user never opened the
    /// picker: "Ventolin Inhaler" says inhaler in its own name. Conservative —
    /// fires only on explicit form words, nil when nothing certain is said.
    var detectedForm: MedicationForm? {
        MedicationForm.detect(in: "\(name) \(doseDetail)")
    }

    /// What gets saved: the user's choice if there is one, else a confident
    /// detection from the entry's own words, else unspecified — never an
    /// assumed pill.
    var resolvedForm: MedicationForm? { form ?? detectedForm }

    // MARK: - Strength

    /// Numbers as people write them: "500" and "0,5" both parse.
    static func parseAmount(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    /// 500 → "500", 0.5 → "0.5" — no trailing ".0" noise.
    static func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }

    var parsedStrength: Double? { Self.parseAmount(strengthText) }
    var parsedIntake: Double? { Self.parseAmount(intakeText) }

    /// Non-empty text that doesn't parse is a typo, and a silently dropped
    /// number is worse than an honest complaint — so it blocks the save
    /// with a footer explaining what the field expects.
    var hasInvalidDoseNumbers: Bool {
        (!strengthText.trimmingCharacters(in: .whitespaces).isEmpty && parsedStrength == nil)
            || (!intakeText.trimmingCharacters(in: .whitespaces).isEmpty && parsedIntake == nil)
    }

    /// The unit the per-dose amount counts in — derived from the form,
    /// neutral when the form is unspecified.
    var intakeUnitLabel: String {
        MedicationForm.supplyUnit(form: resolvedForm, count: parsedIntake == 1 ? 1 : 2)
    }

    /// The display line every surface renders: "500 mg · 2 puffs", built
    /// from structure so it is consistent everywhere. A strength with no
    /// unit still shows ("500"); a unit with no amount is dropped — the
    /// number is the fact, the unit only qualifies it.
    var composedDoseDetail: String {
        var parts: [String] = []
        if let strength = parsedStrength {
            var s = Self.format(strength)
            if let unit = strengthUnit { s += " \(unit.displayName)" }
            parts.append(s)
        }
        if let intake = parsedIntake {
            parts.append("\(Self.format(intake)) \(MedicationForm.supplyUnit(form: resolvedForm, count: intake == 1 ? 1 : 2))")
        }
        return parts.joined(separator: " · ")
    }

    /// What gets persisted as the display line: the composed structure when
    /// anything structured exists, else whatever free text was already there
    /// — legacy entries keep their words until the user replaces them.
    ///
    /// "Replaces" includes emptying: once a structured field has been edited,
    /// an empty result is an empty line. Resurrecting the old text made the
    /// strength impossible to delete.
    var resolvedDoseDetail: String {
        let composed = composedDoseDetail
        if !composed.isEmpty { return composed }
        return didEditDose ? "" : doseDetail
    }

    // MARK: - Output

    func buildSchedule() -> DoseSchedule? {
        guard isValid else { return nil }
        return DoseSchedule(
            kind: kind,
            times: times,
            startDate: Calendar.current.startOfDay(for: startDate),
            weekdays: kind == .weekdays ? weekdays : Set(1...7),
            intervalDays: kind == .everyXDays ? intervalDays : 1,
            dayOfMonth: kind == .monthly ? dayOfMonth : nil,
            intervalHours: kind == .everyXHours ? intervalHours : 8,
            cycleOnDays: kind == .cycle ? cycleOnDays : 21,
            cycleOffDays: kind == .cycle ? cycleOffDays : 7,
            endDate: endDate
        )
    }

    // MARK: - Copy

    var frequencySummary: String {
        switch kind {
        case .daily:
            switch times.count {
            case 1: String(localized: "Once a day")
            case 2: String(localized: "Twice a day")
            default: String(localized: "\(times.count) times a day")
            }
        case .everyXDays:
            intervalDays == 1
                ? String(localized: "Every day")
                : String(localized: "Every \(intervalDays) days")
        case .everyXHours:
            intervalHours == 1
                ? String(localized: "Every hour")
                : String(localized: "Every \(intervalHours) hours")
        case .cycle:
            cycleOffDays == 0
                ? String(localized: "Every day")
                : String(localized: "\(cycleOnDays) days on · \(cycleOffDays) days off")
        case .weekdays:
            weekdaySummary
        case .monthly:
            String(localized: "Monthly on the \(dayOfMonth.ordinalString())")
        }
    }

    private var weekdaySummary: String {
        let days = weekdays.sorted()
        if days.count == 7 { return String(localized: "Every day") }
        if days.isEmpty { return String(localized: "No days set") }
        let symbols = Calendar.current.shortWeekdaySymbols
        return days
            .compactMap { symbols.indices.contains($0 - 1) ? symbols[$0 - 1] : nil }
            .joined(separator: " · ")
    }

    var durationSummary: String {
        guard let endDate else { return String(localized: "Ongoing") }
        return String(localized: "Until \(endDate.formatted(.dateTime.day().month(.abbreviated)))")
    }

    var accessibilitySummary: String {
        let timeList = times.sorted().map { $0.formatted() }.joined(separator: ", ")
        return "\(trimmedName.isEmpty ? String(localized: "New medication") : trimmedName), \(frequencySummary), \(timeList)"
    }
}
