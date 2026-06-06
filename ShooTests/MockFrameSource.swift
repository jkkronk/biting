import CoreVideo
import Foundation
import ImageIO
@testable import Shoo

/// In-memory ``FrameSource`` for headless tests. Lets tests push synthetic frames and
/// synthetic state transitions, and records pause/resume bookkeeping so callers can
/// assert the run-only-when-empty policy without real hardware.
final class MockFrameSource: FrameSource {
    var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?
    var onStateChange: ((CameraSessionState) -> Void)?

    // Recorded intent so tests can assert behavior.
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var pauseReasons: Set<CameraSessionState.PauseReason> = []
    private(set) var lastTargetFPS: Int?
    private(set) var isStarted = false

    func start() {
        startCount += 1
        isStarted = true
    }

    func stop() {
        stopCount += 1
        isStarted = false
        pauseReasons.removeAll()
    }

    func pause(_ reason: CameraSessionState.PauseReason) {
        pauseReasons.insert(reason)
    }

    func resume(_ reason: CameraSessionState.PauseReason) {
        pauseReasons.remove(reason)
    }

    func setTargetFPS(_ fps: Int) {
        lastTargetFPS = fps
    }

    // MARK: - Test helpers

    /// Emit a state transition as if the real controller reported it (on the main actor).
    @MainActor
    func emit(_ state: CameraSessionState) {
        onStateChange?(state)
    }

    /// Push a synthetic frame through `onFrame`.
    func pushFrame(
        _ pixelBuffer: CVPixelBuffer = MockFrameSource.makePixelBuffer(),
        orientation: CGImagePropertyOrientation = .up
    ) {
        onFrame?(pixelBuffer, orientation)
    }

    /// Build a small blank pixel buffer for tests that exercise the frame path.
    static func makePixelBuffer(width: Int = 64, height: Int = 64) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nil, &buffer)
        return buffer!
    }
}
