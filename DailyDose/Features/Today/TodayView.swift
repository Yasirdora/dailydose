import SwiftUI
import SwiftData
import UserNotifications

/// A tap on a reminder banner, delivered into the Doses tab.
///
/// Carries the day as well as the medication: a banner tapped from the
/// Lock Screen refers to the dose it was delivered for, and the app should
/// open on that day — not dump the user on today with no context.
struct TodayDeepLink: Equatable {
    let medicationID: String
    let day: Date?
}

struct TodayView: View {
    @Binding var deepLink: TodayDeepLink?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model: TodayModel?
    @State private var toast: Toast?
    @State private var presentedDose: ResolvedDose?
    /// Medication whose day sheet is open — plus WHICH day's card opened it.
    /// Tapping tomorrow's card for a medication that also runs today must
    /// open tomorrow's card; resolving by id across both days used to find
    /// today's first, and the user concluded tomorrow's doses were already
    /// taken. Re-read from the rebuilt model on every log, so the sheet's
    /// rows update in place instead of showing a stale snapshot.
    @State private var daySheetTarget: DaySheetTarget?

    struct DaySheetTarget: Equatable {
        let medicationID: String
        let isTomorrow: Bool
    }
    @State private var isShowingDaySummary = false
    @State private var route: Route?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// Bumped when a sheet closes — see the add button's `.id` in `toolbar`.
    @State private var toolbarReset = 0
    /// Increments once per taken dose — each value is one BreathBloom.
    @State private var breath = 0
    /// Once a bloom has dissolved it leaves the view tree entirely, so the
    /// resting app renders zero animation frames.
    @State private var breathDone = 0
    /// A store write that failed, shown plainly. Believing a dose was logged
    /// when it wasn't is the one failure this app can never have silently.
    @State private var storeError: String?

    private enum Route: String, Identifiable {
        case calendar, add
        var id: String { rawValue }
    }

    /// One minute is enough: the only thing time changes on this screen is
    /// whether a dose has crossed from upcoming to due, and those boundaries
    /// are 15 and 120 minutes wide.
    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    Color.clear
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toast($toast)
            .alert(
                String(localized: "Couldn't Save"),
                isPresented: Binding(
                    get: { storeError != nil },
                    set: { if !$0 { storeError = nil } }
                ),
                presenting: storeError
            ) { _ in
                Button(String(localized: "OK"), role: .cancel) {}
            } message: { detail in
                Text(detail)
            }
        }
        .task { start() }
        .onChange(of: deepLink) { _, link in apply(link) }
        .onReceive(ticker) { model?.rebuild(now: $0) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model?.rebuild()
            Task { notificationStatus = await environment.notificationService.authorizationStatus() }
        }
        // A store revision, not the model array: SwiftData compares by
        // persistent identity, so an edited schedule produces an *equal*
        // array and the screen would keep showing a time the store no
        // longer holds. Every write bumps the revision; every bump rebuilds.
        .onChange(of: environment.store.revision) { _, _ in model?.rebuild() }
        .sheet(item: $route) { route in
            switch route {
            case .calendar:
                CalendarSheet(selectedDay: Binding(
                    get: { model?.selectedDay ?? .now },
                    set: { model?.selectedDay = $0 }
                ))
            case .add:
                MedicationEditor(medication: nil)
            }
        }
        .onChange(of: route) { _, new in
            if new == nil { toolbarReset += 1 }
        }
        .sheet(item: $presentedDose) { dose in
            DoseDetailSheet(
                dose: dose,
                now: model?.now ?? .now,
                window: model?.window ?? .default,
                onLog: { log(dose, as: $0) },
                onUndo: { undo(dose) }
            )
        }
        .sheet(isPresented: Binding(
            get: { daySheetTarget != nil },
            set: { if !$0 { daySheetTarget = nil } }
        )) {
            if let model, let target = daySheetTarget {
                let cards = target.isTomorrow
                    ? DayPlan(doses: model.tomorrow).cards
                    : model.day.cards
                if let card = cards.first(where: { $0.medication.id == target.medicationID }) {
                    MedicationDaySheet(
                        card: card,
                        now: model.now,
                        window: model.window,
                        onLog: { log($0, as: $1, at: $2) },
                        onUndo: { undo($0) }
                    )
                }
            }
        }
        .sheet(isPresented: $isShowingDaySummary) {
            if let model {
                DaySummarySheet(plan: model.day, day: model.selectedDay)
            }
        }
    }

    private func start() {
        if model == nil {
            model = TodayModel(store: environment.store)
        }
        model?.rebuild()
        apply(deepLink)
        Task { notificationStatus = await environment.notificationService.authorizationStatus() }
    }

    /// Opens the linked day and lets the ring glow briefly, then clears it.
    /// A highlight that never clears makes the *next* deep link
    /// indistinguishable from this one.
    private func apply(_ link: TodayDeepLink?) {
        guard let link, let model else { return }
        if let day = link.day {
            model.selectedDay = day
            model.rebuild()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if deepLink == link { deepLink = nil }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ model: TodayModel) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                header(model)

                WeekPager(model: model) { date in
                    withAnimation(.smooth(duration: 0.3)) { model.selectedDay = date }
                }

                if notificationStatus == .notDetermined, !model.isEmpty {
                    NotificationNudge {
                        Task {
                            await environment.notificationService.requestAuthorization()
                            notificationStatus = await environment.notificationService.authorizationStatus()
                            await environment.store.rescheduleNotifications()
                        }
                    }
                }

                // Denied is not a healthy install: without this card the
                // screen looks fine forever while no reminder can ever fire.
                if notificationStatus == .denied, !model.isEmpty {
                    NotificationDeniedCard {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }

                if !model.lowSupply.isEmpty {
                    RefillCard(medications: model.lowSupply)
                }

                if model.isEmpty {
                    EmptyLibraryCard { route = .add }
                } else {
                    doseSections(model)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                ambientSky(model)
                if breath > breathDone, !reduceMotion {
                    AuroraBloom().id(breath)
                }
            }
        }
    }

    /// The day's acts, in the order attention demands: what needs you *now*,
    /// what's coming later, what went wrong, what's already done.
    ///
    /// The unit is the *medication*, not the dose. Each medicine appears
    /// exactly once, in exactly one section — chosen by what deserves
    /// attention most — while the card's timeline of chips tells the whole
    /// day's truth. A missed 13:00 can never again ride inside a green
    /// "Taken" stack: for an app whose whole promise is honesty about
    /// adherence, that is the one lie the interface must never tell.
    @ViewBuilder
    private func doseSections(_ model: TodayModel) -> some View {
        let byTier = Dictionary(grouping: model.day.cards, by: \.tier)
        let due = (byTier[0] ?? []).sorted { $0.sortDate < $1.sortDate }
        let upcoming = (byTier[1] ?? []).sorted { $0.sortDate < $1.sortDate }
        let missed = (byTier[2] ?? []).sorted { $0.sortDate < $1.sortDate }
        let done = (byTier[3] ?? []).sorted { $0.sortDate < $1.sortDate }
        let dayComplete = model.isToday && model.day.isComplete

        if dayComplete {
            DayCompleteCard(day: model.day)
        }

        if !due.isEmpty {
            SectionLabel(title: model.isToday
                         ? String(localized: "Due now")
                         : String(localized: "Due"))
            medicationCards(due, model: model)
        }

        if !upcoming.isEmpty {
            SectionLabel(title: model.isToday
                         ? String(localized: "To take")
                         : String(localized: "Scheduled"))
            medicationCards(upcoming, model: model)
        }

        // The night pivot: once today is settled, tomorrow's plan is the most
        // useful thing on screen — and it outranks the record of what's done.
        if dayComplete, !model.tomorrow.isEmpty {
            SectionLabel(title: String(localized: "Tomorrow"))
            ForEach(DayPlan(doses: model.tomorrow).cards) { card in
                MedicationDayCardView(
                    card: card, isHighlighted: false,
                    now: model.now, window: model.window,
                    onLog: { _, _ in },
                    onOpen: { presentedDose = $0 },
                    onOpenDay: { daySheetTarget = DaySheetTarget(medicationID: card.medication.id, isTomorrow: true) }
                )
            }
        }

        // One record section for everything already settled. Missed cards
        // lead it — what went wrong is seen first — but the truth lives on
        // the cards themselves now: red chips and the tile's warning badge
        // mean a missed dose no longer needs its own section to be honest.
        let logged = missed + done
        if !logged.isEmpty {
            SectionLabel(title: String(localized: "Logged"))
            medicationCards(logged, model: model)
        }

        if model.day.doses.isEmpty {
            NothingScheduledCard()
        }
    }

    private func medicationCards(_ cards: [MedicationDayCard], model: TodayModel) -> some View {
        ForEach(cards) { card in
            MedicationDayCardView(
                card: card,
                isHighlighted: card.medication.id == deepLink?.medicationID,
                now: model.now,
                window: model.window,
                onLog: { log($0, as: $1) },
                onOpen: { presentedDose = $0 },
                onOpenDay: { daySheetTarget = DaySheetTarget(medicationID: card.medication.id, isTomorrow: false) }
            )
            .transition(.opacity)
        }
    }

    private func header(_ model: TodayModel) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isToday
                     ? model.greeting
                     : model.selectedDay.formatted(.dateTime.weekday(.wide)))
                    .font(.largeTitle.weight(.bold))
                    .minimumScaleFactor(0.7)
                Text(model.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer()

            // One slot, two meanings: today's progress ring, or the way home
            // from any other day. The circle never moves — its contents morph,
            // so the eye learns a single landmark instead of two controls.
            ZStack {
                if model.isToday {
                    if !model.day.doses.isEmpty {
                        Button {
                            isShowingDaySummary = true
                            Haptics.select()
                        } label: {
                            DayRing(
                                progress: DayProgress(taken: model.day.takenCount, total: model.day.doses.count),
                                size: 46, lineWidth: 5
                            )
                            .overlay {
                                Text("\(model.day.takenCount)/\(model.day.doses.count)")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                            }
                            .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                        .accessibilityLabel(String(
                            localized: "\(model.day.takenCount) of \(model.day.doses.count) doses taken"
                        ))
                        .accessibilityHint(String(localized: "Opens the day's summary"))
                    }
                } else {
                    Button {
                        withAnimation(.smooth(duration: 0.35)) { model.goToToday() }
                        Haptics.tap()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Theme.accent.gradient, in: .circle)
                            .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 3)
                    }
                    .accessibilityLabel(String(localized: "Return to today"))
                    .accessibilityHint(String(localized: "Jumps back to today's doses"))
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: model.isToday)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    /// A whisper of colour that tracks the hour — Weather's trick, kept quiet.
    /// Suppressed under Reduce Motion, where a slowly cross-fading background
    /// is exactly the kind of ambient movement the setting exists to stop.
    @ViewBuilder
    private func ambientSky(_ model: TodayModel) -> some View {
        // Still by default — the day doesn't need a lava lamp. Motion arrives
        // only as a reply to an accomplishment (see BreathBloom).
        LinearGradient(
            colors: [skyColor(model).opacity(0.26), skyColor(model).opacity(0.08), .clear],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 320)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func skyColor(_ model: TodayModel) -> Color {
        switch Calendar.current.component(.hour, from: model.now) {
        case 5..<9: Color(red: 1.00, green: 0.62, blue: 0.42)
        case 9..<12: Color(red: 0.55, green: 0.78, blue: 1.00)
        case 12..<17: Color(red: 0.45, green: 0.72, blue: 1.00)
        case 17..<20: Color(red: 0.72, green: 0.58, blue: 0.98)
        case 20..<22: Color(red: 0.45, green: 0.42, blue: 0.85)
        default: Color(red: 0.28, green: 0.32, blue: 0.66)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // iOS 26 merges adjacent toolbar items into one standard-sized
        // capsule; a spacer splits them. So: the add action stands alone,
        // calendar and settings fuse into the system's own pill.
        ToolbarItem(placement: .primaryAction) {
            AddMedicationToolbarButton { route = .add }
                // iOS 26 keeps a toolbar glass button dimmed after the sheet
                // it presented is dismissed — a quiet renderer bug. A fresh
                // identity on dismiss forces a clean redraw.
                .id(toolbarReset)
        }
        if #available(iOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            ToolbarGlyphButton(
                systemImage: "calendar",
                label: String(localized: "Open calendar")
            ) { route = .calendar }
        }
        ToolbarItem(placement: .primaryAction) {
            SettingsToolbarButton()
        }
    }

    // MARK: - Actions

    private func log(_ dose: ResolvedDose, as status: DoseStatus, at loggedAt: Date? = nil) {
        withAnimation(.smooth(duration: 0.35)) {
            model?.log(dose, as: status, at: loggedAt)
        }
        // A failed save must not play the success story — no haptic, no
        // bloom. Say what happened instead.
        if let error = environment.store.lastError {
            environment.store.lastError = nil
            storeError = error.errorDescription
            Haptics.error()
            return
        }
        switch status {
        case .taken:
            Haptics.success()
            if !reduceMotion {
                breath += 1
                let thisBreath = breath
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(AuroraBloom.lifespan))
                    if breathDone < thisBreath { breathDone = thisBreath }
                }
            }
            // No toast: the bloom, the haptic and the green checkmark already
            // confirm the log — a banner on top only interrupts.
        case .skipped:
            Haptics.warning()
        case .missed:
            break
        }
        Task {
            await environment.notificationService.cancelReminders(
                medicationID: dose.medication.id, scheduledAt: dose.scheduledAt
            )
        }
    }

    private func undo(_ dose: ResolvedDose) {
        withAnimation(.smooth(duration: 0.35)) { model?.undo(dose) }
        if let error = environment.store.lastError {
            environment.store.lastError = nil
            storeError = error.errorDescription
            Haptics.error()
            return
        }
        Haptics.tap()
    }
}

// MARK: - Supporting cards

private struct NotificationNudge: View {
    let onEnable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "Turn on reminders"), systemImage: "bell.badge.fill")
                .font(.headline)
            Text(String(localized: "A nudge at every dose time, and a gentle follow-up if one goes unlogged."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: onEnable) {
                Text(String(localized: "Turn On Notifications"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .prominentButton()
            .controlSize(.large)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

/// The denied state, distinct from never-asked: the user said no at the
/// system level, so the only route back is iOS Settings — say so, and take
/// them there.
private struct NotificationDeniedCard: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "Reminders are off"), systemImage: "bell.slash.fill")
                .font(.headline)
            Text(String(localized: "Notifications for Daily Dose are disabled in iOS Settings, so no dose reminder can reach you."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: onOpenSettings) {
                Text(String(localized: "Open Settings"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .prominentButton()
            .controlSize(.large)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct RefillCard: View {
    let medications: [MedicationSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(String(localized: "Refill soon"), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Theme.due)
            ForEach(medications) { medication in
                Text(String(localized: "\(medication.name) — \(medication.pillsRemaining ?? 0) left"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

/// The day's story, told on demand.
///
/// Presented by tapping the header's progress ring. The completion hero used
/// to live inline in the scroll view, occupying permanent space for a fact the
/// ring already communicates at a glance — now the ring is the doorway and the
/// detail is one tap away.
private struct DaySummarySheet: View {
    let plan: DayPlan
    let day: Date

    private var taken: Int { plan.doses.filter { $0.state == .logged(.taken) }.count }
    private var skipped: Int { plan.doses.filter { $0.state == .logged(.skipped) }.count }
    /// Logged-missed plus doses whose window closed unlogged — both are
    /// missed; a dose that can still be taken is late, not missed.
    private var missed: Int {
        plan.doses.filter(\.isMissed).count
    }

    private var percent: Int? {
        guard !plan.doses.isEmpty else { return nil }
        return Int((100.0 * Double(taken) / Double(plan.doses.count)).rounded())
    }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var allTaken: Bool { !plan.doses.isEmpty && taken == plan.doses.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer()

                ProgressRing(percent: percent)

                VStack(spacing: 6) {
                    Text(String(localized: "\(taken) of \(plan.doses.count) doses taken"))
                        .font(.title3.weight(.bold))
                        .contentTransition(.numericText())
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 8) {
                    StatusChip(text: String(localized: "\(taken) taken"),
                               color: Theme.taken, systemImage: "checkmark.circle.fill")
                    if skipped > 0 {
                        StatusChip(text: String(localized: "\(skipped) skipped"), color: Theme.skipped)
                    }
                    if missed > 0 {
                        StatusChip(text: String(localized: "\(missed) missed"),
                                   color: Theme.missed, systemImage: "exclamationmark.circle.fill")
                    }
                }

                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
            }
        }
        .presentationDetents([.medium])
    }

    private var message: String {
        if allTaken {
            return isToday
                ? String(localized: "Nothing left today. Well done.")
                : String(localized: "Every dose was taken.")
        }
        let remaining = plan.pending.count
        if isToday, remaining > 0 {
            return String(localized: "\(remaining) still to go — you've got this.")
        }
        return String(localized: "Nothing left for this day.")
    }
}

/// One breath, once per accomplishment — a fluid aurora, not geometry.
///
/// Four deep-saturated light orbs drift on independent slow orbits while a
/// heavy Gaussian blur melts them into a single seamless field — the same
/// recipe as Gemini's thinking state (blurred light has no edges, which is
/// why a MeshGradient's bilinear creases could never get there). The bloom
/// fades in, flows, dissolves, then leaves the view tree entirely, so the
/// resting app renders zero animation frames.
/// The day is settled. Said plainly, in one calm card, so a taken-dose
/// record never gets mistaken for a to-do list.
private struct DayCompleteCard: View {
    let day: DayPlan

    @State private var appeared = false

    private var taken: Int { day.takenCount }
    private var skipped: Int { day.doses.filter { $0.state == .logged(.skipped) }.count }
    private var missed: Int { day.doses.filter(\.isMissed).count }
    private var allTaken: Bool { taken == day.doses.count }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.taken)
                .symbolEffect(.bounce, value: appeared)

            VStack(alignment: .leading, spacing: 2) {
                Text(allTaken
                     ? String(localized: "All taken")
                     : String(localized: "That's everything for today"))
                    .font(.headline)
                Text(allTaken
                     ? String(localized: "Nothing left — see you tomorrow.")
                     : breakdown)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .cardStyle()
        .onAppear { appeared = true }
        .accessibilityElement(children: .combine)
    }

    private var breakdown: String {
        var parts: [String] = []
        if taken > 0 { parts.append(String(localized: "\(taken) taken")) }
        if skipped > 0 { parts.append(String(localized: "\(skipped) skipped")) }
        if missed > 0 { parts.append(String(localized: "\(missed) missed")) }
        return parts.joined(separator: " · ")
    }
}

private struct NothingScheduledCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36))
                .foregroundStyle(Theme.accent)
            Text(String(localized: "Nothing scheduled for this day"))
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyLibraryCard: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "pills.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent)
                .padding(24)
                .background(Theme.accent.opacity(0.12), in: .circle)

            Text(String(localized: "No medications yet"))
                .font(.title3.weight(.semibold))
            Text(String(localized: "Add your first one — reminders, supply tracking and history start right away."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onAdd) {
                Label(String(localized: "Add Medication"), systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .prominentButton()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
        .cardStyle()
    }
}
