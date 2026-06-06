import CoreGraphics
import Foundation

/// Pure geometry: turns `FaceLandmarks` into the three target regions the analyzer
/// scores against — `mouthBox`, `noseBox`, and the `chinBand` exclusion zone — all in
/// image-normalized space (origin bottom-left, y up).
///
/// No Vision/AVFoundation imports; fully unit-tested with hand-authored landmark fixtures.
struct FaceGeometry: Equatable {
    /// Mouth target (bounding box of `outerLips`, inflated by `regionPad`).
    let mouthBox: CGRect
    /// Nose target (bounding box of `nose`, inflated by `regionPad`).
    let noseBox: CGRect
    /// Lower-jaw band: from the face box bottom up to the lowest median-line point.
    /// A fingertip here but *outside* the mouth box is treated as resting, not biting.
    let chinBand: CGRect

    /// Build regions from landmarks. When a landmark region is empty/low-confidence we
    /// synthesize the box from face-box fractions so detection degrades gracefully
    /// instead of blanking out.
    init(landmarks: FaceLandmarks, regionPad: CGFloat) {
        let box = landmarks.boundingBox

        // Mouth ≈ lower-center third of the face when landmarks are missing.
        let mouthFallback = CGRect(
            x: box.minX + box.width * 0.30,
            y: box.minY + box.height * 0.12,
            width: box.width * 0.40,
            height: box.height * 0.22)
        let rawMouth = FaceGeometry.boundingBox(of: landmarks.outerLips) ?? mouthFallback

        // Nose ≈ vertical center of the face when landmarks are missing.
        let noseFallback = CGRect(
            x: box.minX + box.width * 0.38,
            y: box.minY + box.height * 0.40,
            width: box.width * 0.24,
            height: box.height * 0.22)
        let rawNose = FaceGeometry.boundingBox(of: landmarks.nose) ?? noseFallback

        self.mouthBox = rawMouth.insetBy(dx: -regionPad, dy: -regionPad)
        self.noseBox = rawNose.insetBy(dx: -regionPad, dy: -regionPad)

        // Chin band: bottom of the face box up to the lowest median-line point (the
        // lower jaw). Fall back to the bottom 18% of the face box.
        let medianLow = landmarks.medianLine.map(\.y).min()
        let topY = medianLow ?? (box.minY + box.height * 0.18)
        let clampedTop = max(box.minY, min(topY, box.maxY))
        self.chinBand = CGRect(
            x: box.minX, y: box.minY,
            width: box.width, height: max(0, clampedTop - box.minY))
    }

    /// Convert a face-box-normalized landmark point (0…1 within the box) to
    /// image-normalized space.
    static func imageNormalized(_ p: CGPoint, in box: CGRect) -> CGPoint {
        CGPoint(x: box.minX + p.x * box.width,
                y: box.minY + p.y * box.height)
    }

    /// The axis-aligned bounding box of a set of points, or nil if empty.
    static func boundingBox(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
