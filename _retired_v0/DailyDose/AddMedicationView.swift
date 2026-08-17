import SwiftUI
import SwiftData

struct AddMedicationView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allMeds: [Medication]

    let med: Medication?
    var prefillName = ""
    var prefillStrength = ""
    /// Optional follow-up after a successful save (dismiss happens regardless).
    var onSaved: (() -> Void)? = nil

    @State private var name = ""
    @State private var doseDetail = ""
    @State private var notes = ""

    // Schedule — frequency first, times second, duration third (Apple Alarm style).
    @State private var kind: ScheduleKind = .daily
    @State private var timeDates: [Date] = [Self.timeOfDay(8, 0)]
    @State private var weekdays: Set<Int> = Set(1...7)
    @State private var intervalDays = 2
    @State private var intervalStart = Date.now
    @State private var dayOfMonth = Calendar.current.component(.day, from: .now)
    @State private var isOngoing = true
    @State private var endDate = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now

    // Supply & refill
    @State private var trackSupply = false
    @State private var pillsRemaining = ""
    @State private var refillWarnAt = ""

    // Visual identity — deliberately last in the flow.
    @State private var colorName = "teal"

    @State private var showingScanner = false
    @State private var showingFrequency = false
    @State private var showingDuration = false

    private let weekdaySymbols = Calendar.current.shortWeekdaySymbols // 0 = Sunday

    /// Suggested clock times per daily dose count (spread across waking hours).
    private static let suggested: [[(Int, Int)]] = [
        [],
        [(8, 0)],
        [(8, 0), (20, 0)],
        [(8, 0), (14, 0), (20, 0)],
        [(8, 0), (13, 0), (18, 0), (22, 0)]
    ]

    var body: some View {
        NavigationStack {
            Form {
                // Live preview — the med takes shape as you type.
                Section {
                    HStack(spacing: 16) {
                        PillGlyph(color: MedPalette.color(for: colorName), size: 52)
                            .animation(.spring(duration: 0.3), value: colorName)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name.isEmpty ? "New medication" : name)
                                .font(.headline)
                                .foregroundStyle(name.isEmpty ? .secondary : .primary)
                            Text(doseDetail.isEmpty ? "Dose" : doseDetail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(frequencySummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !timeDates.isEmpty {
                                Text(timeStrings.map(NotificationScheduler.prettyTimeString).joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }

                Section("Medication") {
                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scan label", systemImage: "camera.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)

                    TextField("Name (e.g. Metformin)", text: $name)
                    TextField("Dose (e.g. 500 mg · 1 tablet)", text: $doseDetail)
                    TextField("Notes (e.g. Take with food)", text: $notes)
                }

                Section("Schedule") {
                    // Frequency row — Apple Health's pattern: current choice as the
                    // label, a plain blue "Change" button trailing.
                    Button { showingFrequency = true } label: {
                        HStack {
                            Text(frequencySummary).foregroundStyle(.primary)
                            Spacer()
                            Text("Change")
                                .foregroundStyle(MedPalette.accent)
                        }
                    }

                    if kind == .everyXDays {
                        Stepper("Every \(intervalDays) day\(intervalDays == 1 ? "" : "s")",
                                value: $intervalDays, in: 1...90)
                        DatePicker("Starting", selection: $intervalStart, displayedComponents: .date)
                    }

                    if kind == .weekdays {
                        weekdayChips
                    }

                    if kind == .monthly {
                        Picker("On day", selection: $dayOfMonth) {
                            ForEach(1...31, id: \.self) { d in
                                Text(Medication.ordinal(d)).tag(d)
                            }
                        }
                    }

                    ForEach(timeDates.indices, id: \.self) { i in
                        DatePicker(timeDates.count == 1 ? "Time" : "Time \(i + 1)",
                                   selection: $timeDates[i],
                                   displayedComponents: .hourAndMinute)
                    }

                    // Duration row.
                    Button { showingDuration = true } label: {
                        HStack {
                            Text("Duration").foregroundStyle(.primary)
                            Spacer()
                            Text(isOngoing ? "Ongoing" : "Until " + endDate.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Section("Supply & refill (optional)") {
                    Toggle("Track pill supply", isOn: $trackSupply)
                    if trackSupply {
                        TextField("Pills remaining", text: $pillsRemaining)
                            .keyboardType(.numberPad)
                        TextField("Warn me when this many left", text: $refillWarnAt)
                            .keyboardType(.numberPad)
                    }
                }

                Section("Color") {
                    // Apple's picker: 2×6 grid, selected dot gets a quiet gray ring
                    // (a white checkmark vanishes on yellow and tan).
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 14) {
                        ForEach(MedPalette.names, id: \.self) { colorKey in
                            Circle()
                                .fill(MedPalette.color(for: colorKey))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if colorName == colorKey {
                                        Circle()
                                            .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 2.5)
                                            .frame(width: 44, height: 44)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture { colorName = colorKey }
                                .accessibilityLabel(colorKey)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle(med == nil ? "Add Medication" : "Edit Medication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Apple's own pattern: white ✓ on a filled accent circle.
                    Button { save() } label: {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.bold))
                    }
                    .tint(MedPalette.accent)
                    .disabled(!canSave)
                    .accessibilityLabel("Save")
                }
            }
            .onAppear(perform: loadExisting)
            .sheet(isPresented: $showingScanner) { scannerSheet }
            .sheet(isPresented: $showingFrequency) { frequencySheet }
            .sheet(isPresented: $showingDuration) { durationSheet }
        }
    }

    // MARK: - Schedule helpers

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !timeDates.isEmpty
            && (kind != .weekdays || !weekdays.isEmpty)
    }

    private var frequencySummary: String {
        switch kind {
        case .daily:
            switch timeDates.count {
            case 1: return "Once a day"
            case 2: return "Twice a day"
            case 3: return "3 times a day"
            case 4: return "4 times a day"
            default: return "\(timeDates.count) times a day"
            }
        case .everyXDays:
            return intervalDays == 1 ? "Every day" : "Every \(intervalDays) days"
        case .weekdays:
            let days = weekdays.sorted()
            if days.count == 7 { return "Every day" }
            if days.isEmpty { return "No days set" }
            return days.map { weekdaySymbols[$0 - 1] }.joined(separator: " · ")
        case .monthly:
            return "Monthly on the \(Medication.ordinal(dayOfMonth))"
        }
    }

    private var timeStrings: [String] {
        timeDates.map(NotificationScheduler.timeString(from:)).sorted()
    }

    private var weekdayChips: some View {
        HStack(spacing: 8) {
            ForEach(1...7, id: \.self) { weekday in
                let on = weekdays.contains(weekday)
                Text(weekdaySymbols[weekday - 1])
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(on ? MedPalette.accent : Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(on ? .white : .secondary)
                    .onTapGesture {
                        if on { weekdays.remove(weekday) } else { weekdays.insert(weekday) }
                    }
            }
        }
        .padding(.vertical, 2)
    }

    static func timeOfDay(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? .now
    }

    private static func parseTime(_ string: String) -> Date {
        let parts = string.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return timeOfDay(8, 0) }
        return timeOfDay(parts[0], parts[1])
    }

    /// Grows/shrinks the times list to `count`, suggesting sensible clock times
    /// for newly added slots while preserving times the user already set.
    private func adjustTimes(to count: Int) {
        let target = max(1, count)
        if timeDates.count > target {
            timeDates = Array(timeDates.prefix(target))
        } else {
            let sugg = Self.suggested[min(target, 4)]
            while timeDates.count < target {
                let s = sugg[min(timeDates.count, sugg.count - 1)]
                timeDates.append(Self.timeOfDay(s.0, s.1))
            }
        }
    }

    private func applyFrequency(_ newKind: ScheduleKind, timesPerDay: Int? = nil) {
        withAnimation {
            kind = newKind
            if newKind == .daily {
                adjustTimes(to: timesPerDay ?? min(max(timeDates.count, 1), 4))
            } else {
                adjustTimes(to: 1) // sparse schedules get one time of day
            }
        }
    }

    // MARK: - Sheets

    private var scannerSheet: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if LabelScannerView.isUsable {
                    LabelScannerView(store: RecognizedItemsStore()) { transcript in
                        applyScan(transcript)
                        showingScanner = false
                    }
                } else {
                    ScannerUnavailableView()
                }
            }
            .ignoresSafeArea()

            // Floating close affordance — Apple Camera-style, no nav bar.
            Button { showingScanner = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
            }
            .glassCircleButton()
            .padding(.leading, 16)
            .padding(.top, 14)
            .accessibilityLabel("Close")
        }
    }

    private var frequencySheet: some View {
        NavigationStack {
            List {
                Section {
                    frequencyRow("Once a day", kind: .daily, timesPerDay: 1)
                    frequencyRow("Twice a day", kind: .daily, timesPerDay: 2)
                    frequencyRow("3 times a day", kind: .daily, timesPerDay: 3)
                    frequencyRow("4 times a day", kind: .daily, timesPerDay: 4)
                }
                Section {
                    frequencyRow("Every X days", kind: .everyXDays)
                    frequencyRow("Specific days of the week", kind: .weekdays)
                    frequencyRow("Every month", kind: .monthly)
                }
            }
            .navigationTitle("Frequency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingFrequency = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func frequencyRow(_ title: String, kind rowKind: ScheduleKind, timesPerDay: Int? = nil) -> some View {
        let selected = kind == rowKind && (timesPerDay == nil || timeDates.count == timesPerDay)
        return Button {
            applyFrequency(rowKind, timesPerDay: timesPerDay)
            showingFrequency = false
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MedPalette.accent)
                }
            }
        }
    }

    private var durationSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        withAnimation { isOngoing = true }
                    } label: {
                        HStack {
                            Text("Ongoing").foregroundStyle(.primary)
                            Spacer()
                            if isOngoing {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(MedPalette.accent)
                            }
                        }
                    }
                    Button {
                        withAnimation { isOngoing = false }
                    } label: {
                        HStack {
                            Text("Ends on a date").foregroundStyle(.primary)
                            Spacer()
                            if !isOngoing {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(MedPalette.accent)
                            }
                        }
                    }
                } footer: {
                    Text("Ongoing medications remind you until you stop them. An end date suits courses like antibiotics.")
                }
                if !isOngoing {
                    Section {
                        DatePicker("End date", selection: $endDate, in: Date.now..., displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("Duration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingDuration = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Scan, load, save

    /// Fills name + strength from a tapped OCR fragment, with a little delight.
    private func applyScan(_ transcript: String) {
        let parsed = LabelScanParser.parse(transcript)
        withAnimation(.spring(duration: 0.3)) {
            if !parsed.name.isEmpty { name = parsed.name }
            if !parsed.strength.isEmpty { doseDetail = parsed.strength }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func loadExisting() {
        guard let med else {
            // Fresh form — apply any prefill (e.g. from the camera tab).
            name = prefillName
            doseDetail = prefillStrength
            return
        }
        name = med.name
        doseDetail = med.doseDetail
        notes = med.notes
        colorName = med.colorName

        if let raw = med.scheduleKindRaw, let stored = ScheduleKind(rawValue: raw) {
            kind = stored
        } else {
            // Legacy med: all seven weekdays reads as "every day".
            kind = med.weekdays.count == 7 ? .daily : .weekdays
        }
        timeDates = med.times.sorted().map(Self.parseTime)
        if timeDates.isEmpty { timeDates = [Self.timeOfDay(8, 0)] }
        weekdays = Set(med.weekdays)
        intervalDays = med.intervalDays ?? 2
        intervalStart = med.startDate ?? .now
        dayOfMonth = med.dayOfMonth ?? Calendar.current.component(.day, from: med.startDate ?? med.createdAt)
        isOngoing = med.endDate == nil
        endDate = med.endDate ?? Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now

        trackSupply = med.pillsRemaining != nil
        pillsRemaining = med.pillsRemaining.map(String.init) ?? ""
        refillWarnAt = med.refillWarnAt.map(String.init) ?? ""
    }

    private func save() {
        // Scanned text can contain raw newlines — keep stored fields single-line.
        func cleaned(_ string: String) -> String {
            string.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        let trimmedName = cleaned(name)
        let cleanDose = cleaned(doseDetail)
        let cleanNotes = cleaned(notes)
        let pills = trackSupply ? Int(pillsRemaining) : nil
        let warnAt = trackSupply ? Int(refillWarnAt) : nil
        let sortedTimes = timeStrings
        let finalWeekdays = kind == .weekdays ? weekdays.sorted() : Array(1...7)
        let finalInterval = kind == .everyXDays ? intervalDays : nil
        let finalStart = kind == .everyXDays ? intervalStart : nil
        let finalDayOfMonth = kind == .monthly ? dayOfMonth : nil
        let finalEnd = isOngoing ? nil : endDate

        if let med {
            med.name = trimmedName
            med.doseDetail = cleanDose
            med.notes = cleanNotes
            med.colorName = colorName
            med.times = sortedTimes
            med.weekdays = finalWeekdays
            med.scheduleKindRaw = kind.rawValue
            med.intervalDays = finalInterval
            med.startDate = finalStart
            med.dayOfMonth = finalDayOfMonth
            med.endDate = finalEnd
            med.pillsRemaining = pills
            med.refillWarnAt = warnAt
        } else {
            let new = Medication(name: trimmedName,
                                 doseDetail: cleanDose,
                                 notes: cleanNotes,
                                 colorName: colorName,
                                 times: sortedTimes,
                                 weekdays: finalWeekdays,
                                 pillsRemaining: pills,
                                 refillWarnAt: warnAt,
                                 scheduleKind: kind,
                                 intervalDays: finalInterval,
                                 startDate: finalStart,
                                 dayOfMonth: finalDayOfMonth,
                                 endDate: finalEnd)
            context.insert(new)
        }
        try? context.save()
        Task { await NotificationScheduler.shared.rescheduleAll(meds: allMeds) }
        dismiss()
        // Lets callers follow up after a successful save (the Camera tab
        // uses this to return to Today instead of stranding the user).
        onSaved?()
    }
}

#Preview {
    AddMedicationView(med: nil)
        .modelContainer(sharedModelContainer)
}
