import SwiftUI
import VisionKit
import AVFoundation

/// Live-updated set of the text fragments the scanner currently sees.
/// Shared with the shutter button, so one tap can grab the best candidate
/// without the user having to aim at a highlighted fragment.
final class RecognizedItemsStore {
    private(set) var transcripts: [String] = []

    func update(with items: [RecognizedItem]) {
        transcripts = items.compactMap { item in
            if case .text(let text) = item { return text.transcript }
            return nil
        }
    }

    /// The best medication-name candidate on screen right now:
    /// prefer a fragment containing a strength ("500 mg"), else the longest text.
    func bestCandidate() -> String? {
        transcripts.first { LabelScanParser.containsStrength($0) }
            ?? transcripts.max { $0.count < $1.count }
    }
}

/// Live camera text scanner in the style of Apple Health's "add medication by camera".
/// Highlights recognized text on the bottle/box; tapping a fragment flows it into the
/// form, and the store mirrors whatever is highlighted for the shutter button.
/// Everything is on-device (VisionKit) — no image ever leaves the frame buffer.
struct LabelScannerView: UIViewControllerRepresentable {
    let store: RecognizedItemsStore
    var onBackgroundTap: () -> Void = {}
    let onPick: (String) -> Void

    static var isUsable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> ScannerContainerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        let container = ScannerContainerViewController(scanner: scanner)
        container.onTap = onBackgroundTap
        return container
    }

    func updateUIViewController(_ uiViewController: ScannerContainerViewController, context: Context) {
        uiViewController.onTap = onBackgroundTap
    }

    static func dismantleUIViewController(_ uiViewController: ScannerContainerViewController, coordinator: Coordinator) {
        uiViewController.scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store, onPick: onPick) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let store: RecognizedItemsStore
        let onPick: (String) -> Void
        init(store: RecognizedItemsStore, onPick: @escaping (String) -> Void) {
            self.store = store
            self.onPick = onPick
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            store.update(with: allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate items: [RecognizedItem], allItems: [RecognizedItem]) {
            store.update(with: allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didRemove items: [RecognizedItem], allItems: [RecognizedItem]) {
            store.update(with: allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .text(let text) = item {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onPick(text.transcript)
            }
        }
    }
}

/// Scanning must start only once the view is actually on screen. Calling
/// `startScanning()` at creation time (before the view is in the hierarchy)
/// fails silently: the preview runs but nothing is ever recognized — exactly
/// what broke the tab-embedded scanner. `DataScannerViewController` can't be
/// subclassed, so this plain container hosts it as a child and starts scanning
/// in its own `viewDidAppear`, after camera permission is confirmed — the same
/// timing as the sheet-based flow that already worked.
final class ScannerContainerViewController: UIViewController {
    let scanner: DataScannerViewController

    /// Fired for any tap on the viewfinder. `cancelsTouchesInView` stays off,
    /// so the scanner's own tap-to-pick keeps working alongside.
    var onTap: (() -> Void)?

    init(scanner: DataScannerViewController) {
        self.scanner = scanner
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

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
        onTap?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { [weak scanner] in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted, let scanner else { return }
            do {
                try scanner.startScanning()
            } catch {
                print("DailyDose scanner failed to start: \(error.localizedDescription)")
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scanner.stopScanning()
    }
}

/// Fallback shown where the camera scanner can't run (e.g. the simulator).
struct ScannerUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Camera scanning unavailable", systemImage: "camera.fill")
        } description: {
            Text("Label scanning needs a device with a camera. On this device, please type the medication details instead.")
        }
    }
}

/// Extracts a clean medication name and strength from raw OCR text
/// ("METFORMIN HCL 500 MG TABLET" → name "Metformin Hcl", strength "500 mg tablet").
enum LabelScanParser {
    private static let strengthPattern = #"\d+(?:[.,]\d+)?\s?(?:mg|milligrams?|mcg|µg|g|ml|iu|%)"#

    /// Whether the text looks like it contains a dosage strength — used to rank
    /// shutter candidates (a fragment with "500 mg" is almost certainly the label line).
    static func containsStrength(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: strengthPattern, options: .caseInsensitive) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func parse(_ raw: String) -> (name: String, strength: String) {
        // OCR fragments can span several lines — flatten to a single line first
        // so a label like "PANADOL\nEACH TABLET\nCONTAINS" becomes one clean string.
        let text = flatten(raw)
        let pattern = strengthPattern
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else {
            return (prettify(text), "")
        }

        var strength = String(text[range])
        var name = String(text[..<range.lowerBound])

        // Absorb a trailing dosage-form word ("tablet", "capsule", …) into the strength line.
        let formPattern = #"^\s+(tablet|tablets|capsule|capsules|cap|caps|tab|tabs|oral|solution|cream|spray|patch|drops?|inhaler|injection|lotion|ointment|suspension)\b"#
        if let formRegex = try? NSRegularExpression(pattern: formPattern, options: .caseInsensitive) {
            let tail = String(text[range.upperBound...])
            if let formMatch = formRegex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
               let formRange = Range(formMatch.range, in: tail) {
                strength += tail[formRange]
            }
        }

        name = name.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        if name.isEmpty { name = text }
        return (prettify(name), prettifyStrength(strength))
    }

    /// Collapses any newline flavor into single spaces — label scans come in
    /// as vertical stacks of fragments; stored fields must be single-line.
    static func flatten(_ s: String) -> String {
        s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func prettify(_ s: String) -> String {
        s.lowercased().capitalized
    }

    private static func prettifyStrength(_ s: String) -> String {
        // Keep the number, normalize unit/form casing ("500 MG TABLET" → "500 mg tablet").
        var result = s.trimmingCharacters(in: .whitespaces)
        for unit in ["MG", "MCG", "ML", "IU", "G"] {
            result = result.replacingOccurrences(of: " \(unit)", with: " \(unit.lowercased())",
                                                 options: .caseInsensitive)
        }
        for form in ["TABLETS", "TABLET", "CAPSULES", "CAPSULE", "CAPS", "CAP", "TABS", "TAB",
                     "ORAL", "SOLUTION", "CREAM", "SPRAY", "PATCH", "DROPS", "DROP",
                     "INHALER", "INJECTION", "LOTION", "OINTMENT", "SUSPENSION"] {
            result = result.replacingOccurrences(of: " \(form)", with: " \(form.lowercased())",
                                                 options: .caseInsensitive)
        }
        return result
    }
}
