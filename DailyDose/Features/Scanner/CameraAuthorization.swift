import AVFoundation
import SwiftUI

/// Camera permission as an explicit state the UI can render.
///
/// The old scanner checked only whether the *device* supported scanning. When
/// the user denied access, `requestAccess` returned false, the code returned
/// silently, and they were left staring at a black rectangle with a shutter
/// button and no explanation — permanently, with no route to Settings.
@MainActor
@Observable
final class CameraAuthorization {
    enum State: Equatable {
        case undetermined
        case authorized
        case denied
        case restricted
        /// No camera, or the scanner isn't supported (the Simulator, mostly).
        case unavailable
    }

    private(set) var state: State = .undetermined

    /// Whether the device can run the live text scanner at all, independent of
    /// permission.
    static var isSupportedOnDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    func refresh() {
        guard Self.isSupportedOnDevice else {
            state = .unavailable
            return
        }
        state = switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .undetermined
        @unknown default: .unavailable
        }
    }

    /// Prompts only when the status is genuinely undetermined. Calling
    /// `requestAccess` after a denial does nothing and shows no system alert,
    /// which is why the denied case needs its own UI rather than another prompt.
    func request() async {
        guard Self.isSupportedOnDevice else {
            state = .unavailable
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            refresh()
            return
        }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        refresh()
    }
}

/// Explains why the camera isn't available, and offers the only action that can
/// actually fix it.
struct CameraUnavailableView: View {
    let state: CameraAuthorization.State
    var onRequest: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            switch state {
            case .denied:
                Button(String(localized: "Open Settings")) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .prominentButton()
            case .undetermined:
                if let onRequest {
                    Button(String(localized: "Allow Camera"), action: onRequest)
                        .prominentButton()
                }
            default:
                EmptyView()
            }
        }
    }

    private var title: String {
        switch state {
        case .denied: String(localized: "Camera access is off")
        case .restricted: String(localized: "Camera unavailable")
        case .unavailable: String(localized: "Scanning needs a camera")
        default: String(localized: "Camera access needed")
        }
    }

    private var systemImage: String {
        state == .denied ? "camera.badge.ellipsis" : "camera.fill"
    }

    private var message: String {
        switch state {
        case .denied:
            String(localized: "Daily Meds reads medication labels using the camera. Turn it on in Settings, or type the details instead.")
        case .restricted:
            String(localized: "Camera access is restricted on this device. You can still type medication details by hand.")
        case .unavailable:
            String(localized: "This device can't scan labels. Type the medication details instead — it takes about the same time.")
        default:
            String(localized: "Daily Meds reads the name and strength from the label. Nothing is saved or sent anywhere.")
        }
    }
}
