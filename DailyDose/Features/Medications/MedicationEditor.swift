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

    private enum Route: String, Identifiable {
        case scanner, frequency, duration
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                previewSection
                detailsSection
                scheduleSection
                supplySection
                remindersSection
                colorSection
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
                }
            }
        }
    }

    // MARK: - Sections

    private var previewSection: some View {
        Section {
            HStack(spacing: 16) {
                MedicationTile(color: draft.color, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.name.isEmpty ? String(localized: "New medication") : draft.name)
                        .font(.headline)
                        .foregroundStyle(draft.name.isEmpty ? .secondary : .primary)
                    Text(draft.doseDetail.isEmpty ? String(localized: "Dose") : draft.doseDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(draft.frequencySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !draft.times.isEmpty {
                        Text(draft.times.sorted().map { $0.formatted() }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "Preview: \(draft.accessibilitySummary)"))
        }
    }

    private var detailsSection: some View {
        Section(String(localized: "Medication")) {
            if LabelScannerSheet.isAvailable {
                Button {
                    route = .scanner
                } label: {
                    Label(String(localized: "Scan label"), systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .secondaryButton()
            }

            TextField(String(localized: "Name"), text: $draft.name)
                .textInputAutocapitalization(.words)
            TextField(String(localized: "Dose (e.g. 500 mg, 1 tablet)"), text: $draft.doseDetail)
            TextField(String(localized: "Notes (e.g. take with food)"), text: $draft.notes)
        }
    }

    private var scheduleSection: some View {
        Section {
            Button { route = .frequency } label: {
                LabeledContent(String(localized: "Frequency")) {
                    Text(draft.frequencySummary)
                }
            }
            .foregroundStyle(.primary)

            if draft.kind == .everyXDays {
                Stepper(value: $draft.intervalDays, in: 1...90) {
                    Text(String(localized: "Every \(draft.intervalDays) days"))
                }
            }

            if draft.kind == .everyXHours {
                Stepper(value: $draft.intervalHours, in: 1...24) {
                    Text(draft.intervalHours == 1
                         ? String(localized: "Every hour")
                         : String(localized: "Every \(draft.intervalHours) hours"))
                }
            }

            if draft.kind == .cycle {
                Stepper(value: $draft.cycleOnDays, in: 1...90) {
                    Text(String(localized: "Take for \(draft.cycleOnDays) days"))
                }
                Stepper(value: $draft.cycleOffDays, in: 1...30) {
                    Text(String(localized: "Break for \(draft.cycleOffDays) days"))
                }
            }

            if draft.kind == .weekdays {
                WeekdayPicker(selection: $draft.weekdays)
            }

            if draft.kind == .monthly {
                Picker(String(localized: "On day"), selection: $draft.dayOfMonth) {
                    ForEach(1...31, id: \.self) { day in
                        Text(day.ordinalString()).tag(day)
                    }
                }
            }

            ForEach(Array(draft.times.sorted().enumerated()), id: \.element) { index, time in
                DatePicker(
                    draft.kind == .everyXHours
                        ? String(localized: "First dose at")
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
                LabeledContent(String(localized: "Duration")) {
                    Text(draft.durationSummary)
                }
            }
            .foregroundStyle(.primary)
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
            }
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
        if let medication {
            store.update(
                medication,
                name: draft.name, doseDetail: draft.doseDetail, notes: draft.notes,
                colorName: draft.color.rawValue, schedule: schedule,
                pillsRemaining: draft.resolvedPills, refillThreshold: draft.resolvedThreshold,
                importance: draft.importance
            )
        } else {
            store.add(
                name: draft.name, doseDetail: draft.doseDetail, notes: draft.notes,
                colorName: draft.color.rawValue, schedule: schedule,
                pillsRemaining: draft.resolvedPills, refillThreshold: draft.resolvedThreshold,
                importance: draft.importance
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
                    row(title: String(localized: "Every X hours"), isSelected: draft.kind == .everyXHours) {
                        draft.setKind(.everyXHours)
                    }
                    row(title: String(localized: "Every X days"), isSelected: draft.kind == .everyXDays) {
                        draft.setKind(.everyXDays)
                    }
                    row(title: String(localized: "Specific days of the week"), isSelected: draft.kind == .weekdays) {
                        draft.setKind(.weekdays)
                    }
                    row(title: String(localized: "Every month"), isSelected: draft.kind == .monthly) {
                        draft.setKind(.monthly)
                    }
                    row(title: String(localized: "Recurring cycle (days on / off)"), isSelected: draft.kind == .cycle) {
                        draft.setKind(.cycle)
                    }
                }
            }
            .navigationTitle(String(localized: "Frequency"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
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
            dismiss()
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
