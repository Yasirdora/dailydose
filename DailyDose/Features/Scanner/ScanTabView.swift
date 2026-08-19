import SwiftUI

/// The scanner, presented as a bottom sheet over whatever the user was doing
/// — the same shape as Wallet's Add Card: a back chevron up top, the camera
/// living inside a rounded card that IS the scan window, one brief line of
/// instruction, then shutter and manual entry at the bottom.
///
/// Capture happens four ways, in descending order of magic:
///
/// 1. **A barcode** — fires the instant one parses. No stability window: a
///    barcode carries its own check digit, so it is either right or it is not
///    read at all, and there is nothing for a second of waiting to confirm.
///    If the code matches a pack the user has scanned before, this becomes a
///    refill rather than a new medication.
/// 2. **Auto-capture** — a readable strength ("500 mg") held steady for a
///    second fires on its own. Pointing is all the teaching anyone needs.
/// 3. **The shutter** — the explicit path, and the affordance that tells a
///    first-time user this screen is for scanning. Tap-to-pick alone failed
///    that test: nobody discovered it, because nothing on screen says "tap".
/// 4. **Tapping a highlighted fragment** — still there, just no longer the
///    only way.
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
                header

                cameraCard
                    .padding(.horizontal, 24)
                    .padding(.top, 30)

                guidance
                    .padding(.top, 20)

                Spacer(minLength: 16)

                bottomControls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            .background(Color(.systemGroupedBackground))
            // A sheet carries no navigation bar; the chevron is the header.
            .toolbar(.hidden, for: .navigationBar)
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
            autoCapture = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let current = recognized.strengthCandidate else { return }
                Haptics.success()
                present(current)
            }
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

    // MARK: - Header

    /// Wallet's chevron: a quiet glass orb, top-left. 32 pt visual — the size
    /// of the system's own navigation orbs — with the hit target invisibly
    /// expanded to 44 so it stays easy to reach.
    private var header: some View {
        HStack {
            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .modifier(GlassCircle())
            .contentShape(Circle().inset(by: -6))
            .accessibilityLabel(String(localized: "Back"))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Camera card

    /// The live preview, clipped to the rounded card. The card's border IS
    /// the scan window — it brightens with the app accent the moment the
    /// label inside is readable: the "locked on" cue, in colour not words.
    private var cameraCard: some View {
        ZStack {
            if isScanning {
                LabelScannerView(
                    store: recognized,
                    onBackgroundTap: {
                        // Only nudge when the scanner genuinely sees nothing —
                        // a tap that hit a fragment is already handled.
                        if !recognized.hasCandidate { showEmptyHint() }
                    },
                    onPick: { transcript in
                        autoCapture?.cancel()
                        Haptics.impact()
                        present(transcript)
                    }
                )
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
                    recognized.strengthCandidate != nil ? Theme.accent : Color.white.opacity(0.55),
                    lineWidth: recognized.strengthCandidate != nil ? 3 : 1.5
                )
                .allowsHitTesting(false)
        )
        .animation(.smooth(duration: 0.25), value: recognized.strengthCandidate != nil)
    }

    /// Title plus one brief instruction. Turns into "Hold steady…" once the
    /// label reads — the countdown the user can feel.
    private var guidance: some View {
        VStack(spacing: 6) {
            Text(String(localized: "Scan Medication Label"))
                .font(.title3.weight(.bold))
            Text(recognized.strengthCandidate != nil
                 ? String(localized: "Hold steady…")
                 : String(localized: "Point at the label or the barcode."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
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
        let result = LabelScanParser.parse(transcript)
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

/// A round glass button — Wallet's chevron orb, the system's own material.
private struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.circle)
        }
    }
}

/// The scanner presented as a sheet from the medication editor.
struct LabelScannerSheet: View {
    /// One capture, both engines. The barcode half is nil on a box that carries
    /// no code we can read, which is normal — a UK pack may carry none at all.
    let onPick: (ScanCapture) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorization = CameraAuthorization()
    @State private var recognized = RecognizedTextStore()

    static var isAvailable: Bool { LabelScannerView.isSupported }

    var body: some View {
        NavigationStack {
            Group {
                if authorization.state == .authorized, LabelScannerView.isSupported {
                    LabelScannerView(store: recognized) { transcript in
                        let result = LabelScanParser.parse(transcript)
                        guard !result.isEmpty else { return }
                        onPick(ScanCapture(label: result, pack: recognized.packCandidate))
                        dismiss()
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    CameraUnavailableView(state: authorization.state) {
                        Task { await authorization.request() }
                    }
                }
            }
            .navigationTitle(String(localized: "Scan Label"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
            }
        }
        .task { authorization.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { authorization.refresh() }
        }
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
