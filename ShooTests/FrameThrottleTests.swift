import XCTest
@testable import Shoo

/// The fps gate admits at most `targetFPS` frames/sec and drops the rest, using an
/// injected clock for determinism.
final class FrameThrottleTests: XCTestCase {
    func testAdmitsFirstFrame() {
        let throttle = FrameThrottle(targetFPS: 12)
        XCTAssertTrue(throttle.shouldProcess(now: 100.0))
    }

    func testDropsFramesWithinInterval() {
        let throttle = FrameThrottle(targetFPS: 10)  // 0.1s interval
        XCTAssertTrue(throttle.shouldProcess(now: 0.0))
        XCTAssertFalse(throttle.shouldProcess(now: 0.05))  // too soon
        XCTAssertFalse(throttle.shouldProcess(now: 0.099))
        XCTAssertTrue(throttle.shouldProcess(now: 0.10))   // exactly at interval
        XCTAssertFalse(throttle.shouldProcess(now: 0.15))
        XCTAssertTrue(throttle.shouldProcess(now: 0.20))
    }

    func testAcceptedRateNeverExceedsTarget() {
        let throttle = FrameThrottle(targetFPS: 12)
        var accepted = 0
        // Simulate 60 fps delivery over 1 second.
        for i in 0..<60 where throttle.shouldProcess(now: Double(i) / 60.0) {
            accepted += 1
        }
        XCTAssertLessThanOrEqual(accepted, 13)  // ≤ 12 fps (+1 for the boundary frame)
        XCTAssertGreaterThanOrEqual(accepted, 11)
    }

    func testSetTargetFPSChangesInterval() {
        let throttle = FrameThrottle(targetFPS: 30)
        XCTAssertTrue(throttle.shouldProcess(now: 0.0))
        XCTAssertTrue(throttle.shouldProcess(now: 0.034))  // ~30 fps spacing ok
        throttle.setTargetFPS(2)  // 0.5s interval
        XCTAssertFalse(throttle.shouldProcess(now: 0.10))
        XCTAssertTrue(throttle.shouldProcess(now: 0.55))
    }
}
