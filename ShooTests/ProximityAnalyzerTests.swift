import XCTest
@testable import Shoo

/// Tests for the pure per-frame proximity scorer. This is the piece most worth covering
/// since it encodes the core "is a fingertip at the mouth/nose" decision independent of
/// camera/Vision.
final class ProximityAnalyzerTests: XCTestCase {
    // A face occupying the center of normalized image space.
    private let face = CGRect(x: 0.35, y: 0.35, width: 0.30, height: 0.30)

    // MARK: - Legacy box-overlap wrapper (kept green)

    func testHandClearlyInsideFaceTriggers() {
        let analyzer = ProximityAnalyzer()
        let points = [CGPoint(x: 0.45, y: 0.45), CGPoint(x: 0.55, y: 0.50)]
        XCTAssertTrue(analyzer.isHandInFace(face: face, handPoints: points, margin: 0.0, minPointsInside: 2))
    }

    func testHandFarFromFaceDoesNotTrigger() {
        let analyzer = ProximityAnalyzer()
        let points = [CGPoint(x: 0.05, y: 0.05), CGPoint(x: 0.95, y: 0.95)]
        XCTAssertFalse(analyzer.isHandInFace(face: face, handPoints: points, margin: 0.0, minPointsInside: 2))
    }

    func testSinglePointInsideDoesNotTriggerWhenTwoRequired() {
        let analyzer = ProximityAnalyzer()
        let points = [CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.95, y: 0.95)]
        XCTAssertFalse(analyzer.isHandInFace(face: face, handPoints: points, margin: 0.0, minPointsInside: 2))
    }

    func testMarginExpandsHitRegion() {
        let pointJustOutside = [CGPoint(x: 0.66, y: 0.50), CGPoint(x: 0.67, y: 0.50)]
        let analyzer = ProximityAnalyzer()
        XCTAssertFalse(analyzer.isHandInFace(face: face, handPoints: pointJustOutside, margin: 0.0, minPointsInside: 2))
        XCTAssertTrue(analyzer.isHandInFace(face: face, handPoints: pointJustOutside, margin: 0.3, minPointsInside: 2))
    }

    func testEmptyInputsDoNotTrigger() {
        let analyzer = ProximityAnalyzer()
        XCTAssertFalse(analyzer.isHandInFace(face: face, handPoints: []))
        XCTAssertFalse(analyzer.isHandInFace(face: .null, handPoints: [CGPoint(x: 0.5, y: 0.5)]))
    }

    // MARK: - distanceToBox

    func testSignedDistanceInsideIsZero() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        XCTAssertEqual(ProximityAnalyzer.distanceToBox(CGPoint(x: 0.4, y: 0.4), box), 0, accuracy: 1e-9)
        // On the boundary is still 0.
        XCTAssertEqual(ProximityAnalyzer.distanceToBox(CGPoint(x: 0.2, y: 0.4), box), 0, accuracy: 1e-9)
    }

    func testSignedDistanceOutsideIsMonotone() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let near = ProximityAnalyzer.distanceToBox(CGPoint(x: 0.65, y: 0.4), box)   // 0.05 right
        let far = ProximityAnalyzer.distanceToBox(CGPoint(x: 0.80, y: 0.4), box)    // 0.20 right
        XCTAssertEqual(near, 0.05, accuracy: 1e-9)
        XCTAssertEqual(far, 0.20, accuracy: 1e-9)
        XCTAssertLessThan(near, far)
    }

    func testSignedDistanceCornerIsEuclidean() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)  // maxX=maxY=0.6
        let d = ProximityAnalyzer.distanceToBox(CGPoint(x: 0.9, y: 0.9), box)
        XCTAssertEqual(d, (0.3 * 0.3 + 0.3 * 0.3).squareRoot(), accuracy: 1e-9)
    }

    // MARK: - Per-region soft score

    func testScoreInsideIsFullForUnitWeightConfidence() {
        let analyzer = ProximityAnalyzer(reach: 0.1)
        let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let tip = HandPoint(location: CGPoint(x: 0.5, y: 0.5), confidence: 1.0, weight: 1.0)
        XCTAssertEqual(analyzer.score(region: box, fingertips: [tip]), 1.0, accuracy: 1e-9)
    }

    func testScoreFallsOffWithDistance() {
        let analyzer = ProximityAnalyzer(reach: 0.1)
        let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)  // maxX = 0.6
        // 0.05 outside → proximity 0.5.
        let tip = HandPoint(location: CGPoint(x: 0.65, y: 0.5), confidence: 1.0, weight: 1.0)
        XCTAssertEqual(analyzer.score(region: box, fingertips: [tip]), 0.5, accuracy: 1e-9)
    }

    func testScoreZeroBeyondReach() {
        let analyzer = ProximityAnalyzer(reach: 0.1)
        let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let tip = HandPoint(location: CGPoint(x: 0.9, y: 0.5), confidence: 1.0, weight: 1.0)
        XCTAssertEqual(analyzer.score(region: box, fingertips: [tip]), 0.0, accuracy: 1e-9)
    }

    func testScoreWeightsAndConfidenceScaleContribution() {
        let analyzer = ProximityAnalyzer(reach: 0.1)
        let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let tip = HandPoint(location: CGPoint(x: 0.5, y: 0.5), confidence: 0.5, weight: 0.4)
        XCTAssertEqual(analyzer.score(region: box, fingertips: [tip]), 0.2, accuracy: 1e-9)
    }

    // MARK: - frameScore + chin-rest penalty

    /// A fingertip squarely in the mouth box yields a strong mouth score, weak nose.
    func testFrameScoreMouthContact() {
        let landmarks = FaceLandmarks(
            boundingBox: face,
            outerLips: [CGPoint(x: 0.45, y: 0.40), CGPoint(x: 0.55, y: 0.43)],
            nose: [CGPoint(x: 0.47, y: 0.52), CGPoint(x: 0.53, y: 0.55)],
            medianLine: [CGPoint(x: 0.50, y: 0.40), CGPoint(x: 0.50, y: 0.38)])
        let geometry = FaceGeometry(landmarks: landmarks, regionPad: 0.02)
        let analyzer = ProximityAnalyzer(reach: 0.09)
        let center = CGPoint(x: geometry.mouthBox.midX, y: geometry.mouthBox.midY)
        let tip = HandPoint(location: center, confidence: 1.0, weight: 1.0)

        let score = analyzer.frameScore(geometry: geometry, fingertips: [tip])
        XCTAssertGreaterThan(score.mouthScore, 0.8)
        XCTAssertEqual(score.dominant, .mouth)
    }

    /// Knuckles resting in the chin band (below the mouth, no fingertip at the lips) are
    /// suppressed by the chin-rest penalty — the key false-positive rejection.
    func testChinRestPenaltySuppressesMouthScore() {
        // Mouth box high in the face; chin band well below it.
        let landmarks = FaceLandmarks(
            boundingBox: CGRect(x: 0.35, y: 0.35, width: 0.30, height: 0.30),
            outerLips: [CGPoint(x: 0.45, y: 0.55), CGPoint(x: 0.55, y: 0.57)],
            nose: [CGPoint(x: 0.47, y: 0.62), CGPoint(x: 0.53, y: 0.64)],
            medianLine: [CGPoint(x: 0.50, y: 0.48)])  // chin band: y in [0.35, 0.48]
        let geometry = FaceGeometry(landmarks: landmarks, regionPad: 0.01)
        let analyzer = ProximityAnalyzer(reach: 0.2, chinRestPenalty: 0.4)

        // Fingertip in the chin band but clearly outside the mouth box.
        let resting = HandPoint(location: CGPoint(x: 0.50, y: 0.40), confidence: 1.0, weight: 1.0)
        let penalized = analyzer.frameScore(geometry: geometry, fingertips: [resting])

        // Same fingertip without penalty (compute raw score) is higher.
        let raw = analyzer.score(region: geometry.mouthBox, fingertips: [resting])
        XCTAssertGreaterThan(raw, 0)
        XCTAssertEqual(penalized.mouthScore, raw * 0.4, accuracy: 1e-9)
    }

    /// A real fingertip *inside* the mouth box is NOT penalized even if another point is
    /// in the chin band.
    func testChinRestPenaltyNotAppliedWhenFingertipInMouth() {
        let landmarks = FaceLandmarks(
            boundingBox: CGRect(x: 0.35, y: 0.35, width: 0.30, height: 0.30),
            outerLips: [CGPoint(x: 0.45, y: 0.55), CGPoint(x: 0.55, y: 0.57)],
            nose: [CGPoint(x: 0.47, y: 0.62), CGPoint(x: 0.53, y: 0.64)],
            medianLine: [CGPoint(x: 0.50, y: 0.48)])
        let geometry = FaceGeometry(landmarks: landmarks, regionPad: 0.02)
        let analyzer = ProximityAnalyzer(reach: 0.2, chinRestPenalty: 0.4)
        let inMouth = HandPoint(location: CGPoint(x: geometry.mouthBox.midX, y: geometry.mouthBox.midY),
                                confidence: 1.0, weight: 1.0)
        let raw = analyzer.score(region: geometry.mouthBox, fingertips: [inMouth])
        let result = analyzer.frameScore(geometry: geometry, fingertips: [inMouth])
        XCTAssertEqual(result.mouthScore, raw, accuracy: 1e-9)
    }
}
