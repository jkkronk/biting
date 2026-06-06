import CoreVideo
import ImageIO
import XCTest
@testable import Shoo

/// A scripted ``FrameAnalyzing`` so the coordinator (`HandFaceDetector`) can be tested
/// without a camera or Vision: it returns canned observations regardless of the buffer.
final class MockFrameAnalyzer: FrameAnalyzing {
    var observation: FrameObservation
    private(set) var analyzeCount = 0

    init(observation: FrameObservation) {
        self.observation = observation
    }

    func analyze(_ pixelBuffer: CVPixelBuffer,
                 orientation: CGImagePropertyOrientation) -> FrameObservation {
        analyzeCount += 1
        return observation
    }
}

/// Coordinator-level tests: the pipeline wires analyzer→scorer→gesture and emits a
/// ``DetectionResult`` per processed frame, with config swaps taking effect.
final class HandFaceDetectorTests: XCTestCase {
    private let buffer = MockFrameSource.makePixelBuffer()

    /// An observation with a fingertip planted in the mouth box.
    private func mouthContactObservation() -> FrameObservation {
        let face = SyntheticFixture.face
        let hand = HandLandmarks(
            fingertips: [HandPoint(location: SyntheticFixture.mouthCenter, confidence: 0.95, weight: 1.0)])
        return FrameObservation(face: face, hands: [hand])
    }

    func testSustainedMouthContactEmitsContact() {
        let analyzer = MockFrameAnalyzer(observation: mouthContactObservation())
        // The mock ignores the buffer; frames arrive pre-downscaled in production.
        let detector = HandFaceDetector(
            analyzer: analyzer,
            config: DetectorConfig.from(sensitivity: 0.5))

        var last: DetectionResult = .none
        // Feed enough frames to clear smoothing + sustain. Serialize via the detector queue.
        for _ in 0..<10 {
            let exp = expectation(description: "frame")
            detector.process(buffer, orientation: .up) { result in
                last = result
                exp.fulfill()
            }
            wait(for: [exp], timeout: 2.0)
        }
        XCTAssertTrue(last.isContact)
        XCTAssertEqual(last.region, .mouth)
    }

    func testDisabledMouthGestureSuppressesContact() {
        // Same mouth-contact frames, but the user only watches nose-picking → mouth is gated.
        let analyzer = MockFrameAnalyzer(observation: mouthContactObservation())
        let config = DetectorConfig.from(sensitivity: 0.5).applying(gestures: [.nosePicking])
        let detector = HandFaceDetector(analyzer: analyzer, config: config)

        var last: DetectionResult = .mouthContact(confidence: 1.0)
        for _ in 0..<12 {
            let exp = expectation(description: "frame")
            detector.process(buffer, orientation: .up) { last = $0; exp.fulfill() }
            wait(for: [exp], timeout: 2.0)
        }
        XCTAssertEqual(last, .none, "mouth contact must not fire when the gesture is disabled")
    }

    func testNoFaceEmitsNone() {
        let analyzer = MockFrameAnalyzer(observation: FrameObservation(face: nil, hands: []))
        let detector = HandFaceDetector(analyzer: analyzer)

        var last: DetectionResult = .mouthContact(confidence: 1.0)
        for _ in 0..<5 {
            let exp = expectation(description: "frame")
            detector.process(buffer, orientation: .up) { result in
                last = result
                exp.fulfill()
            }
            wait(for: [exp], timeout: 2.0)
        }
        XCTAssertEqual(last, .none)
    }

    func testResetClearsTemporalState() {
        let analyzer = MockFrameAnalyzer(observation: mouthContactObservation())
        let detector = HandFaceDetector(analyzer: analyzer)

        for _ in 0..<10 {
            let exp = expectation(description: "frame")
            detector.process(buffer, orientation: .up) { _ in exp.fulfill() }
            wait(for: [exp], timeout: 2.0)
        }
        detector.reset()
        // After reset, switch the analyzer to "no hands" and confirm we read .none quickly.
        analyzer.observation = FrameObservation(face: SyntheticFixture.face, hands: [])
        var last: DetectionResult = .mouthContact(confidence: 1.0)
        for _ in 0..<6 {
            let exp = expectation(description: "frame")
            detector.process(buffer, orientation: .up) { result in
                last = result; exp.fulfill()
            }
            wait(for: [exp], timeout: 2.0)
        }
        XCTAssertEqual(last, .none)
    }
}
