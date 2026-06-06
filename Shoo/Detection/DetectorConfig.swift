import CoreGraphics
import Foundation

/// Linear interpolation between `a` and `b` by `t` (clamped 0…1). Pure helper used by
/// the sensitivity mapping.
@inline(__always)
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    let t = min(max(t, 0), 1)
    return a + (b - a) * t
}

/// All tunables that drive the detector's eagerness, derived deterministically from the
/// single user-facing `sensitivity` (0…1) setting.
///
/// Pure (CoreGraphics/Foundation only) so the mapping is unit-tested directly for
/// monotonicity, end-stops, and the `exitThreshold < enterThreshold` hysteresis invariant.
/// Higher sensitivity ⇒ triggers earlier/easier.
struct DetectorConfig: Equatable {
    /// Capture radius (image-normalized) for the proximity falloff — how far outside a
    /// region box a fingertip can be and still contribute.
    var reach: CGFloat
    /// EMA enters "gesture" when the smoothed region score rises to this.
    var enterThreshold: Double
    /// EMA leaves "gesture" only when it falls to this (kept below `enterThreshold`).
    var exitThreshold: Double
    /// Inflation applied to the mouth/nose region boxes.
    var regionPad: CGFloat
    /// Consecutive frames the EMA must stay above `enterThreshold` before declaring a gesture.
    var minSustainedFrames: Int
    /// Minimum Vision confidence for a hand joint to count.
    var handPointConfidence: Float
    /// Multiplier applied to mouth score when the contributing fingertips sit in the
    /// chin band but outside the mouth box (suppresses "resting chin on hand").
    var chinRestPenalty: Double
    /// EMA smoothing factor (α): `ema = α·score + (1-α)·ema`. Fixed across sensitivity.
    var smoothing: Double

    init(
        reach: CGFloat,
        enterThreshold: Double,
        exitThreshold: Double,
        regionPad: CGFloat,
        minSustainedFrames: Int,
        handPointConfidence: Float,
        chinRestPenalty: Double = 0.4,
        smoothing: Double = 0.5
    ) {
        self.reach = reach
        self.enterThreshold = enterThreshold
        self.exitThreshold = exitThreshold
        self.regionPad = regionPad
        self.minSustainedFrames = minSustainedFrames
        self.handPointConfidence = handPointConfidence
        self.chinRestPenalty = chinRestPenalty
        self.smoothing = smoothing
    }

    /// Map the 0…1 sensitivity slider to a concrete config.
    ///
    /// End-stops: `s = 0` is very strict (tight boxes, 4 sustained frames, high
    /// confidence floor → near-zero false positives); `s = 1` is generous (large
    /// capture radius, lax thresholds, 2 sustained frames → catches approaches early).
    static func from(sensitivity s: Double) -> DetectorConfig {
        let s = min(max(s, 0), 1)
        return DetectorConfig(
            reach: CGFloat(lerp(0.04, 0.14, s)),       // tiny → generous capture radius
            enterThreshold: lerp(0.75, 0.45, s),        // strict → lax
            exitThreshold: lerp(0.45, 0.25, s),         // always < enter (hysteresis)
            regionPad: CGFloat(lerp(0.01, 0.05, s)),
            minSustainedFrames: s > 0.66 ? 2 : (s > 0.33 ? 3 : 4),
            handPointConfidence: Float(lerp(0.5, 0.25, s))
        )
    }

    /// The default config matching `AppSettings.sensitivity`'s default of 0.5.
    static let `default` = DetectorConfig.from(sensitivity: 0.5)
}
