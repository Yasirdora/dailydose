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

/// The text fragments currently in frame.
///
/// `@Observable` so the frame's "readable" glow and the auto-capture timer
/// track what the camera can actually see, updated on every recognized-item
/// callback.
@MainActor
@Observable
final class RecognizedTextStore {
    private(set) var transcripts: [String] = []

    /// Any text at all in frame — decides whether a background tap deserves
    /// the "nothing here" nudge.
    var hasCandidate: Bool { !transcripts.isEmpty }

    /// A fragment containing a strength ("500 mg"): the signal that the label
    /// is genuinely readable, not just noisy. Auto-capture waits for this.
    var strengthCandidate: String? {
        transcripts.first(where: LabelScanParser.containsStrength)
    }

    /// The best thing the shutter could capture right now: a fragment with a
    /// strength if there is one, otherwise the longest piece of text in frame.
    var bestCandidate: String? {
        strengthCandidate ?? transcripts.max { $0.count < $1.count }
    }

    func update(with items: [RecognizedItem]) {
        transcripts = items.compactMap { item in
            guard case .text(let text) = item else { return nil }
            return text.transcript
        }
    }

    /// Called when scanning stops. A camera that isn't running must not hold
    /// stale candidates — otherwise a pending auto-capture could fire while
    /// the viewfinder isn't even on screen.
    func clear() {
        transcripts = []
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
