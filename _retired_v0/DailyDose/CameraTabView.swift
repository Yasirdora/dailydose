import SwiftUI

/// A scanned label fragment waiting to become a medication.
struct ScannedLabel: Identifiable {
    let id = UUID()
    let name: String
    let strength: String
}

/// The Camera tab — a real tab, not a sheet, so there is no tab-bar/sheet
/// state to fight. The system tab bar hides while this tab is active and the
/// bottom chrome morphs: the browsing tabs' slot becomes a "Manual entry"
/// pill, and the camera bubble's slot becomes a big shutter button.
///
/// Interaction model (grandmother-tested): point at the bottle, tap the
/// shutter — the best recognized label text flows into a prefilled form.
/// Tapping a highlighted fragment directly also still works.
struct CameraTabView: View {
    /// Provided by the tab container: switches back to the browsing tabs.
    /// When present, the system tab bar hides and an X button appears —
    /// without it (legacy fallback layout) the tab bar stays visible.
    var onExit: (() -> Void)? = nil

    @State private var store = RecognizedItemsStore()
    @State private var scanned: ScannedLabel?
    @State private var manual = false
    @State private var toastMessage: String?

    var body: some View {
        ZStack(alignment: .top) {
            if LabelScannerView.isUsable {
                LabelScannerView(store: store, onBackgroundTap: backgroundTapped) { transcript in
                    Haptics.medium()
                    present(transcript)
                }
                .ignoresSafeArea()
            } else {
                ScannerUnavailableView()
            }

            if let onExit {
                HStack {
                    Spacer()
                    Button(action: onExit) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 40, height: 40)
                    }
                    .cardStyle(cornerRadius: 20, interactive: true)
                    .accessibilityLabel("Close camera")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            VStack {
                Spacer()
                bottomBar
            }
        }
        // Hiding the tab bar must be declared on the tab's child view —
        // and only when an exit path exists, so nobody gets stranded.
        .toolbar(onExit != nil ? .hidden : .visible, for: .tabBar)
        .overlay(alignment: .top) {
            if let toastMessage {
                ToastView(message: toastMessage, systemImage: "viewfinder")
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
                    .padding(.top, 56)
            }
        }
        .sheet(item: $scanned) { label in
            AddMedicationView(med: nil,
                              prefillName: label.name,
                              prefillStrength: label.strength,
                              onSaved: onExit)
        }
        .sheet(isPresented: $manual) {
            AddMedicationView(med: nil, onSaved: onExit)
        }
    }

    /// The morphed bottom chrome: manual-entry pill on the browsing-tabs'
    /// side, shutter where the camera bubble sits.
    private var bottomBar: some View {
        HStack(spacing: 18) {
            Button {
                Haptics.select()
                manual = true
            } label: {
                Label("Manual entry", systemImage: "keyboard")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
            }
            .cardStyle(cornerRadius: 30, interactive: true)
            .accessibilityHint("Type the medication details instead")

            ShutterButton { shutter() }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: - Actions

    private func shutter() {
        Haptics.medium()
        guard let candidate = store.bestCandidate() else {
            showEmptyHint()
            return
        }
        present(candidate)
    }

    /// A tap on the viewfinder that hit no highlighted fragment: only nudge
    /// when the scanner genuinely sees nothing worth reading.
    private func backgroundTapped() {
        if store.bestCandidate() == nil { showEmptyHint() }
    }

    private func showEmptyHint() {
        Haptics.light()
        toastMessage = "No label detected — point at the label"
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            toastMessage = nil
        }
    }

    private func present(_ rawText: String) {
        let parsed = LabelScanParser.parse(rawText)
        scanned = ScannedLabel(name: parsed.name, strength: parsed.strength)
    }
}

/// Camera-app shutter language: white ring, white core, a brief press pulse.
struct ShutterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4.5)
                    .frame(width: 68, height: 68)
                Circle()
                    .fill(.white)
                    .frame(width: 56, height: 56)
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .accessibilityLabel("Capture label")
        .accessibilityHint("Reads the medication name and strength from the label")
    }
}
