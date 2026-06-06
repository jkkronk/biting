import Foundation

/// Single source of truth for what the capture pipeline is doing right now.
///
/// ``CameraController`` publishes transitions through ``FrameSource/onStateChange``
/// and ``AppState`` mirrors the latest value into `@Published sessionState`, from
/// which the menu UI derives its label and symbol.
enum CameraSessionState: Equatable {
    /// Not watching; the session is stopped and the camera LED is off.
    case idle
    /// Permission resolution and/or session configuration is in flight.
    case starting
    /// The session is running and delivering frames.
    case running
    /// The user still wants to watch, but capture is auto-paused (see ``PauseReason``).
    case pausedAuto(PauseReason)
    /// Camera access is not granted; carries the concrete authorization status.
    case noPermission(CameraPermission.Status)
    /// No usable camera device is present.
    case noDevice
    /// The `AVCaptureSession` was interrupted; human-readable reason.
    case interrupted(String)
    /// An unrecoverable runtime error; human-readable message.
    case failed(String)

    /// Why capture was auto-paused. Used as the reference-counting key in
    /// ``PowerCoordinator`` so overlapping causes don't prematurely resume.
    enum PauseReason: Equatable, CaseIterable {
        case screenLocked
        case displayAsleep
        case systemAsleep
        case thermal
        case lowPower
    }
}

/// Reference-counts the reasons capture is auto-paused so overlapping causes (e.g.
/// screen locked *and* display asleep) don't prematurely resume. The session should
/// run only when this is empty (and the user wants to watch, and we're authorized).
///
/// Extracted as a pure value type so the policy is unit-testable without AVFoundation.
struct PauseReasonSet: Equatable {
    private(set) var reasons: Set<CameraSessionState.PauseReason> = []

    var isPaused: Bool { !reasons.isEmpty }

    /// A representative active reason, for surfacing in `.pausedAuto`.
    var primaryReason: CameraSessionState.PauseReason? { reasons.first }

    mutating func insert(_ reason: CameraSessionState.PauseReason) {
        reasons.insert(reason)
    }

    mutating func remove(_ reason: CameraSessionState.PauseReason) {
        reasons.remove(reason)
    }

    mutating func clear() {
        reasons.removeAll()
    }
}

extension CameraSessionState.PauseReason {
    /// Short, user-facing description of the pause cause.
    var description: String {
        switch self {
        case .screenLocked: return "screen locked"
        case .displayAsleep: return "display asleep"
        case .systemAsleep: return "system asleep"
        case .thermal: return "thermal pressure"
        case .lowPower: return "low power mode"
        }
    }
}
