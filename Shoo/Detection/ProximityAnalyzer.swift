import CoreGraphics
import Foundation

/// Pure, dependency-free per-frame scorer: how close are the hand's fingertips to the
/// mouth / nose target regions, *right now*.
///
/// Kept free of Vision/AVFoundation imports so it can be unit-tested in isolation (see
/// `ShooTests/ProximityAnalyzerTests`). All coordinates are in Vision's normalized image
/// space (origin bottom-left, 0…1 on both axes). Temporal smoothing/hysteresis lives in
/// ``GestureDetector``; this type only answers "this frame".
struct ProximityAnalyzer {
    /// Capture radius: a fingertip exactly `reach` outside a region box contributes 0;
    /// inside contributes 1. Driven by ``DetectorConfig/reach``. `let` (set via the clamping
    /// init) so it can never be mutated to 0 and produce a NaN in `score`.
    let reach: CGFloat

    /// Multiplier applied to the mouth score when the dominant fingertips sit in the
    /// chin band but outside the mouth box (suppresses "resting chin on hand").
    let chinRestPenalty: Double

    init(reach: CGFloat = 0.09, chinRestPenalty: Double = 0.4) {
        self.reach = max(reach, 0.0001)  // avoid divide-by-zero
        self.chinRestPenalty = chinRestPenalty
    }

    // MARK: - Per-region soft score

    /// Soft proximity score (0…1) of a set of weighted, confidence-tagged fingertips to a
    /// region box `R`.
    ///
    /// For each fingertip: `proximity = clamp(1 - d/reach, 0, 1)` where `d` is the distance
    /// to the box (0 inside). Contribution is `proximity · weight · confidence`;
    /// the region score is the sum, clamped to [0, 1].
    func score(region: CGRect, fingertips: [HandPoint]) -> Double {
        guard !region.isNull, !region.isEmpty else { return 0 }
        var total = 0.0
        for tip in fingertips {
            let d = ProximityAnalyzer.distanceToBox(tip.location, region)
            let proximity = max(0, min(1, 1 - Double(d / reach)))
            total += proximity * tip.weight * Double(tip.confidence)
        }
        return min(1, max(0, total))
    }

    /// Compute the per-frame `FrameScore` for one frame's geometry.
    ///
    /// Applies the chin-rest penalty: if the mouth's contributing fingertips are inside
    /// the chin band but outside the mouth box (knuckles/palm resting, no fingertip at
    /// the mouth) the mouth score is suppressed.
    func frameScore(geometry: FaceGeometry, fingertips: [HandPoint]) -> FrameScore {
        var mouth = score(region: geometry.mouthBox, fingertips: fingertips)
        let nose = score(region: geometry.noseBox, fingertips: fingertips)

        if mouth > 0 && shouldPenalizeChinRest(geometry: geometry, fingertips: fingertips) {
            mouth *= chinRestPenalty
        }
        return FrameScore(mouthScore: mouth, noseScore: nose)
    }

    /// True when the fingertips contributing to the mouth region are really just resting
    /// in the chin band (in the lower jaw, not at the lips). That's a chin-rest, not a bite.
    private func shouldPenalizeChinRest(geometry: FaceGeometry, fingertips: [HandPoint]) -> Bool {
        // Is *any* fingertip actually inside the mouth box? If so, it's a real bite.
        let anyInMouth = fingertips.contains { tip in
            tip.weight > 0 && geometry.mouthBox.contains(tip.location)
        }
        if anyInMouth { return false }

        // Otherwise: are the nearby fingertips in the chin band? If so, penalize.
        let anyInChinBand = fingertips.contains { tip in
            tip.weight > 0 && geometry.chinBand.contains(tip.location)
        }
        return anyInChinBand
    }

    // MARK: - Geometry primitive

    /// Euclidean distance from a point to the nearest edge of a box; 0 if the point is
    /// inside (or on the boundary). Pure, trivially unit-testable.
    static func distanceToBox(_ p: CGPoint, _ box: CGRect) -> CGFloat {
        let dx = max(box.minX - p.x, 0, p.x - box.maxX)
        let dy = max(box.minY - p.y, 0, p.y - box.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - Legacy box test (kept for back-compat with original tests)

    /// Returns true when at least `minPointsInside` plain points fall within the face box
    /// expanded by `margin` (fraction of box size).
    ///
    /// Retained so the original box-overlap tests stay meaningful; the production pipeline
    /// uses ``frameScore(geometry:fingertips:)`` instead.
    func isHandInFace(
        face: CGRect,
        handPoints: [CGPoint],
        margin: CGFloat = 0.08,
        minPointsInside: Int = 2
    ) -> Bool {
        guard !face.isNull, !face.isEmpty, !handPoints.isEmpty else { return false }
        let expanded = face.insetBy(dx: -margin * face.width, dy: -margin * face.height)
        let inside = handPoints.reduce(into: 0) { count, point in
            if expanded.contains(point) { count += 1 }
        }
        return inside >= minPointsInside
    }
}
