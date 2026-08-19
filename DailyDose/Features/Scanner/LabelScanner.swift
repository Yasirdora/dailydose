import SwiftUI
import VisionKit
import Vision
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

    /// What a medicine pack is printed in, anywhere in the world.
    ///
    /// `.dataMatrix` is the one that matters: it is what EU prescription packs
    /// carry under the Falsified Medicines Directive and what US packs carry
    /// under DSCSA, and it is the only one that holds an expiry date. The
    /// linear symbologies are here because an over-the-counter box, or a UK
    /// pack since the FMD stopped applying, may carry nothing else — and a
    /// GTIN with no expiry still makes a refill scan work.
    static let symbologies: [VNBarcodeSymbology] = [
        .dataMatrix,
        .ean13, .ean8, .upce,
        .code39, .code128,
        .gs1DataBar, .gs1DataBarExpanded, .gs1DataBarLimited,
    ]

    func makeUIViewController(context: Context) -> ScannerContainerViewController {
        let scanner = DataScannerViewController(
            // Text *and* barcodes, in one session: `recognizedDataTypes` is a
            // set, and the two run together rather than in competition. The
            // camera gives us the medicine's name; the barcode gives us its
            // identity and its expiry date, which no amount of OCR can.
            recognizedDataTypes: [.text(), .barcode(symbologies: Self.symbologies)],
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
        #if DEBUG
        ScanProbe.logLaunch(requested: Self.symbologies)
        #endif
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

/// What the camera can currently see: text fragments, and the pack a barcode
/// in frame decoded to.
///
/// `@Observable` so the frame's "readable" glow and the auto-capture trigger
/// track what the camera can actually see, updated on every recognized-item
/// callback.
///
/// This is the boundary between VisionKit and the pure domain layer: raw bytes
/// come in here and a `ScannedPack` goes out. Nothing above it touches Vision,
/// and nothing below it knows a camera exists.
@MainActor
@Observable
final class RecognizedTextStore {
    private(set) var transcripts: [String] = []

    /// The pack a barcode in frame decoded to, if one did.
    ///
    /// A barcode carries its own check digit, so this is either right or nil —
    /// there is no "probably". That is what lets it fire capture immediately
    /// where OCR has to be held steady for a second first.
    private(set) var pack: ScannedPack?

    /// Any text at all in frame — decides whether a background tap deserves
    /// the "nothing here" nudge.
    var hasCandidate: Bool { !transcripts.isEmpty || pack != nil }

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
        #if DEBUG
        ScanProbe.record(items: items, interpret: Self.interpret)
        #endif

        var transcripts: [String] = []
        var pack: ScannedPack?

        for item in items {
            switch item {
            case .text(let text):
                transcripts.append(text.transcript)
            case .barcode(let barcode):
                // First readable code wins. Two medicine barcodes in one frame
                // means the camera is looking at two boxes, and picking one is
                // exactly as wrong as picking the other — but the user is
                // holding *something* up, and the guard is the confirmation
                // screen they land on either way.
                if pack == nil, let scanned = Self.interpret(barcode) { pack = scanned }
            @unknown default:
                continue
            }
        }

        self.transcripts = transcripts
        self.pack = pack
    }

    /// Called when scanning stops. A camera that isn't running must not hold
    /// stale candidates — otherwise a pending auto-capture could fire while
    /// the viewfinder isn't even on screen.
    func clear() {
        transcripts = []
        pack = nil
    }

    // MARK: - VisionKit bridging

    /// The bytes to hand the parser.
    ///
    /// `payloadData` before `payloadStringValue`, always. The string form is
    /// decoded text, and the `GS` (0x1D) bytes that separate a GS1 element
    /// string's variable-length fields do not reliably survive that trip —
    /// losing one silently merges a batch number with whatever followed it.
    ///
    /// Not private, so `ScanProbe` can log the exact bytes production parses
    /// rather than its own second guess at them.
    static func payloadBytes(of barcode: RecognizedItem.Barcode) -> [UInt8]? {
        let observation = barcode.observation
        if let data = observation.payloadData, !data.isEmpty {
            return Array(data)
        }
        if let text = observation.payloadStringValue, !text.isEmpty {
            return Array(text.utf8)
        }
        return nil
    }

    private static func interpret(_ barcode: RecognizedItem.Barcode) -> ScannedPack? {
        guard let bytes = payloadBytes(of: barcode) else { return nil }
        return BarcodeInterpreter.interpret(
            BarcodePayload(bytes: bytes, symbology: .init(barcode.observation.symbology))
        )
    }
}

extension BarcodePayload.Symbology {
    /// Maps Vision's symbology onto the domain layer's, so nothing above
    /// `RecognizedTextStore` has to import Vision to know what it scanned.
    init(_ symbology: VNBarcodeSymbology) {
        switch symbology {
        case .dataMatrix: self = .dataMatrix
        case .ean13: self = .ean13
        case .ean8: self = .ean8
        case .upce: self = .upce
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum: self = .code39
        case .code128: self = .code128
        case .gs1DataBar: self = .gs1DataBar
        case .gs1DataBarExpanded: self = .gs1DataBarExpanded
        case .gs1DataBarLimited: self = .gs1DataBarLimited
        default: self = .other
        }
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
            #if DEBUG
            ScanProbe.logGeometry(
                viewBounds: view.bounds, regionOfInterest: roi,
                scale: view.window?.screen.scale ?? UIScreen.main.scale
            )
            #endif
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
            #if DEBUG
            ScanProbe.logScanningFailure(error)
            #endif
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
