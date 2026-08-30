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

    /// The supply count a scan last wrote, if one did.
    ///
    /// Two jobs, and neither needs a second flag. It lets the editor say the
    /// number came off the pack rather than out of the user's head — a count
    /// read from a carton is worth checking before it starts driving refill
    /// warnings. And it makes "has the user touched this?" decidable: a count
    /// still equal to what the last scan wrote is the scan's to replace,
    /// anything else is theirs to keep.
    private(set) var scannedSupplyCount: Int?

    /// Whether the count on screen is the one a scan read and the user has not
    /// changed.
    var hasScannedSupplyCount: Bool {
        scannedSupplyCount != nil && pillsRemaining == scannedSupplyCount
    }

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
        pack: ScannedPack? = nil
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
                // And "30 Tabletten" pre-fills the supply count, which nothing
                // in the scan path used to touch at all.
                if let quantity = prefill.quantity { adoptScannedSupply(quantity) }
            }
            // Stated beats inferred: AI (30) is a count the manufacturer
            // encoded, where the label's is one we read off the front.
            if let stated = pack?.count { adoptScannedSupply(stated) }
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
    /// clause buried here. The Save button and the sentence explaining it read
    /// the same source, so the button can never grey out with nothing on
    /// screen saying why.
    ///
    /// A missing name and a blank supply count both block Save *silently* —
    /// neither is one of the `blockingReason` cases. The name field is the
    /// first thing on the sheet with its placeholder in plain sight, and the
    /// supply count sits directly under the toggle that revealed it, so both
    /// sentences fired the moment the user acted rather than after a mistake.
    /// Every other blocked state still names itself.
    var isValid: Bool { !trimmedName.isEmpty && !isMissingSupplyCount && blockingReason == nil }

    /// Why Save is dimmed, in the order the fields appear on screen — for the
    /// states a user cannot work out by looking at the form.
    ///
    /// The per-card footers already explained each of these, but a footer only
    /// helps someone looking at it, and the button it explains is up in the
    /// toolbar — so what remains here is pinned beside Save.
    ///
    /// The blank supply count used to be one of these, for a good reason: a
    /// blank count persisted as 0, `0 <= 0` fired a refill alert on a box the
    /// user had just filled, and with no sentence the dimmed Save read as a
    /// broken toggle. The rule still holds — `isValid` enforces it — but the
    /// sentence was asked for removal. If the toggle ever reads as broken
    /// again, that is the thread to pull.
    ///
    /// `isValid` reads this rather than repeating the rules, so a stated reason
    /// and a live Save button can never disagree — with the single, documented
    /// exception of the empty name above.
    var blockingReason: String? {
        if hasInvalidDoseNumbers {
            return String(localized: "Strength and amount should be numbers, like 500 or 0.5.")
        }
        if times.isEmpty {
            return String(localized: "Add at least one time of day.")
        }
        if hasEmptyWeekdays {
            return String(localized: "Choose at least one day of the week.")
        }
        if hasEndBeforeStart {
            return String(localized: "The end date is before the start date.")
        }
        return nil
    }

    /// "Specific days" with every day deselected: a schedule that can never
    /// occur, and the picker happily allows it.
    var hasEmptyWeekdays: Bool { kind == .weekdays && weekdays.isEmpty }

    /// A course that ends before it starts.
    var hasEndBeforeStart: Bool {
        guard let endDate else { return false }
        return endDate < Calendar.current.startOfDay(for: startDate)
    }

    /// Tracking supply with nothing ever captured or typed.
    ///
    /// An empty field is `nil`, and `nil` used to persist as `0` — which made
    /// `0 <= 0` true and fired a refill alert on a box the user had just
    /// filled. The warning level may stay blank (it means "don't warn me");
    /// the count cannot, because asking to be warned about a supply nobody has
    /// stated is meaningless. It fires only when the user wants warnings and
    /// there is no number at all — never merely because tracking is off.
    var isMissingSupplyCount: Bool { tracksSupply && pillsRemaining == nil }

    var refillThresholdExceedsSupply: Bool {
        guard tracksSupply, let threshold = refillThreshold, let remaining = pillsRemaining else { return false }
        return threshold > remaining
    }

    /// How many are on hand, clamped to a sane range so a typo can't put the
    /// counter into a state the UI can't represent.
    ///
    /// **Not gated on `tracksSupply`, and that is the fix.** The count and the
    /// toggle are different kinds of thing that were treated as one: the count
    /// is an *observation* — what the pack says, read off a carton or typed by
    /// the user — and the toggle is a *preference*, whether they want to be
    /// warned. Gating the observation on the preference meant a scan that read
    /// "90" while tracking happened to be off discarded the 90 at save, and
    /// switching tracking on afterwards started from an empty field.
    ///
    /// An empty field still resolves to `nil`, never `0`. Coercing it to zero
    /// is how a brand-new medication arrived already low on supply.
    var resolvedPills: Int? {
        guard let pillsRemaining else { return nil }
        return max(0, min(pillsRemaining, 9999))
    }

    /// The warning level, which *is* the preference and stays gated.
    ///
    /// Blank means "don't warn me" — `isLowOnSupply` needs both values, so a
    /// nil threshold simply never triggers. Turning tracking off therefore
    /// stops the warnings without throwing the count away, which is the whole
    /// point of the split.
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

    /// Folds in what a barcode said. The key and the dates are the barcode's
    /// to state — nothing on the label can contradict them, and nothing the
    /// user typed is overwritten by them.
    /// Folds in one capture — what the label said, then what the pack's own
    /// code said.
    ///
    /// One entry point rather than two calls at every site, because the order
    /// is load-bearing: AI (30) is a count the manufacturer *stated*, the
    /// label's is one we *inferred*, and the stated one has to arrive second
    /// to win.
    mutating func apply(_ capture: ScanCapture) {
        apply(capture.label)
        if let pack = capture.pack { apply(pack) }
    }

    /// Whether a supply count exists at all, whatever the tracking preference
    /// says. Lets the editor reveal a number that was captured while tracking
    /// was off rather than presenting an empty field.
    var hasSupplyCount: Bool { pillsRemaining != nil }

    mutating func apply(_ pack: ScannedPack) {
        productKey = pack.key
        if let expiry = pack.expiry { expiryDate = expiry.day }
        if let stated = pack.count { adoptScannedSupply(stated) }
    }

    /// Takes a supply count a scan read — unless the user has one of their own.
    ///
    /// A scan filling a blank field is help; a scan replacing a number someone
    /// typed is the app overruling them about their own medicine cabinet. The
    /// same rule `form` already follows.
    ///
    /// The count is recorded whatever `tracksSupply` says, because it is an
    /// observation rather than a preference — see ``resolvedPills``. Switching
    /// tracking on is a convenience on top of that, not the thing that makes
    /// the number exist.
    private mutating func adoptScannedSupply(_ count: Int) {
        guard pillsRemaining == nil || pillsRemaining == scannedSupplyCount else { return }
        pillsRemaining = count
        scannedSupplyCount = count
        // Reading a count off the box is also the answer to "do you want to
        // track this?" — the number is already there to be tracked.
        tracksSupply = true
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
        if let quantity = result.quantity { adoptScannedSupply(quantity) }
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
