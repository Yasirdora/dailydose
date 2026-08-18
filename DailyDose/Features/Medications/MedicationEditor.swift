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
    var onSaved: (() -> Void)?

    @Environment(\.doseStore) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft = MedicationDraft()
    @State private var route: Route?
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
            Form {
                detailsSection
                scheduleSection
                moreOptionsSection

                if showsMoreOptions {
                    notesSection
                    supplySection
                    remindersSection
                    colorSection
                }
            }
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
                }
            }
            // `.task` rather than `.onAppear`: onAppear can fire again when the
            // sheet returns from a sub-sheet, which used to wipe the user's
            // in-progress edits.
            .task {
                guard !didLoad else { return }
                didLoad = true
                draft = MedicationDraft(medication: medication, prefill: prefill)
                // Editing a medication that already has notes, supply or
                // custom reminders opens with those sections expanded — the
                // screen should reflect what is configured, not hide it.
                if let medication {
                    showsMoreOptions = !medication.notes.isEmpty
                        || medication.pillsRemaining != nil
                        || medication.importance != .standard
                        || MedicationColor.named(medication.colorName) != .default
                }
            }
            .sheet(item: $route) { route in
                switch route {
                case .scanner:
                    LabelScannerSheet { result in
                        draft.apply(result)
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

    private var detailsSection: some View {
        Section {
            if LabelScannerSheet.isAvailable {
                Button { route = .scanner } label: {
                    // The fast path, dressed like one: an accent tile with
                    // the viewfinder glyph, a plain invitation, and the
                    // chevron that says "this takes you somewhere". One row,
                    // same rhythm as the Form row beneath it.
                    HStack(spacing: 14) {
                        Image(systemName: "camera.viewfinder")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34)
                            .background(Theme.accent.opacity(0.14), in: .rect(cornerRadius: 9, style: .continuous))
                            .accessibilityHidden(true)
                        Text(String(localized: "Scan medication label"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(.rect)
                }
                .buttonStyle(SoftPressButtonStyle())
                .accessibilityHint(String(localized: "Opens the camera to read the bottle's label"))
            }

            TextField(String(localized: "Medication name"), text: $draft.name)
                .textInputAutocapitalization(.words)

            // Placeholder-first: at rest each row is a single quiet line.
            // The unit appears the moment a number does — options exactly
            // when they become relevant, never before. Everything optional:
            // "the blue pill, one in the morning" is always enough to save.
            HStack(spacing: 8) {
                TextField(String(localized: "Strength (e.g. 500)"), text: $draft.strengthText)
                    .keyboardType(.decimalPad)
                if showsStrengthUnit {
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
                        // A capsule with a chevron — the way Apple marks an
                        // inline choice (Reminders' priority, Health's unit
                        // pickers). Bare text read as a label; a chip with a
                        // chevron reads as "tap me". Unset, it wears the
                        // accent: an invitation, not a placeholder.
                        HStack(spacing: 4) {
                            Text(draft.strengthUnit?.displayName ?? String(localized: "unit"))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(draft.strengthUnit == nil ? Theme.accent : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill), in: .capsule)
                    }
                    .menuIndicator(.hidden)
                    .accessibilityLabel(String(localized: "Strength unit"))
                    .transition(.opacity)
                }
            }
            // The row reserves its full height whether or not the chip is
            // showing — an appearing choice must never shift the line
            // underneath it.
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsStrengthUnit)

            HStack(spacing: 8) {
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
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsIntakeUnit)

            Button { route = .form } label: {
                // The preview card used to float above the form showing
                // placeholder content in the costume of a real entry. Its
                // one true magic — watching the tile come alive — now lives
                // here, where the choice is made: pick a form, the glyph
                // appears; change the colour below, the tile repaints.
                HStack(spacing: 14) {
                    MedicationTile(color: draft.color, form: draft.form, size: 34)
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
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(.rect)
            }
            .buttonStyle(SoftPressButtonStyle())
            .accessibilityHint(String(localized: "Choose whether this is a pill, liquid, injection or another form"))
        } header: {
            Text(String(localized: "Medication"))
        } footer: {
            if draft.trimmedName.isEmpty {
                Text(String(localized: "Enter the medication name to continue."))
                    .foregroundStyle(Theme.due)
            } else if draft.hasInvalidDoseNumbers {
                Text(String(localized: "Strength and amount should be numbers, like 500 or 0.5."))
                    .foregroundStyle(Theme.due)
            } else {
                Text(String(localized: "You can add notes, supply tracking and reminder preferences under More Options."))
            }
        }
    }

    private var scheduleSection: some View {
        Section {
            Button { route = .frequency } label: {
                EditorSummaryRow(
                    label: String(localized: "How often"),
                    value: draft.frequencySummary
                )
            }
            .buttonStyle(SoftPressButtonStyle())
            .accessibilityHint(String(localized: "Choose how often this medication is taken"))

            if draft.kind == .everyXDays {
                Stepper(value: $draft.intervalDays, in: 1...90) {
                    LabeledContent(String(localized: "Repeat every")) {
                        Text(daysCopy(draft.intervalDays))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if draft.kind == .everyXHours {
                Stepper(value: $draft.intervalHours, in: 1...24) {
                    LabeledContent(String(localized: "Repeat every")) {
                        Text(hoursCopy(draft.intervalHours))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if draft.kind == .cycle {
                Stepper(value: $draft.cycleOnDays, in: 1...90) {
                    LabeledContent(String(localized: "Take for")) {
                        Text(daysCopy(draft.cycleOnDays))
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $draft.cycleOffDays, in: 1...30) {
                    LabeledContent(String(localized: "Then pause for")) {
                        Text(daysCopy(draft.cycleOffDays))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if draft.kind == .weekdays {
                Text(String(localized: "Which days?"))
                    .font(.subheadline.weight(.medium))
                WeekdayPicker(selection: $draft.weekdays)
            }

            if draft.kind == .monthly {
                Picker(String(localized: "Day of month"), selection: $draft.dayOfMonth) {
                    ForEach(1...31, id: \.self) { day in
                        Text(day.ordinalString()).tag(day)
                    }
                }
            }

            ForEach(Array(draft.times.sorted().enumerated()), id: \.element) { index, time in
                DatePicker(
                    draft.kind == .everyXHours
                        ? String(localized: "Starting at")
                        : draft.times.count == 1
                            ? String(localized: "Time")
                            : String(localized: "Time \(index + 1)"),
                    selection: binding(for: time),
                    displayedComponents: .hourAndMinute
                )
            }

            DatePicker(
                String(localized: "Starts"),
                selection: $draft.startDate,
                displayedComponents: .date
            )

            Button { route = .duration } label: {
                EditorSummaryRow(
                    label: String(localized: "Ends"),
                    value: draft.durationSummary
                )
            }
            .buttonStyle(SoftPressButtonStyle())
            .accessibilityHint(String(localized: "Choose whether this medication has an end date"))
        } header: {
            Text(String(localized: "Schedule"))
        } footer: {
            // Duplicate times are impossible to store, so tell the user why the
            // picker snapped rather than letting it look broken.
            if draft.hasCollidingTimes {
                Text(String(localized: "Two doses can't share the same time — adjust one by a minute."))
                    .foregroundStyle(Theme.due)
            } else if draft.times.isEmpty {
                Text(String(localized: "Add at least one time so reminders can be scheduled."))
                    .foregroundStyle(Theme.due)
            } else if draft.kind == .daily, draft.times.count > 1 {
                Text(String(localized: "Review the suggested times and change them to match your medication instructions."))
            }
        }
    }

    /// A deliberate boundary: the everyday plan ends above this row. Optional
    /// personalisation remains easy to find without competing with the first
    /// successful setup.
    private var moreOptionsSection: some View {
        Section {
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
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(SoftPressButtonStyle())
            .accessibilityHint(
                showsMoreOptions
                    ? String(localized: "Hides optional medication details")
                    : String(localized: "Shows notes, supply tracking, reminder preferences and colour")
            )
        }
    }

    private var notesSection: some View {
        Section(String(localized: "Details")) {
            TextField(String(localized: "Notes (e.g. take with food)"), text: $draft.notes)
        }
    }

    private var supplySection: some View {
        Section {
            Toggle(String(localized: "Track supply"), isOn: $draft.tracksSupply.animation(.smooth(duration: 0.25)))
            if draft.tracksSupply {
                LabeledContent(String(localized: "Doses on hand")) {
                    TextField("0", value: $draft.pillsRemaining, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent(String(localized: "Warn me at")) {
                    TextField("0", value: $draft.refillThreshold, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text(String(localized: "Supply & refill"))
        } footer: {
            // Numeric fields are typed now, so "thirty" can't silently disable
            // supply tracking the way free-text `Int(_:)` parsing did.
            if draft.tracksSupply, draft.refillThresholdExceedsSupply {
                Text(String(localized: "The warning level is higher than what you have — you'll be alerted right away."))
                    .foregroundStyle(Theme.due)
            } else {
                Text(String(localized: "Optional. Daily Dose counts down as you log doses and warns you before you run out."))
            }
        }
    }

    /// How much this medication may interrupt.
    ///
    /// Defaulted to Standard, so the common case needs no decision — but a
    /// vitamin and a heart medication genuinely are not the same event, and
    /// delivering them identically is what teaches people to swipe both away.
    private var remindersSection: some View {
        Section {
            MedicationImportancePicker(importance: $draft.importance)
        } header: {
            Text(String(localized: "Reminders"))
        } footer: {
            Text(draft.importance.explanation)
        }
    }

    private var colorSection: some View {
        Section(String(localized: "Color")) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 14) {
                ForEach(MedicationColor.allCases) { swatch in
                    Button {
                        draft.color = swatch
                        Haptics.select()
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 34, height: 34)
                            .overlay {
                                if draft.color == swatch {
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(0.5), lineWidth: 2.5)
                                        .frame(width: 44, height: 44)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.displayName)
                    .accessibilityAddTraits(draft.color == swatch ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func daysCopy(_ count: Int) -> String {
        count == 1 ? String(localized: "1 day") : String(localized: "\(count) days")
    }

    private func hoursCopy(_ count: Int) -> String {
        count == 1 ? String(localized: "1 hour") : String(localized: "\(count) hours")
    }

    // MARK: - Time editing

    /// Editing a time replaces it in the set. Because `times` is a `Set`,
    /// dragging one picker onto another's value collapses them instead of
    /// creating two doses that fire at the same instant.
    private func binding(for time: TimeOfDay) -> Binding<Date> {
        Binding(
            get: { time.date(on: .now, calendar: .current) ?? .now },
            set: { newValue in
                let updated = TimeOfDay(from: newValue)
                guard updated != time else { return }
                draft.replace(time, with: updated)
            }
        )
    }

    private func save() {
        guard let store, let schedule = draft.buildSchedule() else { return }
        // resolvedForm: the user's choice, else a confident detection from
        // the entry's own words ("…inhaler"), else unspecified. Never an
        // assumed pill — a wrong glyph is worse than a neutral one.
        let form = draft.resolvedForm
        if let medication {
            store.update(
                medication,
                name: draft.name, doseDetail: draft.resolvedDoseDetail, notes: draft.notes,
                colorName: draft.color.rawValue, schedule: schedule,
                pillsRemaining: draft.resolvedPills, refillThreshold: draft.resolvedThreshold,
                importance: draft.importance, form: form,
                strengthAmount: draft.parsedStrength,
                strengthUnit: draft.parsedStrength != nil ? draft.strengthUnit : nil,
                intakeAmount: draft.parsedIntake
            )
        } else {
            store.add(
                name: draft.name, doseDetail: draft.resolvedDoseDetail, notes: draft.notes,
                colorName: draft.color.rawValue, schedule: schedule,
                pillsRemaining: draft.resolvedPills, refillThreshold: draft.resolvedThreshold,
                importance: draft.importance, form: form,
                strengthAmount: draft.parsedStrength,
                strengthUnit: draft.parsedStrength != nil ? draft.strengthUnit : nil,
                intakeAmount: draft.parsedIntake
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
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
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
                        .frame(maxWidth: .infinity, minHeight: 56)
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
            .frame(maxWidth: .infinity, minHeight: 56)
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
            .frame(maxWidth: .infinity, minHeight: 56)
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
        .frame(maxWidth: .infinity, minHeight: 52)
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
            .frame(maxWidth: .infinity, minHeight: 56)
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
