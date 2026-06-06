import AppKit
import AVFoundation

/// Thin wrapper over the `AVCaptureDevice` video authorization flow.
enum CameraPermission {
    enum Status {
        case notDetermined
        case authorized
        case denied
        case restricted

        init(_ status: AVAuthorizationStatus) {
            switch status {
            case .authorized: self = .authorized
            case .denied: self = .denied
            case .restricted: self = .restricted
            case .notDetermined: self = .notDetermined
            @unknown default: self = .denied
            }
        }
    }

    /// Current authorization status, without prompting.
    static var current: Status {
        Status(AVCaptureDevice.authorizationStatus(for: .video))
    }

    /// Requests access if undetermined; returns the resulting status.
    static func request() async -> Status {
        switch current {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return granted ? .authorized : .denied
        default:
            return current
        }
    }

    /// Deep-links to the Camera pane of System Settings so a denied user can re-enable
    /// access. The URL lives here so it has a single home.
    @MainActor
    static func openSystemSettings() {
        let preferred = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        let fallback = "x-apple.systempreferences:Privacy_Camera"
        if let url = URL(string: preferred), NSWorkspace.shared.open(url) {
            return
        }
        if let url = URL(string: fallback) {
            NSWorkspace.shared.open(url)
        }
    }
}
