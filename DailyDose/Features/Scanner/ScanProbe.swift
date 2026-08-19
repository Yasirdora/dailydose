#if DEBUG
import Foundation
import VisionKit
import Vision

/// **Temporary.** Instrumentation for "barcode scanning does nothing on device,
/// while OCR works in the same session".
///
/// Delete this file, and the four call sites in `LabelScanner.swift` that
/// mention `ScanProbe`, once the cause is known. It is `#if DEBUG` in its
/// entirety, so nothing here ships.
///
/// It exists to separate three explanations that look identical from the
/// outside:
///
/// 1. **No `.barcode` items arrive at all** — a detection problem. Either the
///    session never started (the `startScanning()` error is swallowed), or the
///    symbology is not live on this device, or the code is too small in frame
///    to resolve. The launch banner and `barcodeItems == 0` say which.
/// 2. **Items arrive with empty payloads** — the `payloadData` question. Both
///    payload accessors are logged separately, so "the data is nil and the
///    string is fine" is distinguishable from "both are nil".
/// 3. **Payloads arrive and `interpret` returns nil** — a parser gap. The hex
///    of the exact bytes handed to the parser is logged, which is enough to
///    reproduce the failure in a unit test without a device.
@MainActor
enum ScanProbe {

    private static var didLogLaunch = false
    private static var callbacks = 0
    private static var barcodeItems = 0
    private static var interpreted = 0
    private static var lastHeartbeat = Date.distantPast

    // MARK: - Launch

    /// Logged once: which symbologies this device actually supports, and which
    /// of the ones we ask for are among them.
    ///
    /// `DataScannerViewController` throws from `startScanning()` if asked for a
    /// symbology it cannot do — and that error is currently swallowed, which
    /// would look exactly like "barcodes do nothing" except that OCR would stop
    /// too. Printing the intersection makes a missing symbology obvious rather
    /// than inferred.
    static func logLaunch(requested: [VNBarcodeSymbology]) {
        guard !didLogLaunch else { return }
        didLogLaunch = true

        let supported = supportedSymbologies()
        print("""
        [scan-probe] ---- launch ----
        [scan-probe] DataScannerViewController isSupported=\(DataScannerViewController.isSupported) \
        isAvailable=\(DataScannerViewController.isAvailable)
        [scan-probe] device supports \(supported.count) symbologies
        """)
        for symbology in supported.sorted(by: { $0.rawValue < $1.rawValue }) {
            print("[scan-probe]   supported: \(symbology.rawValue)")
        }
        let missing = requested.filter { !supported.contains($0) }
        for symbology in requested {
            let mark = supported.contains(symbology) ? "live" : "NOT SUPPORTED"
            print("[scan-probe]   requested: \(symbology.rawValue) — \(mark)")
        }
        if !missing.isEmpty {
            print("[scan-probe] !! \(missing.count) requested symbologies are unsupported; "
                  + "startScanning() may be throwing")
        }
    }

    /// `DetectBarcodesRequest.supportedSymbologies` is iOS 18+ *and* an
    /// instance property, not a static one. The deployment floor here is 17.0,
    /// so the older Vision call is the fallback rather than the exception.
    private static func supportedSymbologies() -> [VNBarcodeSymbology] {
        if #available(iOS 18.0, *) {
            let modern = DetectBarcodesRequest().supportedSymbologies
            print("[scan-probe] via DetectBarcodesRequest (iOS 18+): \(modern.count) symbologies")
        }
        do {
            return try VNDetectBarcodesRequest().supportedSymbologies()
        } catch {
            print("[scan-probe] !! supportedSymbologies() threw: \(error)")
            return []
        }
    }

    /// The geometry the scanner is actually working with, logged once the view
    /// has laid out. Answers "is the camera card big enough to resolve an 8 mm
    /// DataMatrix" with numbers instead of an estimate.
    static func logGeometry(viewBounds: CGRect, regionOfInterest: CGRect, scale: CGFloat) {
        print("""
        [scan-probe] scanner view \(Int(viewBounds.width))×\(Int(viewBounds.height)) pt \
        (\(Int(viewBounds.width * scale))×\(Int(viewBounds.height * scale)) px at @\(Int(scale))x)
        [scan-probe] regionOfInterest \(Int(regionOfInterest.width))×\(Int(regionOfInterest.height)) pt
        """)
    }

    /// The swallowed error, made audible.
    static func logScanningFailure(_ error: Error) {
        print("[scan-probe] !! startScanning() threw: \(error)")
    }

    // MARK: - Per callback

    /// One line per callback, plus full detail for every barcode item.
    ///
    /// Callbacks with no barcodes are throttled to one line a second: they
    /// arrive many times a second and would otherwise scroll the interesting
    /// lines out of the console. The running totals are on every line, so
    /// "no `.barcode` items have *ever* arrived" stays unambiguous.
    static func record(items: [RecognizedItem], interpret: (RecognizedItem.Barcode) -> ScannedPack?) {
        callbacks += 1
        let barcodes: [RecognizedItem.Barcode] = items.compactMap {
            if case .barcode(let barcode) = $0 { return barcode }
            return nil
        }
        let texts = items.count - barcodes.count
        barcodeItems += barcodes.count

        guard !barcodes.isEmpty else {
            let now = Date()
            guard now.timeIntervalSince(lastHeartbeat) >= 1 else { return }
            lastHeartbeat = now
            print("[scan-probe] callback #\(callbacks): \(items.count) items "
                  + "(\(texts) text, 0 barcode) — totals: barcodes=\(barcodeItems) interpreted=\(interpreted)")
            return
        }

        print("[scan-probe] callback #\(callbacks): \(items.count) items "
              + "(\(texts) text, \(barcodes.count) barcode)")

        for (index, barcode) in barcodes.enumerated() {
            let observation = barcode.observation
            let data = observation.payloadData
            let string = observation.payloadStringValue

            print("[scan-probe]   [\(index)] symbology: \(observation.symbology.rawValue)")
            print("[scan-probe]       payloadData: "
                  + (data.map { "\($0.count) bytes" } ?? "nil"))
            if let data {
                print("[scan-probe]       payloadData hex: \(hex(Array(data)))")
            }
            print("[scan-probe]       payloadStringValue: "
                  + (string.map { "\"\($0)\" (\($0.utf8.count) bytes)" } ?? "nil"))
            if let string {
                print("[scan-probe]       payloadString hex: \(hex(Array(string.utf8)))")
            }

            // Exactly the bytes production hands the parser — the same helper,
            // so this can never drift from what actually happens.
            let chosen = RecognizedTextStore.payloadBytes(of: barcode)
            print("[scan-probe]       parser input: "
                  + (chosen.map { "\($0.count) bytes — \(hex($0))" } ?? "nil (nothing to parse)"))

            let pack = interpret(barcode)
            if let pack {
                interpreted += 1
                print("[scan-probe]       interpret: OK key=\(pack.key.rawValue) "
                      + "syntax=\(pack.syntax.rawValue) batch=\(pack.batch ?? "-") "
                      + "expiry=\(pack.expiry.map { "\($0.day)" } ?? "-")")
            } else {
                print("[scan-probe]       interpret: nil  <-- parser rejected these bytes")
            }
        }
        print("[scan-probe]   totals: barcodes=\(barcodeItems) interpreted=\(interpreted)")
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
#endif
