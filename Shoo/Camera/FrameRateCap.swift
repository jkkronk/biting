import CoreMedia

/// Pure helper for clamping a desired capture frame rate into a device's supported ranges.
///
/// Setting `AVCaptureDevice.activeVideoMin/MaxFrameDuration` to a value outside the active
/// format's `videoSupportedFrameRateRanges` raises an Objective-C `NSException` (uncatchable
/// from Swift), so the value must be provably in range *before* it's applied. Kept free of
/// AVFoundation so it can be unit-tested in isolation (see `ShooTests/FrameRateCapTests`).
enum FrameRateCap {
    /// Clamp `desiredFPS` into the device's supported frame-rate ranges and return the frame
    /// duration to lock `activeVideoMin/MaxFrameDuration` to.
    ///
    /// - Parameters:
    ///   - desiredFPS: the fps we'd like to cap to (may be below the device floor).
    ///   - ranges: `(minFrameRate, maxFrameRate)` pairs, mapped from
    ///     `AVCaptureDevice.Format.videoSupportedFrameRateRanges`.
    /// - Returns: the clamped fps and the matching `1/fps` duration, or `nil` if there are no
    ///   usable ranges (caller should then leave the device default untouched).
    static func clamp(desiredFPS: Double, into ranges: [(min: Double, max: Double)])
        -> (fps: Double, duration: CMTime)? {
        // Keep only sane ranges (positive, min <= max).
        let valid = ranges.filter { $0.min > 0 && $0.max >= $0.min }
        guard !valid.isEmpty else { return nil }

        let clampedFPS: Double
        if valid.contains(where: { desiredFPS >= $0.min && desiredFPS <= $0.max }) {
            // Already achievable as-is.
            clampedFPS = desiredFPS
        } else {
            // Snap to the nearest range, clamping into that range's [min, max]. Handles
            // below-floor → floor, above-ceiling → ceiling, and non-contiguous gaps.
            let nearest = valid.min { lhs, rhs in
                distance(desiredFPS, to: lhs) < distance(desiredFPS, to: rhs)
            }!
            clampedFPS = Swift.min(Swift.max(desiredFPS, nearest.min), nearest.max)
        }

        let timescale = Int32(clampedFPS.rounded())
        return (clampedFPS, CMTime(value: 1, timescale: max(1, timescale)))
    }

    /// Distance from `fps` to a range: 0 inside, else the gap to the nearer edge.
    private static func distance(_ fps: Double, to range: (min: Double, max: Double)) -> Double {
        if fps < range.min { return range.min - fps }
        if fps > range.max { return fps - range.max }
        return 0
    }
}
