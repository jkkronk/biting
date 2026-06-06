import Foundation
import QuartzCore

/// Cheap timestamp gate that admits at most one frame per `minInterval` and drops the
/// rest, so Vision processes at a fixed cap (≤12 fps) regardless of the camera's native
/// rate. Combined with `alwaysDiscardsLateVideoFrames = true` this prevents any backlog.
///
/// Pure logic (clock injected) so it's unit-testable. Not thread-safe on its own — the
/// caller drives it from a single serial queue.
final class FrameThrottle {
    /// Minimum seconds between accepted frames (e.g. `1.0 / 12`).
    private(set) var minInterval: CFTimeInterval
    private var lastAccepted: CFTimeInterval = -.greatestFiniteMagnitude

    init(targetFPS: Int) {
        self.minInterval = 1.0 / Double(max(1, targetFPS))
    }

    /// Update the cap (e.g. on thermal backoff). Does not reset the last-accepted clock.
    func setTargetFPS(_ fps: Int) {
        minInterval = 1.0 / Double(max(1, fps))
    }

    /// Returns true (and records the timestamp) if this frame should be processed.
    func shouldProcess(now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard now - lastAccepted >= minInterval else { return false }
        lastAccepted = now
        return true
    }
}
