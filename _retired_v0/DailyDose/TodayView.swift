import SwiftUI
import SwiftData
import UserNotifications

struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Medication.createdAt) private var meds: [Medication]

    @State private var selectedDay = Date.now
    @State private var now = Date.now
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var toastMessage: String?
    @State private var toastIcon = "checkmark"
    @State private var showingCalendar = false
    @State private var showingSettings = false
    @State private var addingNew = false
    @State private var presentedDose: Dose?

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var isToday: Bool { Calendar.current.isDateInToday(selectedDay) }
    private var doses: [Dose] { DoseEngine.doses(on: selectedDay, meds: meds, now: now) }
    private var pendingDoses: [Dose] {
        doses.filter { dose in
            if case .logged = dose.state { return false }
            return true
        }
    }
    private var loggedDoses: [Dose] {
        doses.filter { dose in
            if case .logged = dose.state { return true }
            return false
        }
    }
    /// Every dose for the day is logged — the moment the page should celebrate
    /// and pivot to tomorrow instead of staring at finished cards.
    private var dayComplete: Bool { isToday && !doses.isEmpty && pendingDoses.isEmpty }
    private var tomorrowDoses: [Dose] {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) else { return [] }
        return DoseEngine.doses(on: tomorrow, meds: meds, now: now)
    }
    /// Actionable (due/overdue) first, then by time of day.
    private var sortedPending: [Dose] {
        pendingDoses.sorted { a, b in
            let aActionable = a.state == .due || a.state == .overdue
            let bActionable = b.state == .due || b.state == .overdue
            if aActionable != bActionable { return aActionable }
            return a.scheduledAt < b.scheduledAt
        }
    }
    private var lowSupplyMeds: [Medication] {
        meds.filter { med in
            guard med.isActive, let pills = med.pillsRemaining, let warnAt = med.refillWarnAt else { return false }
            return pills <= warnAt
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }

    /// The ambient "sky" behind the header — the page breathes with the hour,
    /// the way Weather's background reflects the world outside.
    /// Sunrise peach → clear day blue → lavender dusk → deep night indigo.
    private var ambientColor: Color {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<9:   return Color(red: 1.00, green: 0.62, blue: 0.42) // sunrise
        case 9..<12:  return Color(red: 0.55, green: 0.78, blue: 1.00) // morning sky
        case 12..<17: return Color(red: 0.45, green: 0.72, blue: 1.00) // clear day
        case 17..<20: return Color(red: 0.72, green: 0.58, blue: 0.98) // dusk lavender
        case 20..<22: return Color(red: 0.45, green: 0.42, blue: 0.85) // late evening
        default:      return Color(red: 0.28, green: 0.32, blue: 0.66) // night indigo
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    WeekStrip(selectedDay: $selectedDay, meds: meds, now: now)

                    // Wayfinding: the week strip can take you anywhere — always
                    // offer the way home (elders tap days by accident and get lost).
                    if !isToday {
                        Button {
                            withAnimation(.spring(duration: 0.3)) { selectedDay = .now }
                            Haptics.light()
                        } label: {
                            Label("Return to Today", systemImage: "arrow.uturn.backward")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(MedPalette.accent)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if notificationStatus == .notDetermined {
                        notificationNudge
                    }
                    if !lowSupplyMeds.isEmpty {
                        refillCard
                    }

                    if meds.isEmpty {
                        emptyState
                    } else {
                        // 1. What still needs action — the reason this page exists.
                        if !sortedPending.isEmpty {
                            sectionLabel(isToday ? "To take" : "Scheduled")
                            ForEach(sortedPending) { dose in
                                DoseCard(dose: dose, now: now,
                                         onLog: { status in log(dose: dose, status: status) },
                                         onTap: { presentedDose = dose })
                                .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity),
                                                        removal: .opacity))
                            }
                        }

                        // 2. Done for the day — celebrate, don't just stop listing.
                        if dayComplete {
                            completeHero
                        } else if !loggedDoses.isEmpty {
                            sectionLabel("Done")
                            ForEach(loggedDoses) { dose in
                                DoseCard(dose: dose, now: now,
                                         onLog: { status in log(dose: dose, status: status) },
                                         onTap: { presentedDose = dose })
                            }
                        }

                        // 3. The night pivot: when today is finished (or has nothing),
                        // tomorrow's plan is the most useful thing on screen.
                        if isToday && pendingDoses.isEmpty {
                            if doses.isEmpty {
                                nothingScheduled
                            }
                            if !tomorrowDoses.isEmpty {
                                sectionLabel("Tomorrow")
                                ForEach(tomorrowDoses) { dose in
                                    DoseCard(dose: dose, now: now,
                                             onLog: { status in log(dose: dose, status: status) },
                                             onTap: { presentedDose = dose })
                                }
                            }
                        } else if !isToday && doses.isEmpty {
                            nothingScheduled
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            // The ambient sky: a whisper of color that fades into the page,
            // reacting to the hour (Weather's trick, kept quiet).
            .background(alignment: .top) {
                LinearGradient(colors: [ambientColor.opacity(0.28),
                                        ambientColor.opacity(0.10),
                                        .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 340)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 1.2), value: ambientColor)
            }
            // Same pinned chrome as every other page: real navigation bar.
            // The + stands alone in its own circle; calendar + settings share
            // one pill to its right — [(+) (📅 ⋮)].
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Haptics.light()
                        addingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add medication")
                }
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Haptics.light()
                        showingCalendar = true
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Open calendar")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Haptics.light()
                        showingSettings = true
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Open settings")
                }
            }
            .overlay(alignment: .top) {
                if let toastMessage {
                    ToastView(message: toastMessage, systemImage: toastIcon)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .task { await refresh() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refresh() }
            }
            .onReceive(ticker) { now = $0 }
            .sheet(isPresented: $showingCalendar) {
                CalendarSheetView(selectedDay: $selectedDay)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $addingNew) {
                AddMedicationView(med: nil)
            }
            .sheet(item: $presentedDose) { dose in
                DoseDetailSheet(dose: dose,
                                onLog: { status in log(dose: dose, status: status) },
                                onUndo: { undo(dose: dose) })
            }
        }
    }

    // MARK: - Header

    /// The date, plus — when looking at today — the one number that matters:
    /// how many doses are still ahead of you.
    private var subtitle: String {
        let date = selectedDay.formatted(.dateTime.month(.wide).day().year())
        guard isToday, !meds.isEmpty else { return date }
        let left = pendingDoses.count
        if doses.isEmpty { return date }
        return left == 0 ? "\(date) · all done" : "\(date) · \(left) left"
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isToday ? greeting : selectedDay.formatted(.dateTime.weekday(.wide)))
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    // MARK: - Cards

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }

    /// The "day complete" moment — closure at night, not a graveyard of logged cards.
    private var completeHero: some View {
        let takenCount = loggedDoses.filter { dose in
            if case .logged(.taken) = dose.state { return true }
            return false
        }.count
        let allTaken = takenCount == doses.count
        return VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((allTaken ? Color.green : Color.orange).opacity(0.14))
                    .frame(width: 72, height: 72)
                Image(systemName: allTaken ? "checkmark.circle.fill" : "moon.stars.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(allTaken ? .green : .orange)
            }
            Text(allTaken
                 ? "All \(doses.count) dose\(doses.count == 1 ? "" : "s") taken"
                 : "\(takenCount) of \(doses.count) doses taken")
                .font(.title3.weight(.bold))
            Text("Nothing left today — tomorrow's plan is below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .cardStyle()
    }

    private var notificationNudge: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Enable reminders", systemImage: "bell.badge.fill")
                .font(.headline)
            Text("Time-sensitive alerts that break through Focus modes — and a follow-up nudge if a dose goes unlogged.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task {
                    let granted = await NotificationScheduler.shared.requestAuthorization()
                    if granted { await NotificationScheduler.shared.rescheduleAll(meds: meds) }
                    notificationStatus = await NotificationScheduler.shared.authorizationStatus()
                }
            } label: {
                Text("Turn on notifications")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .prominentButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var refillCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Refill soon", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            ForEach(lowSupplyMeds) { med in
                Text("\(med.name) — only \(med.pillsRemaining ?? 0) pill\((med.pillsRemaining ?? 0) == 1 ? "" : "s") left.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            PillGlyph(color: MedPalette.accent, size: 64)
            Text("No medications yet")
                .font(.title3.weight(.semibold))
            Text("Add your first medication in the Meds tab.\nUnlimited, free, and stored only on this device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .cardStyle()
    }

    private var nothingScheduled: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36))
                .foregroundStyle(MedPalette.accent)
            Text("Nothing scheduled for this day")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .cardStyle()
    }

    // MARK: - Actions

    private func log(dose: Dose, status: DoseStatus) {
        withAnimation(.spring(duration: 0.35)) {
            DoseEngine.log(med: dose.medication, at: dose.scheduledAt, status: status, context: context)
        }
        if status == .taken { Haptics.success() } else { Haptics.warning() }
        toastIcon = status == .taken ? "checkmark" : "forward"
        showToast(status == .taken ? "Taken" : "Skipped")
        Task {
            await NotificationScheduler.shared.cancelFollowUps(medUUID: dose.medication.uuid)
            await NotificationScheduler.shared.refreshFollowUps(meds: meds)
        }
    }

    private func undo(dose: Dose) {
        withAnimation(.spring(duration: 0.35)) {
            DoseEngine.unlog(med: dose.medication, at: dose.scheduledAt, context: context)
        }
        Haptics.light()
        toastIcon = "arrow.uturn.backward"
        showToast("Undone")
        Task { await NotificationScheduler.shared.refreshFollowUps(meds: meds) }
    }

    private func showToast(_ message: String) {
        withAnimation(.spring(duration: 0.3)) { toastMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.spring(duration: 0.3)) { toastMessage = nil }
        }
    }

    private func refresh() async {
        DoseEngine.recordMissedDoses(meds: meds, context: context)
        notificationStatus = await NotificationScheduler.shared.authorizationStatus()
        await NotificationScheduler.shared.refreshFollowUps(meds: meds)
    }
}

// MARK: - Week strip

struct WeekStrip: View {
    @Binding var selectedDay: Date
    let meds: [Medication]
    let now: Date

    private var days: [Date] {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .weekOfYear, for: selectedDay)?.start ?? selectedDay
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let isToday = Calendar.current.isDateInToday(day)
                let isSelected = Calendar.current.isDate(day, inSameDayAs: selectedDay)
                let progress = DoseEngine.dayProgress(on: day, meds: meds, now: now)
                VStack(spacing: 6) {
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    DayRing(taken: progress.taken, total: progress.total, size: 34, lineWidth: 4)
                        .overlay {
                            Text(day.formatted(.dateTime.day()))
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(isToday ? MedPalette.accent : .primary)
                        }
                        .background {
                            if isSelected {
                                Circle().stroke(MedPalette.accent, lineWidth: 1.5).padding(-4)
                            }
                        }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(duration: 0.3)) { selectedDay = day }
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
        }
        .padding(.vertical, 12)
        .cardStyle(cornerRadius: 20, interactive: true)
    }
}

// MARK: - Dose card

/// Minimal at a glance — tile, name, one line of detail, time, one status chip.
/// Hero actions appear ONLY for the dose that needs you right now; everything
/// else (undo, late-logging, bookkeeping) lives behind a tap on the card,
/// which opens the dose detail sheet. Apple rule: the list shows state,
/// the detail handles action.
struct DoseCard: View {
    let dose: Dose
    let now: Date
    let onLog: (DoseStatus) -> Void
    let onTap: () -> Void

    private var med: Medication { dose.medication }
    private var medColor: Color { MedPalette.color(for: med.colorName) }

    /// Only the dose that can still be acted on earns the loud buttons.
    private var needsAction: Bool {
        dose.state == .due
            || (dose.state == .overdue && Calendar.current.isDateInToday(dose.scheduledAt))
    }

    var body: some View {
        HStack(spacing: 14) {
            // Color-identity tile. Taken doses earn a green badge.
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(medColor.gradient)
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: "pill.fill")
                        .font(.body)
                        .foregroundStyle(.white)
                }
                .overlay(alignment: .bottomTrailing) {
                    if case .logged(.taken) = dose.state {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.green)
                            .background(Circle().fill(.white).padding(-2))
                            .offset(x: 4, y: 4)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(med.displayName)
                    .font(.headline)
                    .lineLimit(1)
                let detail = LabelScanParser.flatten(
                    [med.doseDetail, med.notes].filter { !$0.isEmpty }.joined(separator: " · "))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(dose.scheduledAt.formatted(date: .omitted, time: .shortened))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(needsAction ? .primary : .secondary)
                statusChip
            }
            // The Reminders pattern: one satisfying green circle marks the
            // dose taken. Everything else (skip, undo, bookkeeping) lives
            // behind a tap on the card. No walls of pill buttons.
            if needsAction {
                Button { onLog(.taken) } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Color.green.gradient, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark \(med.displayName) as taken")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.light()
            onTap()
        }
        .padding(16)
        .cardStyle(interactive: true)
        .overlay {
            if needsAction {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(medColor.opacity(0.45), lineWidth: 1.5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Tap for details and actions")
    }

    @ViewBuilder
    private var statusChip: some View {
        switch dose.state {
        case .upcoming:
            StatusChip(text: dose.scheduledAt.formatted(.relative(presentation: .named)).capitalized,
                       color: .secondary, systemImage: nil)
        case .due:
            StatusChip(text: "Due now", color: .orange, systemImage: "bell.fill")
        case .overdue:
            if Calendar.current.isDateInToday(dose.scheduledAt) {
                StatusChip(text: "Late", color: .orange, systemImage: "clock.exclamationmark")
            } else {
                StatusChip(text: "Missed", color: .red, systemImage: "exclamationmark")
            }
        case .logged(.taken):
            StatusChip(text: "Taken", color: .green, systemImage: "checkmark.circle.fill")
        case .logged(.skipped):
            StatusChip(text: "Skipped", color: .secondary, systemImage: nil)
        case .logged(.missed):
            StatusChip(text: "Missed", color: .red, systemImage: nil)
        }
    }
}

// MARK: - Dose detail sheet

/// Everything the minimal card withholds: full schedule context and every
/// action that isn't a right-now call to action (undo, late logging,
/// correcting a mistake). One tap on any dose card opens this.
struct DoseDetailSheet: View {
    let dose: Dose
    let onLog: (DoseStatus) -> Void
    let onUndo: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var med: Medication { dose.medication }
    private var medColor: Color { MedPalette.color(for: med.colorName) }

    private var statusText: (text: String, color: Color) {
        switch dose.state {
        case .upcoming: return ("Upcoming", .secondary)
        case .due: return ("Due now", .orange)
        case .overdue:
            return Calendar.current.isDateInToday(dose.scheduledAt)
                ? ("Late — can still be taken", .orange)
                : ("Missed", .red)
        case .logged(.taken): return ("Taken", .green)
        case .logged(.skipped): return ("Skipped", .secondary)
        case .logged(.missed): return ("Missed", .red)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(medColor.gradient)
                            .frame(width: 48, height: 48)
                            .overlay {
                                Image(systemName: "pill.fill")
                                    .font(.body)
                                    .foregroundStyle(.white)
                            }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LabelScanParser.flatten(med.name))
                                .font(.headline)
                            let detail = LabelScanParser.flatten(
                                [med.doseDetail, med.notes].filter { !$0.isEmpty }.joined(separator: " · "))
                            if !detail.isEmpty {
                                Text(detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    LabeledContent("Scheduled") {
                        Text(dose.scheduledAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Time") {
                        Text(dose.scheduledAt.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Status") {
                        Text(statusText.text)
                            .foregroundStyle(statusText.color)
                    }
                }

                Section {
                    switch dose.state {
                    case .due, .overdue:
                        Button {
                            act(.taken)
                        } label: {
                            Label("Log as taken", systemImage: "checkmark")
                                .foregroundStyle(.green)
                        }
                        Button {
                            act(.skipped)
                        } label: {
                            Text("Mark as skipped")
                                .foregroundStyle(.secondary)
                        }
                    case .logged(.taken):
                        Button("Undo — back to unlogged") {
                            undoLog()
                        }
                        .foregroundStyle(MedPalette.accent)
                    case .logged(.skipped), .logged(.missed):
                        Button {
                            act(.taken)
                        } label: {
                            Label("Mark as taken", systemImage: "checkmark")
                                .foregroundStyle(.green)
                        }
                        Button("Undo log") {
                            undoLog()
                        }
                        .foregroundStyle(MedPalette.accent)
                    case .upcoming:
                        Text("Not due yet — the reminder will come to you.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(LabelScanParser.flatten(med.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton()
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func act(_ status: DoseStatus) {
        onLog(status)
        dismiss()
    }

    private func undoLog() {
        onUndo()
        dismiss()
    }
}
