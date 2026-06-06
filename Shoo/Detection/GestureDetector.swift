import Foundation

/// Pure, stateful temporal model that turns a noisy stream of per-frame ``FrameScore``s
/// into a stable ``DetectionResult``.
///
/// Applies, in order:
///  - **EMA smoothing** of each region score to kill single-frame Vision jitter.
///  - **Sustain:** the smoothed score must stay above `enterThreshold` for
///    `minSustainedFrames` before a gesture is declared.
///  - **Hysteresis:** once active, the gesture persists until the smoothed score drops to
///    `exitThreshold` (< `enterThreshold`), so the boundary doesn't flicker.
///  - **Region arbitration:** when both regions qualify, the higher EMA wins.
///
/// A `struct` with `mutating` methods → deterministic and snapshot-testable by replaying
/// a fixture sequence of `FrameScore`s. No Vision/AVFoundation imports.
struct GestureDetector {
    /// Tunables (smoothing, thresholds, sustain). Hot-swappable from the camera-side queue.
    var config: DetectorConfig

    private var mouthEMA = 0.0
    private var noseEMA = 0.0
    private var sustainedMouth = 0
    private var sustainedNose = 0
    /// The currently-latched gesture (for hysteresis). `.none` until we declare one.
    private(set) var active: DetectionResult = .none

    init(config: DetectorConfig = .default) {
        self.config = config
    }

    /// Feed one frame's score; returns the current verdict after smoothing/hysteresis.
    mutating func ingest(_ s: FrameScore) -> DetectionResult {
        let alpha = config.smoothing
        mouthEMA = alpha * s.mouthScore + (1 - alpha) * mouthEMA
        noseEMA = alpha * s.noseScore + (1 - alpha) * noseEMA

        // Track sustain counters independently per region.
        sustainedMouth = mouthEMA >= config.enterThreshold ? sustainedMouth + 1 : 0
        sustainedNose = noseEMA >= config.enterThreshold ? sustainedNose + 1 : 0

        let mouthQualifies = sustainedMouth >= config.minSustainedFrames
        let noseQualifies = sustainedNose >= config.minSustainedFrames

        switch active {
        case .none:
            // Not latched: declare a gesture once a region has sustained above enter.
            if mouthQualifies || noseQualifies {
                active = arbitrate(mouthQualifies: mouthQualifies, noseQualifies: noseQualifies)
            }

        case .mouthContact:
            // Latched on mouth: leave only when mouth EMA falls to exit. If nose has
            // since become dominant *and* qualifies, switch regions.
            if mouthEMA <= config.exitThreshold {
                active = noseQualifies
                    ? .noseContact(confidence: noseEMA)
                    : .none
            } else if noseQualifies && noseEMA > mouthEMA {
                active = .noseContact(confidence: noseEMA)
            } else {
                active = .mouthContact(confidence: mouthEMA)
            }

        case .noseContact:
            if noseEMA <= config.exitThreshold {
                active = mouthQualifies
                    ? .mouthContact(confidence: mouthEMA)
                    : .none
            } else if mouthQualifies && mouthEMA > noseEMA {
                active = .mouthContact(confidence: mouthEMA)
            } else {
                active = .noseContact(confidence: noseEMA)
            }
        }

        return active
    }

    /// Reset all temporal state (e.g. when capture stops or the face is lost for a while).
    mutating func reset() {
        mouthEMA = 0
        noseEMA = 0
        sustainedMouth = 0
        sustainedNose = 0
        active = .none
    }

    // MARK: - Helpers

    private func arbitrate(mouthQualifies: Bool, noseQualifies: Bool) -> DetectionResult {
        if mouthQualifies && noseQualifies {
            return mouthEMA >= noseEMA
                ? .mouthContact(confidence: mouthEMA)
                : .noseContact(confidence: noseEMA)
        }
        if mouthQualifies { return .mouthContact(confidence: mouthEMA) }
        if noseQualifies { return .noseContact(confidence: noseEMA) }
        return .none
    }
}
