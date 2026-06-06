import XCTest
@testable import Shoo

/// Region extraction from authored landmark fixtures, including the face-box fallback path.
final class FaceGeometryTests: XCTestCase {
    private let box = CGRect(x: 0.35, y: 0.35, width: 0.30, height: 0.30)

    func testImageNormalizedMath() {
        let box = CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.6)
        let p = FaceGeometry.imageNormalized(CGPoint(x: 0.5, y: 0.5), in: box)
        XCTAssertEqual(p.x, 0.2 + 0.5 * 0.4, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.1 + 0.5 * 0.6, accuracy: 1e-9)
    }

    func testBoundingBoxOfPoints() {
        let pts = [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.4, y: 0.6)]
        let bb = FaceGeometry.boundingBox(of: pts)
        XCTAssertEqual(bb, CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.5))
        XCTAssertNil(FaceGeometry.boundingBox(of: []))
    }

    func testMouthAndNoseBoxesFromLandmarks() {
        let landmarks = FaceLandmarks(
            boundingBox: box,
            outerLips: [CGPoint(x: 0.45, y: 0.42), CGPoint(x: 0.55, y: 0.45)],
            nose: [CGPoint(x: 0.47, y: 0.52), CGPoint(x: 0.53, y: 0.56)],
            medianLine: [CGPoint(x: 0.50, y: 0.40)])
        let g = FaceGeometry(landmarks: landmarks, regionPad: 0.01)

        // Mouth box surrounds the lips points (with pad).
        XCTAssertTrue(g.mouthBox.contains(CGPoint(x: 0.50, y: 0.435)))
        // Nose box surrounds the nose points.
        XCTAssertTrue(g.noseBox.contains(CGPoint(x: 0.50, y: 0.54)))
        // Padding inflates beyond the raw lip span.
        XCTAssertLessThan(g.mouthBox.minX, 0.45)
    }

    func testChinBandIsBelowMedianLine() {
        let landmarks = FaceLandmarks(
            boundingBox: box,
            outerLips: [CGPoint(x: 0.45, y: 0.50)],
            nose: [CGPoint(x: 0.50, y: 0.55)],
            medianLine: [CGPoint(x: 0.50, y: 0.45), CGPoint(x: 0.50, y: 0.48)])
        let g = FaceGeometry(landmarks: landmarks, regionPad: 0.01)
        // Chin band runs from face bottom (0.35) up to lowest median point (0.45).
        XCTAssertEqual(g.chinBand.minY, 0.35, accuracy: 1e-9)
        XCTAssertEqual(g.chinBand.maxY, 0.45, accuracy: 1e-9)
        XCTAssertTrue(g.chinBand.contains(CGPoint(x: 0.50, y: 0.40)))
        XCTAssertFalse(g.chinBand.contains(CGPoint(x: 0.50, y: 0.50)))
    }

    func testFallbackWhenLandmarksMissing() {
        // No landmark points at all → boxes synthesized from face-box fractions.
        let landmarks = FaceLandmarks(boundingBox: box)
        let g = FaceGeometry(landmarks: landmarks, regionPad: 0.01)
        XCTAssertFalse(g.mouthBox.isEmpty)
        XCTAssertFalse(g.noseBox.isEmpty)
        // Mouth fallback sits lower (smaller y) than nose fallback.
        XCTAssertLessThan(g.mouthBox.midY, g.noseBox.midY)
        // Both fallbacks live inside the face box footprint.
        XCTAssertTrue(box.insetBy(dx: -0.05, dy: -0.05).contains(CGPoint(x: g.mouthBox.midX, y: g.mouthBox.midY)))
    }
}
