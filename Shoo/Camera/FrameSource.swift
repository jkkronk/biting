import CoreVideo
import ImageIO

/// Abstraction over a source of camera frames so the detection/alerting pipeline can
/// be driven without real hardware (see `MockFrameSource` in the test target).
///
/// ``CameraController`` is the production implementation; tests inject a mock to push
/// synthetic `CVPixelBuffer`s and synthetic state transitions.
protocol FrameSource: AnyObject {
    /// Delivered for every frame, on the source's delivery queue. The orientation is
    /// derived from the capture connection so Vision interprets the buffer correctly
    /// (the detector must not assume `.up`).
    var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)? { get set }

    /// Reports lifecycle/auth/device state transitions. Always invoked on the main actor.
    var onStateChange: ((CameraSessionState) -> Void)? { get set }

    /// Idempotent: ensures the session is running if permitted and not paused.
    func start()

    /// Idempotent: fully tears down capture (camera LED off) while keeping the source reusable.
    func stop()

    /// Auto-pause capture for the given reason (reference-counted by the caller).
    /// Pausing stops frame delivery and turns the camera indicator off, but remembers intent.
    func pause(_ reason: CameraSessionState.PauseReason)

    /// Clear a previously requested pause reason; resumes only when no reasons remain.
    func resume(_ reason: CameraSessionState.PauseReason)

    /// Target capture frame rate. ``PowerCoordinator`` lowers this under thermal/low-power pressure.
    func setTargetFPS(_ fps: Int)
}
