import SwiftUI

/// The scanner, presented as a bottom sheet over whatever the user was doing
/// — the same shape as Wallet's Add Card: a back chevron up top, the camera
/// living inside a rounded card that IS the scan window, one brief line of
/// instruction, then shutter and manual entry at the bottom.
///
/// Capture happens four ways, in descending order of magic:
///
/// 1. **Auto-capture** — a readable strength ("500 mg") held steady for a
///    second fires on its own. Pointing is all the teaching anyone needs.
/// 2. **The shutter** — the explicit path, and the affordance that tells a
///    first-time user this screen is for scanning. Tap-to-pick alone failed
///    that test: nobody discovered it, because nothing on screen says "tap".
/// 3. **Tapping a highlighted fragment** — still there, just no longer the
///    only way.
///
/// A pack rides along with whichever of those fires: there is no separate
/// barcode trigger, because the live AVFoundation path was removed — the box
/// prints the code's own contents in type the OCR already reads, and
/// `HRIParser` takes it from there. If that identifies a pack the user has
/// scanned before, this becomes a refill rather than a new medication.
///
/// Only what the card shows can be scanned — the region of interest is the
/// card itself, so text outside the window cannot trigger a capture.
///
/// The sheet disables drag-to-dismiss on purpose: dragging a live camera over
/// the tab UI is what glitched before. The chevron is the one honest exit.
struct ScanTabView: View {
    var onFinish: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.doseStore) private var store
    @State private var authorization = CameraAuthorization()
    @State private var recognized = RecognizedTextStore()
    @State private var scanned: ScanCapture?
    /// A medication this barcode already belongs to. Set instead of `scanned`,
    /// because the right offer for a box the user has bought before is "top up
    /// your supply", not "add a second Metformin".
    @State private var matched: Medication?
    @State private var isEnteringManually = false
    @State private var autoCapture: Task<Void, Never>?
    @State private var toast: Toast?

    private var isScanning: Bool {
        authorization.state == .authorized && LabelScannerView.isSupported
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                cameraCard
                    .padding(.horizontal, 24)
                    .padding(.top, 24)

                guidance
                    .padding(.top, 20)

                Spacer(minLength: 16)

                bottomControls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            .background(Color(.systemGroupedBackground))
            // The system's own cancellation orb, in the toolbar where it
            // belongs. This was a hand-drawn chevron for a while, wrong twice
            // over: a chevron means "back up a navigation stack" and there is
            // no stack here, and every hand-built orb fights the toolbar's
            // automatic glass treatment — see `SheetCloseButton`.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
            }
            .toast($toast)
        }
        // Prime, don't pounce: the permission explanation must be read
        // *before* the system alert, not behind it. A cold prompt is the
        // single biggest cause of permanent camera denial, and denial here
        // is one-way. The "Allow Camera" button in CameraUnavailableView
        // makes the request.
        .task { authorization.refresh() }
        // The sheet disables drag-to-dismiss, so a user who fixes permission
        // in Settings needs the state re-read when they come back.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { authorization.refresh() }
        }
        .onChange(of: recognized.strengthCandidate) { _, candidate in
            // Any change — appearing, disappearing, re-reading — restarts the
            // stability window. OCR flickers frame to frame; a capture taken
            // from a flicker fills the form with garbage.
            autoCapture?.cancel()
            guard candidate != nil, !isPresenting else { return }
            autoCapture = steadyStrengthTask(store: recognized) { present($0) }
        }
        .onDisappear { autoCapture?.cancel() }
        .sheet(item: $scanned) { capture in
            MedicationEditor(
                medication: nil, prefill: capture.label, pack: capture.pack, onSaved: onFinish
            )
        }
        .sheet(item: $matched) { medication in
            RefillSheet(medicationName: medication.displayName) { amount in
                store?.addSupply(amount, to: medication)
                Haptics.success()
                onFinish?()
            }
        }
        .sheet(isPresented: $isEnteringManually) {
            MedicationEditor(medication: nil, onSaved: onFinish)
        }
    }

    /// Whether something is already on screen in front of the camera. Every
    /// capture path checks it, so two triggers firing in the same frame — a
    /// barcode and a steady strength — cannot stack two sheets.
    private var isPresenting: Bool {
        scanned != nil || matched != nil || isEnteringManually
    }

    // MARK: - Camera card

    /// The live preview, clipped to the rounded card. The card's border IS
    /// the scan window — it brightens with the app accent the moment the
    /// label inside is readable: the "locked on" cue, in colour not words.
    private var cameraCard: some View {
        ScannerCameraCard(
            store: recognized,
            authorization: authorization,
            onBackgroundTap: {
                // Only nudge when the scanner genuinely sees nothing —
                // a tap that hit a fragment is already handled.
                if !recognized.hasCandidate { showEmptyHint() }
            },
            onPick: { transcript in
                // A tap names its own winner, so it goes through the
                // same rules ranking does — see `pickable`.
                guard let picked = recognized.pickable(transcript) else {
                    Haptics.warning()
                    return
                }
                autoCapture?.cancel()
                Haptics.impact()
                present(picked)
            }
        )
    }

    /// Title plus one brief instruction. Turns into "Hold steady…" once the
    /// label reads — the countdown the user can feel.
    private var guidance: some View {
        ScannerGuidance(isLockedOn: recognized.strengthCandidate != nil)
    }

    // MARK: - Bottom controls

    /// Shutter above, manual entry below — the arrangement from Wallet's Add
    /// Card, plus the shutter it never needed but a first-time user does.
    private var bottomControls: some View {
        VStack(spacing: 22) {
            if isScanning {
                ShutterButton(isEnabled: recognized.hasCandidate) { capture() }
            }
            manualButton
        }
    }

    /// The one escape that always works, camera or no camera.
    private var manualButton: some View {
        Button {
            Haptics.select()
            autoCapture?.cancel()
            isEnteringManually = true
        } label: {
            Text(String(localized: "Enter Manually"))
                .font(.headline)
                // 50 pt — the height of Apple's own full-width action buttons
                // (Wallet, Health), not a custom taller one.
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .prominentButton()
        .accessibilityHint(String(localized: "Enter the medication details by hand"))
    }

    // MARK: - Capture

    private func capture() {
        autoCapture?.cancel()
        // Either half is enough. A small pack may print nothing the OCR can
        // use as a name except its own transcription — and that still carries
        // the identity and the expiry, which is most of what a refill needs.
        guard recognized.bestCandidate != nil || recognized.packCandidate != nil else {
            showEmptyHint()
            return
        }
        Haptics.impact()
        present(recognized.bestCandidate ?? "")
    }

    /// One capture: what the label says, plus the pack's own printed
    /// transcription when the box carries one.
    ///
    /// A box the user has scanned before does not become a second medication —
    /// it becomes more of the one they already have. That is the payoff of
    /// storing the key: name it once, and every refill after that is a
    /// two-second scan with no typing and no database anywhere on earth.
    private func present(_ transcript: String) {
        // Everything else in frame comes with it: the form and the pack size
        // are almost never printed on the same line as the name.
        let result = LabelScanParser.parse(transcript, context: recognized.packagingText)
        let pack = recognized.packCandidate
        // A readable name is not required when the pack identified itself: the
        // user names it once, and the identity is what makes the next scan of
        // the same box instant.
        guard !result.isEmpty || pack != nil else {
            showEmptyHint()
            return
        }
        if let pack, let existing = store?.medication(productKey: pack.key) {
            matched = existing
            return
        }
        scanned = ScanCapture(label: result, pack: pack)
    }

    private func showEmptyHint() {
        Haptics.warning()
        toast = Toast(
            message: String(localized: "No label detected — point at the name on the box"),
            systemImage: "viewfinder"
        )
    }
}

// MARK: - Shared scanner surface

/// The live preview, clipped to the rounded card. The card's border IS the
/// scan window — it brightens with the app accent the moment the label inside
/// is readable: the "locked on" cue, in colour not words.
///
/// Both scanners in this file draw it. Two implementations is how they drifted
/// apart in the first place — the editor's sheet spent a release as a
/// full-bleed camera with no window, no cue and no shutter — so the region of
/// interest, the border and the unavailable state now have one home.
private struct ScannerCameraCard: View {
    let store: RecognizedTextStore
    let authorization: CameraAuthorization
    let onBackgroundTap: () -> Void
    let onPick: (String) -> Void

    private var isLockedOn: Bool { store.strengthCandidate != nil }

    var body: some View {
        ZStack {
            if authorization.state == .authorized, LabelScannerView.isSupported {
                LabelScannerView(store: store, onBackgroundTap: onBackgroundTap, onPick: onPick)
            } else {
                CameraUnavailableView(state: authorization.state) {
                    Task { await authorization.request() }
                }
            }
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
        .background(Color.black, in: .rect(cornerRadius: 28, style: .continuous))
        .clipShape(.rect(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(
                    isLockedOn ? Theme.accent : Color.white.opacity(0.55),
                    lineWidth: isLockedOn ? 3 : 1.5
                )
                .allowsHitTesting(false)
        )
        .animation(.smooth(duration: 0.25), value: isLockedOn)
    }
}

/// Title plus one brief instruction. Turns into "Hold steady…" once the label
/// reads — the countdown the user can feel.
private struct ScannerGuidance: View {
    let isLockedOn: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text(String(localized: "Scan Medication Label"))
                .font(.title3.weight(.bold))
            Text(isLockedOn
                 ? String(localized: "Hold steady…")
                 : String(localized: "Point at the label or the barcode."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
    }
}

/// The one-second stability window before a steady strength reading fires.
///
/// OCR flickers frame to frame, and a capture taken from a flicker fills the
/// form with garbage. The caller keeps the handle so it can cancel — every
/// path that puts something in front of the camera has to.
private func steadyStrengthTask(
    store: RecognizedTextStore,
    action: @escaping @MainActor (String) -> Void
) -> Task<Void, Never> {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let current = store.strengthCandidate else { return }
        Haptics.success()
        action(current)
    }
}

/// Camera-app shutter language, with an honest disabled state: dimmed and
/// unavailable until the scanner actually has something to capture.
private struct ShutterButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4.5)
                    .frame(width: 64, height: 64)
                Circle()
                    .fill(.white)
                    .frame(width: 52, height: 52)
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.smooth(duration: 0.2), value: isEnabled)
        }
        .disabled(!isEnabled)
        .accessibilityLabel(String(localized: "Capture label"))
        .accessibilityHint(
            isEnabled
                ? String(localized: "Reads the medication name and strength")
                : String(localized: "Point the camera at a label first")
        )
    }
}

/// The scanner presented as a sheet from the medication editor.
///
/// The same surface as `ScanTabView` — same camera card, same lock-on border,
/// same guidance, same shutter — because it is the same job: point at a box,
/// get its name and strength. What differs is where the capture goes. The tab
/// scanner may decide a pack is a refill of something you already take; here
/// you are already mid-form, so the capture fills that form in and leaves.
///
/// For the same reason there is no "Enter Manually" button: the manual form is
/// the thing behind this sheet. Close returns to it, and when the camera
/// cannot be used at all, that route is offered outright.
struct LabelScannerSheet: View {
    /// One capture, both engines. The barcode half is nil on a box that carries
    /// no code we can read, which is normal — a UK pack may carry none at all.
    let onPick: (ScanCapture) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorization = CameraAuthorization()
    @State private var recognized = RecognizedTextStore()
    @State private var autoCapture: Task<Void, Never>?
    @State private var toast: Toast?
    /// Delivery is one-way and one-shot. The shutter, a tap and the stability
    /// window can all land in the same frame; without this the editor would be
    /// handed two captures and the sheet dismissed twice.
    @State private var hasDelivered = false

    static var isAvailable: Bool { LabelScannerView.isSupported }

    private var isScanning: Bool {
        authorization.state == .authorized && LabelScannerView.isSupported
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScannerCameraCard(
                    store: recognized,
                    authorization: authorization,
                    onBackgroundTap: {
                        // Only nudge when the scanner genuinely sees nothing —
                        // a tap that hit a fragment is already handled.
                        if !recognized.hasCandidate { showEmptyHint() }
                    },
                    onPick: { transcript in
                        // A tap names its own winner, so it goes through the
                        // same rules ranking does — see `pickable`.
                        guard let picked = recognized.pickable(transcript) else {
                            Haptics.warning()
                            return
                        }
                        autoCapture?.cancel()
                        Haptics.impact()
                        deliver(picked)
                    }
                )
                .padding(.horizontal, 24)
                .padding(.top, 24)

                ScannerGuidance(isLockedOn: recognized.strengthCandidate != nil)
                    .padding(.top, 20)

                Spacer(minLength: 16)

                bottomControls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            .background(Color(.systemGroupedBackground))
            // The same system cancellation orb every other sheet in the app
            // uses. This is a modal root, not a step in a navigation stack.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
            }
            .toast($toast)
        }
        // Prime, don't pounce: the permission explanation must be read *before*
        // the system alert. The "Allow Camera" button inside the card makes the
        // request.
        .task { authorization.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { authorization.refresh() }
        }
        .onChange(of: recognized.strengthCandidate) { _, candidate in
            // Any change — appearing, disappearing, re-reading — restarts the
            // stability window.
            autoCapture?.cancel()
            guard candidate != nil, !hasDelivered else { return }
            autoCapture = steadyStrengthTask(store: recognized) { deliver($0) }
        }
        .onDisappear { autoCapture?.cancel() }
    }

    // MARK: - Bottom controls

    /// The shutter while there is a camera to fire; otherwise the way back to
    /// the form, which is the only thing left that can help.
    @ViewBuilder
    private var bottomControls: some View {
        if isScanning {
            ShutterButton(isEnabled: recognized.hasCandidate) { capture() }
        } else {
            Button {
                Haptics.select()
                dismiss()
            } label: {
                Text(String(localized: "Type It Instead"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .prominentButton()
            .accessibilityHint(String(localized: "Returns to the medication details"))
        }
    }

    // MARK: - Capture

    private func capture() {
        autoCapture?.cancel()
        // Either half is enough. A small pack may print nothing the OCR can use
        // as a name except its own transcription — and that still carries the
        // identity, which is most of what the editor needs.
        guard recognized.bestCandidate != nil || recognized.packCandidate != nil else {
            showEmptyHint()
            return
        }
        Haptics.impact()
        deliver(recognized.bestCandidate ?? "")
    }

    /// Hands one capture to the editor and gets out of the way.
    private func deliver(_ transcript: String) {
        guard !hasDelivered else { return }
        // Everything else in frame comes with it: the form and the pack size
        // are almost never printed on the same line as the name.
        let result = LabelScanParser.parse(transcript, context: recognized.packagingText)
        let pack = recognized.packCandidate
        // A readable name is not required when the pack identified itself —
        // the same rule the tab scanner applies.
        guard !result.isEmpty || pack != nil else {
            showEmptyHint()
            return
        }
        hasDelivered = true
        autoCapture?.cancel()
        onPick(ScanCapture(label: result, pack: pack))
        dismiss()
    }

    private func showEmptyHint() {
        Haptics.warning()
        toast = Toast(
            message: String(localized: "No label detected — point at the name on the box"),
            systemImage: "viewfinder"
        )
    }
}

/// One capture, from both engines at once.
///
/// The two halves answer different questions and neither replaces the other:
/// the barcode is certain about *which product* and *when it expires*, the
/// label is the only thing that knows what the medicine is called. Either half
/// may be empty — a UK box with no DataMatrix, a code with no readable text
/// beside it — and the editor fills in what it was given.
struct ScanCapture: Identifiable, Equatable {
    var label: LabelScanParser.Result
    var pack: ScannedPack?

    /// Identity for `.sheet(item:)`. The barcode wins when there is one: it is
    /// stable frame to frame where OCR text is not.
    var id: String {
        pack?.key.rawValue ?? "\(label.name)|\(label.strength)"
    }
}
