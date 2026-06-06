import XCTest
@testable import Shoo

/// Verifies the sensitivity→config mapping: monotonicity, end-stops, and the hysteresis
/// invariant. This is the contract plan 04's slider drives.
final class DetectorConfigTests: XCTestCase {
    private let samples = [0.0, 0.25, 0.5, 0.75, 1.0]

    func testExitAlwaysBelowEnter() {
        for s in stride(from: 0.0, through: 1.0, by: 0.05) {
            let c = DetectorConfig.from(sensitivity: s)
            XCTAssertLessThan(c.exitThreshold, c.enterThreshold, "hysteresis broken at s=\(s)")
        }
    }

    func testReachIsMonotonicallyIncreasing() {
        let reaches = samples.map { DetectorConfig.from(sensitivity: $0).reach }
        for (a, b) in zip(reaches, reaches.dropFirst()) {
            XCTAssertLessThan(a, b)
        }
    }

    func testThresholdsMonotonicallyDecreasing() {
        let enters = samples.map { DetectorConfig.from(sensitivity: $0).enterThreshold }
        let exits = samples.map { DetectorConfig.from(sensitivity: $0).exitThreshold }
        for (a, b) in zip(enters, enters.dropFirst()) { XCTAssertGreaterThan(a, b) }
        for (a, b) in zip(exits, exits.dropFirst()) { XCTAssertGreaterThan(a, b) }
    }

    func testSustainedFramesNonIncreasing() {
        let frames = samples.map { DetectorConfig.from(sensitivity: $0).minSustainedFrames }
        for (a, b) in zip(frames, frames.dropFirst()) { XCTAssertGreaterThanOrEqual(a, b) }
        XCTAssertEqual(DetectorConfig.from(sensitivity: 0).minSustainedFrames, 4)
        XCTAssertEqual(DetectorConfig.from(sensitivity: 1).minSustainedFrames, 2)
    }

    func testHandConfidenceMonotonicallyDecreasing() {
        let confs = samples.map { DetectorConfig.from(sensitivity: $0).handPointConfidence }
        for (a, b) in zip(confs, confs.dropFirst()) { XCTAssertGreaterThan(a, b) }
    }

    func testEndStops() {
        let strict = DetectorConfig.from(sensitivity: 0)
        XCTAssertEqual(strict.reach, 0.04, accuracy: 1e-6)
        XCTAssertEqual(strict.enterThreshold, 0.75, accuracy: 1e-6)

        let lax = DetectorConfig.from(sensitivity: 1)
        XCTAssertEqual(lax.reach, 0.14, accuracy: 1e-6)
        XCTAssertEqual(lax.enterThreshold, 0.45, accuracy: 1e-6)
    }

    func testClampsOutOfRangeInput() {
        XCTAssertEqual(DetectorConfig.from(sensitivity: -5), DetectorConfig.from(sensitivity: 0))
        XCTAssertEqual(DetectorConfig.from(sensitivity: 5), DetectorConfig.from(sensitivity: 1))
    }

    func testDefaultMatchesHalfSensitivity() {
        XCTAssertEqual(DetectorConfig.default, DetectorConfig.from(sensitivity: 0.5))
    }
}
