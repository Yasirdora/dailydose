import SwiftUI
import VisionKit
import AVFoundation

/// Live on-device text scanning over the camera, in the style of Apple Health's
/// "add medication by camera". Nothing ever leaves the frame buffer.
struct LabelScannerView: UIViewControllerRepresentable {
    let store: RecognizedTextStore
    var onBackgroundTap: () -> Void = {}
    let onPick: (String) -> Void

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> ScannerContainerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            // The system's "Find nearby text." guidance is noise inside our
            // small camera card — the sheet carries its own instruction.
            isGuidanceEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        let container = ScannerContainerViewController(scanner: scanner, store: store)
        container.onBackgroundTap = onBackgroundTap
        return container
    }

    func updateUIViewController(_ controller: ScannerContainerViewController, context: Context) {
        controller.onBackgroundTap = onBackgroundTap
    }

    static func dismantleUIViewController(_ controller: ScannerContainerViewController, coordinator: Coordinator) {
        controller.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store, onPick: onPick) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let store: RecognizedTextStore
        private let onPick: (String) -> Void

        init(store: RecognizedTextStore, onPick: @escaping (String) -> Void) {
            self.store = store
            self.onPick = onPick
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            store.update(with: allItems)
        }

        func dataScanner(_ scanner: DataScannerViewController, didUpdate updated: [RecognizedItem], allItems: [RecognizedItem]) {
            store.update(with: allItems)
        }

        func dataScanner(_ scanner: DataScannerViewController, didRemove removed: [RecognizedItem], allItems: [RecognizedItem]) {
            store.update(with: allItems)
        }

        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            guard case .text(let text) = item else { return }
            Haptics.impact()
            onPick(text.transcript)
        }
    }
}

/// One piece of text the camera can see, and how large it is printed.
///
/// A plain value so the ranking rules below can be tested without a camera, a
/// simulator, or a `RecognizedItem` — which cannot be constructed outside
/// VisionKit at all.
struct ScannedFragment: Equatable, Sendable {
    let text: String
    /// Printed height, in the camera card's own points.
    ///
    /// The medication's name is almost always the largest text on a carton,
    /// and legal small print is the smallest — so height separates them where
    /// string length does not. Length was the old rule, and it preferred
    /// whichever line had the most characters: the manufacturer's address, the
    /// storage instructions, the leaflet reference.
    let height: CGFloat
    /// Where the fragment sits, so fragments can be put back into reading
    /// order and grouped into printed lines. See ``lines(from:)``.
    let verticalCenter: CGFloat
    let left: CGFloat

    init(text: String, height: CGFloat, verticalCenter: CGFloat = 0, left: CGFloat = 0) {
        self.text = text
        self.height = height
        self.verticalCenter = verticalCenter
        self.left = left
    }

    /// The fragments rebuilt into printed lines, in reading order.
    ///
    /// The scanner does not hand text over one line at a time. It groups by
    /// proximity, so a label's left-hand column can arrive as a single item
    /// spanning three printed lines, and a line with a wide gap in it —
    /// `Qty:90    Physician: Test Doctor` — can arrive as two. Neither the
    /// order nor the grouping is anything to build on.
    ///
    /// This puts them back: fragments whose vertical centres sit within a
    /// tolerance of each other are one line, ordered left to right, and the
    /// lines themselves run top to bottom. It matters because a quantity is
    /// only read where the number and its noun share a line — the rule that
    /// keeps "Ibuprofen AL 400" over "Filmtabletten" from reading as a pack of
    /// four hundred — and because §1's privacy rules are positional.
    ///
    /// A fragment that already contains newlines keeps them: whatever the
    /// scanner grouped, it still said where the breaks were.
    static func lines(from fragments: [ScannedFragment]) -> [String] {
        let ordered = fragments.sorted { $0.verticalCenter < $1.verticalCenter }
        var rows: [[ScannedFragment]] = []

        for fragment in ordered {
            // Same line when the centres are closer than half the shorter
            // fragment's height. Proportional rather than absolute, because
            // the camera card's scale changes with how close the box is held.
            if let last = rows.last?.last,
               abs(last.verticalCenter - fragment.verticalCenter) < min(last.height, fragment.height) / 2 {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }

        return rows.flatMap { row -> [String] in
            let joined = row.sorted { $0.left < $1.left }.map(\.text).joined(separator: " ")
            // Split on any newline the scanner itself reported: a break it
            // stated is better evidence than a break we inferred.
            return joined.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    /// The fragment most likely to be the medication's name.
    ///
    /// Tallest wins, but only among fragments that could be a name at all —
    /// "GEBRAUCHSINFORMATION" is set in display type on the leaflet flap and
    /// would otherwise win on size every time.
    ///
    /// Deliberately not used on a dispensing label, where the largest text is
    /// very often the *patient's* name — see ``DispensingLabel``.
    static func nameCandidate(among fragments: [ScannedFragment]) -> String? {
        fragments
            .filter { LabelScanParser.couldBeName($0.text) }
            .max { $0.height < $1.height }?
            .text
    }
}

/// The text fragments currently in frame.
///
/// `@Observable` so the frame's "readable" glow and the auto-capture timer
/// track what the camera can actually see, updated on every recognized-item
/// callback.
///
/// There is one recognised data type now, and one capture rule. The scanner
/// briefly also read barcodes; that path is gone, because the pack prints the
/// barcode's own contents in type the camera already reads, and running both
/// engines let a DataMatrix's printed transcription arrive as a medication
/// *name*. `HRIParser` reads that text properly — see `packCandidate`.
@MainActor
@Observable
final class RecognizedTextStore {
    private(set) var fragments: [ScannedFragment] = []

    /// The label as printed lines, in reading order, with everything the
    /// privacy rules forbid already gone.
    ///
    /// Computed once per callback rather than derived on demand: every consumer
    /// below needs it, and a live camera re-evaluates them thirty times a
    /// second.
    private(set) var lines: [String] = []

    /// Whether this is a pharmacy dispensing label rather than a product
    /// carton. Changes where the name may come from — see ``bestCandidate``.
    private(set) var isDispensingLabel = false

    /// Any text at all in frame — decides whether a background tap deserves
    /// the "nothing here" nudge.
    var hasCandidate: Bool { !fragments.isEmpty }

    /// Fragments that are prose rather than a barcode transcription.
    ///
    /// Everything the *name* and *strength* are read from comes through here,
    /// so a printed `(01)…(17)…` line can never reach either field however it
    /// is captured.
    private var prose: [ScannedFragment] {
        fragments.filter { !HRIParser.isTranscription($0.text) }
    }

    /// A line containing a strength ("500 mg"): the signal that the label is
    /// genuinely readable, not just noisy. Auto-capture waits for this.
    var strengthCandidate: String? {
        lines.first(where: LabelScanParser.containsStrength)
    }

    /// The best thing the shutter could capture right now.
    ///
    /// On a carton: a line with a strength if there is one, otherwise the
    /// largest printed text that could be a name — the medicine is the biggest
    /// thing on a box.
    ///
    /// On a dispensing label: the drug line, and only the drug line. Height
    /// ranking is actively wrong here, because the largest text on a label is
    /// very often the patient's name. Nothing else is offered — refusing a name
    /// is the correct outcome, and an empty field the user fills is already how
    /// this screen behaves when a box says nothing certain.
    var bestCandidate: String? {
        if isDispensingLabel { return DispensingLabel.drugLine(in: lines) }
        return strengthCandidate ?? ScannedFragment.nameCandidate(among: nameable)
    }

    /// What a tap on a fragment is allowed to capture, or nil to ignore it.
    ///
    /// Tapping bypasses ranking completely — it names its own winner — so every
    /// rule ranking enforces has to be enforced here too. Otherwise a tap on
    /// the patient's name puts it straight into the field that all of this was
    /// built to keep it out of.
    ///
    /// On a dispensing label the pick must state a strength. That is the drug
    /// line's defining property and one a person's name never has, and it holds
    /// whether or not the tapped fragment matches a rebuilt line exactly.
    func pickable(_ transcript: String) -> String? {
        Self.pickable(transcript, isDispensingLabel: isDispensingLabel)
    }

    /// The rule itself, as a value — so it can be tested without a camera.
    nonisolated static func pickable(_ transcript: String, isDispensingLabel: Bool) -> String? {
        guard !DispensingLabel.isPrivate(transcript) else { return nil }
        guard isDispensingLabel else { return transcript }
        return LabelScanParser.containsStrength(transcript) ? transcript : nil
    }

    /// Fragments allowed to compete for the name field.
    ///
    /// The privacy filter runs here, on the *candidates*, not on the winner:
    /// a prescriber's or a pharmacist's name must never enter the list at all.
    private var nameable: [ScannedFragment] {
        prose.filter { !DispensingLabel.isPrivate($0.text) }
    }

    /// Everything else the carton says.
    ///
    /// A box does not print its facts on one line. The name and strength are on
    /// the front panel; "Filmtabletten" and "30 Stück" are set somewhere else,
    /// and the shutter captures one fragment. Passing this alongside that
    /// fragment is what lets the form and the pack size be read at all — it is
    /// why a scan used to fill in the name and the strength and leave Form on
    /// "Choose".
    ///
    /// Deliberately not used for the name or the strength: those are claims
    /// about one piece of text, and reading them from anywhere in frame is how
    /// a scan picks up the pharmacy's address.
    /// Joined with a line break: a pack quantity is only read where the number
    /// and its noun share a printed line.
    var packagingText: String {
        lines.joined(separator: "\n")
    }

    /// The pack described by a printed barcode transcription in frame, if one
    /// is there and reads cleanly.
    ///
    /// Not a capture trigger — capture waits on the same steady strength it
    /// always did. This is the identity and the dates, attached to whatever
    /// the shutter catches, from a *different* fragment than the name.
    var packCandidate: ScannedPack? {
        fragments.lazy.compactMap { HRIParser.parse($0.text) }.first
    }

    func update(with items: [RecognizedItem]) {
        fragments = items.compactMap { item in
            guard case .text(let text) = item else { return nil }
            return ScannedFragment(
                text: text.transcript,
                height: Self.height(of: item.bounds),
                verticalCenter: Self.verticalCenter(of: item.bounds),
                left: min(item.bounds.topLeft.x, item.bounds.bottomLeft.x)
            )
        }
        // Rebuilt into printed lines and redacted here, once, before anything
        // downstream can rank or parse them.
        lines = DispensingLabel.redacted(ScannedFragment.lines(from: prose))
        isDispensingLabel = DispensingLabel.isDispensingLabel(lines)
        #if DEBUG
        ScanTranscriptProbe.record(fragments)
        #endif
    }

    /// The quadrilateral VisionKit reports is not necessarily upright — a
    /// carton held at an angle produces a sheared box — so the height is the
    /// length of its side edges rather than a difference of `y` values, which
    /// would shrink towards zero as the text rotated.
    private nonisolated static func verticalCenter(of bounds: RecognizedItem.Bounds) -> CGFloat {
        (bounds.topLeft.y + bounds.topRight.y + bounds.bottomLeft.y + bounds.bottomRight.y) / 4
    }

    private nonisolated static func height(of bounds: RecognizedItem.Bounds) -> CGFloat {
        let left = hypot(
            bounds.topLeft.x - bounds.bottomLeft.x,
            bounds.topLeft.y - bounds.bottomLeft.y
        )
        let right = hypot(
            bounds.topRight.x - bounds.bottomRight.x,
            bounds.topRight.y - bounds.bottomRight.y
        )
        return (left + right) / 2
    }

    /// Called when scanning stops. A camera that isn't running must not hold
    /// stale candidates — otherwise a pending auto-capture could fire while
    /// the viewfinder isn't even on screen.
    func clear() {
        fragments = []
        lines = []
        isDispensingLabel = false
    }
}

/// Hosts `DataScannerViewController` as a child.
///
/// Scanning must start only once the view is genuinely on screen — calling
/// `startScanning()` at creation time fails silently, leaving a live preview
/// that never recognises anything.
final class ScannerContainerViewController: UIViewController {
    let scanner: DataScannerViewController
    private let store: RecognizedTextStore
    var onBackgroundTap: (() -> Void)?

    private var isScanning = false

    init(scanner: DataScannerViewController, store: RecognizedTextStore) {
        self.scanner = scanner
        self.store = store
        super.init(nibName: nil, bundle: nil)

        addChild(scanner)
        scanner.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanner.view)
        NSLayoutConstraint.activate([
            scanner.view.topAnchor.constraint(equalTo: view.topAnchor),
            scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        scanner.didMove(toParent: self)

        // `cancelsTouchesInView = false` so the scanner's own tap-to-pick keeps
        // working alongside this.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func handleTap() { onBackgroundTap?() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Recognize only what the camera card shows. The default (.zero)
        // scans the entire sensor frame, so text well outside the visible
        // window was being picked up — and auto-captured. The small inset
        // keeps half-cut text at the very edge from counting as "read".
        let roi = view.bounds.insetBy(dx: 10, dy: 10)
        if scanner.regionOfInterest != roi {
            scanner.regionOfInterest = roi
        }
    }

    /// Permission is resolved by `CameraAuthorization` before this view is ever
    /// shown, so by the time we get here starting is expected to succeed.
    func start() {
        guard !isScanning, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        do {
            try scanner.startScanning()
            isScanning = true
        } catch {
            isScanning = false
        }
    }

    func stop() {
        guard isScanning else { return }
        scanner.stopScanning()
        isScanning = false
        // A stopped camera sees nothing; stale candidates would let a pending
        // auto-capture fire into a viewfinder that isn't on screen.
        store.clear()
    }
}
