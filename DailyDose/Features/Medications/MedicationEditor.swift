import SwiftUI
import SwiftData

/// Add and edit, one screen.
///
/// The form is driven by `MedicationDraft` — a plain value type that owns
/// validation. The view renders the draft and nothing else, which is why the
/// "can this be saved?" question has exactly one answer instead of a condition
/// spread across four computed properties.
struct MedicationEditor: View {
    let medication: Medication?
    var prefill: LabelScanParser.Result?
    /// What the box's barcode said, when the editor was opened by a scan.
    /// It fills no field on this screen: it is stored so the *next* scan of
    /// the same pack finds this medication instead of adding another one.
    var pack: ScannedPack?
    var onSaved: (() -> Void)?

    @Environment(\.doseStore) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft = MedicationDraft()
    @State private var route: Route?
    /// The time currently being tuned on the wheel. The sheet stays open
    /// until the user confirms — see TimeWheelSheet.
    @State private var editingTime: TimeOfDay?
    /// Same grammar for the start date: a big calendar, a green ✓.
    @State private var isEditingStartDate = false
    @State private var didLoad = false
    /// The essentials stay visible. Everything else is available without
    /// making a first-time setup feel like a medical intake form.
    @State private var showsMoreOptions = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Route: String, Identifiable {
        case scanner, frequency, duration, form
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            // No Form, no system rows, no derived separators: the sheet is
            // hand-built cards in a ScrollView — the same fully-controlled
            // approach that made the rest of the app stable. Every card
            // shares one row height and one divider rhythm.
            ScrollView {
                VStack(spacing: 22) {
                    // The fast path, first and outside every card: exactly
                    // one row tall, like each field — quiet glass tinted
                    // with the accent, because untinted glass over the
                    // near-black page is how it once went invisible.
                    if LabelScannerSheet.isAvailable {
                        Button { route = .scanner } label: {
                            Label(String(localized: "Scan Medication"), systemImage: "camera.viewfinder")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: editorRowHeight)
                                .contentShape(.rect)
                        }
                        .secondaryButton()
                        .tint(Theme.accent)
                        .accessibilityHint(String(localized: "Opens the camera to read the bottle's label"))
                    }

                    detailsSection
                    scheduleSection
                    // Supply is schedule logic, not personalization: the
                    // refill forecast *is* the schedule speaking (supply ÷
                    // doses per day). It stands as its own card right after
                    // Schedule — always visible, never collapsed away.
                    supplySection
                    moreOptionsSection

                    if showsMoreOptions {
                        notesSection
                        remindersSection
                        colorSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(medication == nil
                             ? String(localized: "Add Medication")
                             : String(localized: "Edit Medication"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { save() }
                        .fontWeight(.semibold)
                        .disabled(!draft.isValid)
                        // Sighted users can read the form back before
                        // committing; this is that same check, spoken.
                        .accessibilityHint(draft.accessibilitySummary)
                }
            }
            // `.task` rather than `.onAppear`: onAppear can fire again when the
            // sheet returns from a sub-sheet, which used to wipe the user's
            // in-progress edits.
            .task {
                guard !didLoad else { return }
                didLoad = true
                draft = MedicationDraft(medication: medication, prefill: prefill, pack: pack)
                // Editing a medication that already has notes or custom
                // reminders opens with those sections expanded — the screen
                // should reflect what is configured, not hide it. (Supply
                // is always visible now; it needs no expansion.)
                if let medication {
                    showsMoreOptions = !medication.notes.isEmpty
                        || medication.importance != .standard
                        || MedicationColor.named(medication.colorName) != .default
                }
            }
            .sheet(item: $route) { route in
                switch route {
                case .scanner:
                    LabelScannerSheet { result, scannedPack in
                        draft.apply(result)
                        if let scannedPack { draft.apply(scannedPack) }
                        Haptics.success()
                    }
                case .frequency:
                    FrequencyPicker(draft: $draft)
                case .duration:
                    DurationPicker(draft: $draft)
                case .form:
                    FormPicker(selection: $draft.form)
                }
            }
            // Time and date pickers are Apple's own popovers: a native
            // floating card with the system's material, animation and
            // lifecycle — `.none` keeps the popover even in compact width,
            // which is how it floats centered instead of sliding up.
            .popover(item: $editingTime) { time in
                TimeWheelPopover(time: time) { picked in
                    if let picked { draft.replace(time, with: picked) }
                    editingTime = nil
                }
                .presentationCompactAdaptation(.none)
            }
            .popover(isPresented: $isEditingStartDate) {
                DateCalendarPopover(date: draft.startDate) { picked in
                    if let picked { draft.startDate = picked }
                    isEditingStartDate = false
                }
                .presentationCompactAdaptation(.none)
            }
        }
    }

    // MARK: - Sections

    /// The unit selector appears only once there is a number to qualify —
    /// options exactly when they become relevant, never before.
    private var showsStrengthUnit: Bool {
        !draft.strengthText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var showsIntakeUnit: Bool {
        !draft.intakeText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A hairline exactly where a native one would sit.
    private var rowDivider: some View {
        Divider().padding(.leading, 16)
    }

    /// Every field row in the Medication card: same margins, same 44pt,
    /// same leading alignment. One definition, so the rows can never drift
    /// apart again.
    private func editorRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: editorRowHeight, alignment: .leading)
    }

    /// A compact capsule with a chevron — the way Apple marks an inline
    /// choice. Unset, it wears the accent: an invitation, not a placeholder.
    private var strengthUnitMenu: some View {
        Menu {
            ForEach(StrengthUnit.allCases) { unit in
                Button {
                    draft.strengthUnit = unit
                    Haptics.select()
                } label: {
                    if draft.strengthUnit == unit {
                        Label(unit.displayName, systemImage: "checkmark")
                    } else {
                        Text(unit.displayName)
                    }
                }
            }
        } label: {
            EditorChip(
                text: draft.strengthUnit?.displayName ?? String(localized: "unit"),
                highlighted: draft.strengthUnit == nil
            )
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(String(localized: "Strength unit"))
    }

    /// One row, one divider, one rhythm — built by hand.
    ///
    /// The system's separators derive their insets from row content, and a
    /// custom HStack confuses that logic: the result was dividers rendered
    /// as stubs at the trailing edge. So this card opts out entirely — a
    /// single VStack with explicit hairlines, every row exactly 44pt, every
    /// divider exactly where a native one would sit.
    /// One height for every interactive row in this sheet. Declared once,
    /// applied everywhere — uniformity by construction, not approximation.
    /// 56pt: generous enough for an 80-year-old's thumb, calm enough to
    /// stack five deep without towering.
    private var editorRowHeight: CGFloat { 56 }

    private var detailsSection: some View {
        cardSection(String(localized: "Medication"), footer: medicationFooter) {
            editorRow {
                TextField(String(localized: "Medication name"), text: $draft.name)
                    .textInputAutocapitalization(.words)
            }
            rowDivider

            // Placeholder-first: at rest each row is a single quiet line.
            // The unit appears the moment a number does — options exactly
            // when they become relevant, never before.
            editorRow {
                TextField(String(localized: "Strength (e.g. 500)"), text: $draft.strengthText)
                    .keyboardType(.decimalPad)
                if showsStrengthUnit {
                    strengthUnitMenu
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsStrengthUnit)
            rowDivider

            editorRow {
                TextField(String(localized: "Amount per dose (e.g. 1)"), text: $draft.intakeText)
                    .keyboardType(.decimalPad)
                if showsIntakeUnit {
                    // The unit is whispered, not asked: the form choice
                    // already answered it.
                    Text(draft.intakeUnitLabel)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsIntakeUnit)
            rowDivider

            Button { route = .form } label: {
                // The preview card's one true magic — watching the tile come
                // alive — lives here, where the choice is made: pick a form,
                // the glyph appears; change the colour below, it repaints.
                HStack(spacing: 12) {
                    MedicationTile(color: draft.color, form: draft.form, size: 32)
                    Text(String(localized: "Form"))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Text(draft.form?.displayName ?? String(localized: "Choose"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: editorRowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(SoftPressButtonStyle())
            .accessibilityHint(String(localized: "Choose whether this is a pill, liquid, injection or another form"))
        }
    }

    /// Hand-built with the same rows and dividers as the Medication card.
    /// Two cards, one set of metrics.
    private var scheduleSection: some View {
        cardSection(String(localized: "Schedule"), footer: scheduleFooter) {
            Button { route = .frequency } label: {
                EditorSummaryRow(
                    label: String(localized: "How often"),
                    value: draft.frequencySummary
                )
            }
            .buttonStyle(SoftPressButtonStyle())
            .accessibilityHint(String(localized: "Choose how often this medication is taken"))

            if draft.kind == .everyXDays {
                rowDivider
                editorRow {
                    Stepper(value: $draft.intervalDays, in: 1...90) {
                        LabeledContent(String(localized: "Repeat every")) {
                            Text(daysCopy(draft.intervalDays))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if draft.kind == .everyXHours {
                rowDivider
                editorRow {
                    Stepper(value: $draft.intervalHours, in: 1...24) {
                        LabeledContent(String(localized: "Repeat every")) {
                            Text(hoursCopy(draft.intervalHours))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if draft.kind == .cycle {
                rowDivider
                editorRow {
                    Stepper(value: $draft.cycleOnDays, in: 1...90) {
                        LabeledContent(String(localized: "Take for")) {
                            Text(daysCopy(draft.cycleOnDays))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                rowDivider
                editorRow {
                    Stepper(value: $draft.cycleOffDays, in: 1...30) {
                        LabeledContent(String(localized: "Then pause for")) {
                            Text(daysCopy(draft.cycleOffDays))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if draft.kind == .weekdays {
                rowDivider
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Which days?"))
                        .font(.subheadline.weight(.medium))
                    WeekdayPicker(selection: $draft.weekdays)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if draft.kind == .monthly {
                rowDivider
                editorRow {
                    Picker(String(localized: "Day of month"), selection: $draft.dayOfMonth) {
                        ForEach(1...31, id: \.self) { day in
                            Text(day.ordinalString()).tag(day)
                        }
                    }
                }
            }

            ForEach(Array(draft.times.sorted().enumerated()), id: \.element) { index, time in
                rowDivider
                Button {
                    editingTime = time
                    Haptics.select()
                } label: {
                    HStack {
                        Text(
                            draft.kind == .everyXHours
                                ? String(localized: "Starting at")
                                : draft.times.count == 1
                                    ? String(localized: "Time")
                                    : String(localized: "Time \(index + 1)")
                        )
                        .foregroundStyle(.primary)
                        Spacer()
                        EditorChip(text: time.formatted())
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: editorRowHeight)
                    .contentShape(.rect)
                }
                .buttonStyle(SoftPressButtonStyle())
                .accessibilityHint(String(localized: "Opens the time wheel"))
            }

            rowDivider
            Button {
                isEditingStartDate = true
                Haptics.select()
            } label: {
                HStack {
                    Text(String(localized: "Starts"))
                        .foregroundStyle(.primary)
                    Spacer()
                    EditorChip(text: draft.startDate.formatted(.dateTime.day().month(.abbreviated).year()))
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: editorRowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(SoftPressButtonStyle())
            .accessibilityHint(String(localized: "Opens the calendar"))

            rowDivider
            Button { route = .duration } label: {
                EditorSummaryRow(
                    label: String(localized: "Ends"),
                    value: draft.durationSummary
                )
            }
            .buttonStyle(SoftPressButtonStyle())
            .accessibilityHint(String(localized: "Choose whether this medication has an end date"))
        }
    }

    /// A deliberate boundary: the everyday plan ends above this row. Optional
    /// personalisation remains easy to find without competing with the first
    /// successful setup.
    private var moreOptionsSection: some View {
        VStack(spacing: 0) {
            Button {
                if reduceMotion {
                    showsMoreOptions.toggle()
                } else {
                    withAnimation(.smooth(duration: 0.25)) {
                        showsMoreOptions.toggle()
                    }
                }
                Haptics.select()
            } label: {
                HStack(spacing: 12) {
                    Label(
                        showsMoreOptions
                            ? String(localized: "Fewer options")
                            : String(localized: "More options"),
                        systemImage: "slider.horizontal.3"
                    )
                    .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showsMoreOptions ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: editorRowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(SoftPressButtonStyle())
            .accessibilityHint(
                showsMoreOptions
                    ? String(localized: "Hides optional medication details")
                    : String(localized: "Shows notes, supply tracking, reminder preferences and colour")
            )
        }
        .cardStyle()
    }

    private var notesSection: some View {
        cardSection(String(localized: "Details")) {
            editorRow {
                TextField(String(localized: "Notes (e.g. take with food)"), text: $draft.notes)
            }
        }
    }

    private var supplySection: some View {
        cardSection(String(localized: "Supply & refill"), footer: supplyFooter) {
            editorRow {
                Toggle(String(localized: "Track supply"), isOn: $draft.tracksSupply.animation(.smooth(duration: 0.25)))
            }
            if draft.tracksSupply {
                rowDivider
                editorRow {
                    Text(String(localized: "Doses on hand"))
                    Spacer()
                    TextField("0", value: $draft.pillsRemaining, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80)
                }
                rowDivider
                editorRow {
                    Text(String(localized: "Warn me at"))
                    Spacer()
                    TextField("0", value: $draft.refillThreshold, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80)
                }
            }
        }
    }

    /// How much this medication may interrupt.
    ///
    /// Defaulted to Standard, so the common case needs no decision — but a
    /// vitamin and a heart medication genuinely are not the same event, and
    /// delivering them identically is what teaches people to swipe both away.
    private var remindersSection: some View {
        cardSection(
            String(localized: "Reminders"),
            footer: Text(draft.importance.explanation).foregroundStyle(.secondary)
        ) {
            // A system Picker only spreads full-width inside a Form row;
            // loose in a card it collapsed to its own content. So the row
            // is built like every other: label left, choice chip right.
            editorRow {
                Label(String(localized: "Reminders"), systemImage: "bell.badge")
                    .foregroundStyle(.primary)
                Spacer()
                Menu {
                    ForEach(MedicationImportance.allCases) { level in
                        Button {
                            draft.importance = level
                            Haptics.select()
                        } label: {
                            if draft.importance == level {
                                Label(level.title, systemImage: "checkmark")
                            } else {
                                Label(level.title, systemImage: level.systemImage)
                            }
                        }
                    }
                } label: {
                    EditorChip(text: draft.importance.title)
                }
                .menuIndicator(.hidden)
                .accessibilityLabel(String(localized: "Reminder strength"))
            }
        }
    }

    private var colorSection: some View {
        cardSection(String(localized: "Color")) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 14) {
                ForEach(MedicationColor.allCases) { swatch in
                    Button {
                        draft.color = swatch
                        Haptics.select()
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 38, height: 38)
                            .overlay {
                                if draft.color == swatch {
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(0.5), lineWidth: 2.5)
                                        .frame(width: 48, height: 48)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.displayName)
                    .accessibilityAddTraits(draft.color == swatch ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Card plumbing

    /// A titled card with hand-drawn rows — the sheet's only layout system.
    private func cardSection<Rows: View>(
        _ title: String,
        footer: Text? = nil,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            VStack(spacing: 0, content: rows)
                .cardStyle()
            if let footer {
                footer
                    .font(.footnote)
                    .padding(.horizontal, 8)
            }
        }
    }

    private var medicationFooter: Text {
        if draft.trimmedName.isEmpty {
            return Text(String(localized: "Enter the medication name to continue."))
                .foregroundStyle(Theme.due)
        } else if draft.hasInvalidDoseNumbers {
            return Text(String(localized: "Strength and amount should be numbers, like 500 or 0.5."))
                .foregroundStyle(Theme.due)
        }
        return Text(String(localized: "You can add notes, supply tracking and reminder preferences under More Options."))
            .foregroundStyle(.secondary)
    }

    private var scheduleFooter: Text? {
        // Duplicate times are impossible to store, so tell the user why the
        // picker snapped rather than letting it look broken.
        if draft.hasCollidingTimes {
            return Text(String(localized: "Two doses can't share the same time — adjust one by a minute."))
                .foregroundStyle(Theme.due)
        } else if draft.times.isEmpty {
            return Text(String(localized: "Add at least one time so reminders can be scheduled."))
                .foregroundStyle(Theme.due)
        } else if draft.hasEmptyWeekdays {
            // The picker allows deselecting all seven. Save then greys out,
            // and without this line nothing on screen said why.
            return Text(String(localized: "Choose at least one day of the week."))
                .foregroundStyle(Theme.due)
        } else if draft.hasEndBeforeStart {
            return Text(String(localized: "The end date is before the start date — move one of them."))
                .foregroundStyle(Theme.due)
        } else if draft.kind == .daily, draft.times.count > 1 {
            return Text(String(localized: "Review the suggested times and change them to match your medication instructions."))
                .foregroundStyle(.secondary)
        }
        return nil
    }

    private var supplyFooter: Text {
        // Numeric fields are typed now, so "thirty" can't silently disable
        // supply tracking the way free-text `Int(_:)` parsing did.
        if draft.isMissingSupplyCount {
            // A blank count used to persist as 0, and 0 <= 0 made a medication
            // low on supply the instant it was saved.
            return Text(String(localized: "Enter how many doses you have on hand, or turn tracking off."))
                .foregroundStyle(Theme.due)
        }
        if draft.tracksSupply, draft.refillThresholdExceedsSupply {
            return Text(String(localized: "The warning level is higher than what you have — you'll be alerted right away."))
                .foregroundStyle(Theme.due)
        }
        return Text(String(localized: "Optional. Daily Dose counts down as you log doses and warns you before you run out."))
            .foregroundStyle(.secondary)
    }

    private func daysCopy(_ count: Int) -> String {
        count == 1 ? String(localized: "1 day") : String(localized: "\(count) days")
    }

    private func hoursCopy(_ count: Int) -> String {
        count == 1 ? String(localized: "1 hour") : String(localized: "\(count) hours")
    }

    // MARK: - Time editing

    private func save() {
        guard let store, let schedule = draft.buildSchedule() else { return }
        // resolvedForm: the user's choice, else a confident detection from
        // the entry's own words ("…inhaler"), else unspecified. Never an
        // assumed pill — a wrong glyph is worse than a neutral one.
        let form = draft.resolvedForm
        if let medication {
            store.update(
                medication,
                name: draft.trimmedName, doseDetail: draft.resolvedDoseDetail, notes: draft.notes,
                colorName: draft.color.rawValue, schedule: schedule,
                pillsRemaining: draft.resolvedPills, refillThreshold: draft.resolvedThreshold,
                importance: draft.importance, form: form,
                strengthAmount: draft.parsedStrength,
                strengthUnit: draft.parsedStrength != nil ? draft.strengthUnit : nil,
                intakeAmount: draft.parsedIntake,
                productKey: draft.productKey,
                expiryDate: draft.expiryDate
            )
        } else {
            store.add(
                name: draft.trimmedName, doseDetail: draft.resolvedDoseDetail, notes: draft.notes,
                colorName: draft.color.rawValue, schedule: schedule,
                pillsRemaining: draft.resolvedPills, refillThreshold: draft.resolvedThreshold,
                importance: draft.importance, form: form,
                strengthAmount: draft.parsedStrength,
                strengthUnit: draft.parsedStrength != nil ? draft.strengthUnit : nil,
                intakeAmount: draft.parsedIntake,
                productKey: draft.productKey,
                expiryDate: draft.expiryDate
            )
        }
        Haptics.success()
        dismiss()
        onSaved?()
    }
}

// MARK: - Weekday picker

private struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    /// Ordered by the user's own locale, so a German user sees Mon–Sun and an
    /// American user sees Sun–Sat.
    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { ((first - 1 + $0) % 7) + 1 }
    }

    private var symbols: [String] { Calendar.current.shortWeekdaySymbols }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(orderedWeekdays, id: \.self) { weekday in
                let isOn = selection.contains(weekday)
                Button {
                    if isOn { selection.remove(weekday) } else { selection.insert(weekday) }
                    Haptics.select()
                } label: {
                    Text(symbols[weekday - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(
                            isOn ? Theme.accent : Color(.tertiarySystemFill),
                            in: .rect(cornerRadius: 8, style: .continuous)
                        )
                        .foregroundStyle(isOn ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Frequency picker

private struct FrequencyPicker: View {
    @Binding var draft: MedicationDraft
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingMoreSchedules = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(1...4, id: \.self) { count in
                        row(title: dailyTitle(count), isSelected: draft.kind == .daily && draft.times.count == count) {
                            draft.setDaily(dosesPerDay: count)
                        }
                    }
                }
                Section {
                    row(title: String(localized: "Specific days"), isSelected: draft.kind == .weekdays) {
                        draft.setKind(.weekdays)
                    }
                    row(title: String(localized: "Every few hours"), isSelected: draft.kind == .everyXHours) {
                        draft.setKind(.everyXHours)
                    }
                    Button {
                        isShowingMoreSchedules = true
                        Haptics.select()
                    } label: {
                        HStack {
                            Text(String(localized: "More schedules…"))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .contentShape(.rect)
                    }
                    .buttonStyle(SoftPressButtonStyle())
                }
            }
            .navigationTitle(String(localized: "How often do you take it?"))
            .navigationBarTitleDisplayMode(.inline)
            // Selecting marks the choice; leaving is the user's own decision.
            // A tap that also dismisses the sheet feels — especially to an
            // older user — like the app decided for them, and a mistap costs
            // a round trip back in. Apple's own pick-from-list screens stay
            // open with a checkmark; so do we.
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .navigationDestination(isPresented: $isShowingMoreSchedules) {
                MoreSchedulesPicker(selectedKind: draft.kind) { kind in
                    withAnimation(.smooth(duration: 0.2)) {
                        draft.setKind(kind)
                    }
                    Haptics.select()
                    dismiss()
                }
            }
        }
        // .large as well as .medium: the pushed "More schedules" page needs
        // room, and the system shrinks back down when it pops.
        .presentationDetents([.medium, .large])
    }

    private func dailyTitle(_ count: Int) -> String {
        switch count {
        case 1: String(localized: "Once a day")
        case 2: String(localized: "Twice a day")
        default: String(localized: "\(count) times a day")
        }
    }

    private func row(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { action() }
            Haptics.select()
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The uncommon scheduling patterns stay available, but never obscure the
/// everyday choices. This is depth without a separate "advanced mode".
private struct MoreSchedulesPicker: View {
    let selectedKind: ScheduleKind
    let onSelect: (ScheduleKind) -> Void

    var body: some View {
        List {
            choice(String(localized: "Every few days"), kind: .everyXDays)
            choice(String(localized: "Every month"), kind: .monthly)
            choice(String(localized: "Recurring cycle (days on / off)"), kind: .cycle)
        }
        .navigationTitle(String(localized: "More schedules"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choice(_ title: String, kind: ScheduleKind) -> some View {
        Button {
            onSelect(kind)
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if selectedKind == kind {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedKind == kind ? [.isButton, .isSelected] : .isButton)
    }
}

/// A standard, full-width row for an editor value that opens a more focused
/// configuration step. The chevron belongs to navigation; the value stays
/// quiet until the user asks to change it.
private struct EditorSummaryRow: View {
    let label: String
    let value: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(label)
                            .foregroundStyle(.primary)
                        Spacer()
                        chevron
                    }
                    Text(value)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 12) {
                    Text(label)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Text(value)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    chevron
                }
            }
        }
        .padding(.horizontal, 16)
        // 56 — the sheet's single row height, shared with every other row.
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(.rect)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Duration picker

private struct DurationPicker: View {
    @Binding var draft: MedicationDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    choice(String(localized: "Ongoing"), isSelected: draft.endDate == nil) {
                        draft.endDate = nil
                    }
                    choice(String(localized: "Ends on a date"), isSelected: draft.endDate != nil) {
                        if draft.endDate == nil {
                            draft.endDate = Calendar.current.date(byAdding: .day, value: 7, to: draft.startDate)
                        }
                    }
                } footer: {
                    Text(String(localized: "Ongoing medications remind you until you stop them. An end date suits a course like antibiotics."))
                }

                if draft.endDate != nil {
                    Section {
                        DatePicker(
                            String(localized: "Last day"),
                            selection: Binding(
                                get: { draft.endDate ?? draft.startDate },
                                set: { draft.endDate = $0 }
                            ),
                            in: draft.startDate...,
                            displayedComponents: .date
                        )
                    }
                }
            }
            .navigationTitle(String(localized: "Duration"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func choice(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { action() }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Form picker

/// "What form is it?" — the question a pharmacist asks before anything else.
/// The answer chooses the glyph on every tile and the unit the supply counter
/// speaks in. Like the frequency picker, selection stays open with a
/// checkmark; the user leaves through Done, on their own terms.
private struct FormPicker: View {
    @Binding var selection: MedicationForm?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(MedicationForm.allCases) { form in
                        row(form)
                    }
                } footer: {
                    Text(String(localized: "This sets the icon and how your supply is counted — pills, puffs, drops."))
                }
            }
            .navigationTitle(String(localized: "What form is it?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Picker rows live inside a List, which adds its own ~22pt of vertical
    /// padding. 34pt of content + 22pt of system air lands at 56 — the
    /// sheet's one rhythm, shared with the hand-built cards.
    private func row(_ form: MedicationForm) -> some View {
        Button {
            selection = form
            Haptics.select()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: form.systemImage)
                    .font(.body)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                Text(form.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if selection == form {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(.rect)
        }
        .buttonStyle(SoftPressButtonStyle())
        .accessibilityAddTraits(selection == form ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Soft press

/// The pressed-state feedback `.plain` never gives. A row that doesn't
/// answer a touch feels broken — especially on sheets where a mistap costs
/// a round trip. Opacity, not scale: scale on a full-width row reads as a
/// layout glitch, opacity reads as "I heard you".
private struct SoftPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Time wheel popover

/// The time chooser an 80-year-old can't fumble: Apple's own alarm wheel
/// inside a native popover — the system's floating card, material and
/// animation, nothing hand-rolled. ✕ cancels bottom-left, the green glass
/// ✓ confirms bottom-right; the popover never closes because a wheel moved,
/// the way the system's compact popover once did.
private struct TimeWheelPopover: View {
    let time: TimeOfDay
    /// `nil` means cancelled; a value means confirmed.
    let onDone: (TimeOfDay?) -> Void

    @State private var picked = Date()

    var body: some View {
        VStack(spacing: 8) {
            DatePicker(
                String(localized: "Time"),
                selection: $picked,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.wheel)
            .labelsHidden()

            PopoverActions(
                onCancel: { onDone(nil) },
                onConfirm: { onDone(TimeOfDay(from: picked)) }
            )
        }
        .padding(20)
        .frame(width: 320, height: 350)
        .onAppear {
            // Not `?? .now`: on the morning the clocks jump forward a 02:30
            // dose has no instant that day, and falling back to the current
            // time showed a value the user never set — which the next touch
            // would then commit.
            picked = time.nextValidDate()
        }
    }
}

// MARK: - Editor chip

/// The one capsule every inline value wears — unit, time, date. One font,
/// one padding, one fill, so the sheet reads as a single surface instead of
/// a patchwork of system and custom controls. `highlighted` marks the
/// unset invitation state ("unit") in the accent.
private struct EditorChip: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(highlighted ? Theme.accent : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color(.tertiarySystemFill), in: .capsule)
    }
}

// MARK: - Calendar popover

/// The date counterpart of the time wheel: Apple's graphical calendar —
/// big day numbers, swipe between months — inside the same native popover,
/// with the same ✕ / green ✓ grammar at the bottom.
private struct DateCalendarPopover: View {
    let date: Date
    /// `nil` means cancelled; a value means confirmed.
    let onDone: (Date?) -> Void

    @State private var picked = Date()

    var body: some View {
        VStack(spacing: 8) {
            DatePicker(
                String(localized: "Starts"),
                selection: $picked,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()

            PopoverActions(
                onCancel: { onDone(nil) },
                onConfirm: { onDone(picked) }
            )
        }
        .padding(20)
        .frame(width: 360, height: 470)
        .onAppear { picked = date }
    }
}

// MARK: - Popover actions

/// The two exits every picker popover shares: ✕ in quiet glass on the
/// left, a green glass ✓ on the right. One layout, one grammar — the row
/// can never drift between popovers.
private struct PopoverActions: View {
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack {
            Button {
                onCancel()
                Haptics.select()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 56, height: 56)
                    .contentShape(.circle)
            }
            .secondaryButton()
            .accessibilityLabel(String(localized: "Cancel"))

            Spacer()

            Button {
                onConfirm()
                Haptics.success()
            } label: {
                Image(systemName: "checkmark")
                    .font(.body.weight(.bold))
                    .frame(width: 56, height: 56)
                    .contentShape(.circle)
            }
            .prominentButton()
            .tint(Theme.taken)
            .accessibilityLabel(String(localized: "Confirm"))
        }
    }
}
