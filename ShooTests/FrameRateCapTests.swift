import CoreMedia
import XCTest
@testable import Shoo

final class FrameRateCapTests: XCTestCase {
    /// 12 fps requested on a 15–30 camera must clamp UP to 15 (the floor) — this is the crash
    /// the helper exists to prevent.
    func testBelowFloorClampsUpToMinimum() {
        let result = FrameRateCap.clamp(desiredFPS: 12, into: [(min: 15, max: 30)])
        XCTAssertEqual(result?.fps, 15)
        XCTAssertEqual(result?.duration, CMTime(value: 1, timescale: 15))
    }

    /// PowerCoordinator's thermal/low-power backoff to 6 fps hits the same path; must also clamp.
    func testReducedFPSBelowFloorClampsUp() {
        let result = FrameRateCap.clamp(desiredFPS: 6, into: [(min: 15, max: 30)])
        XCTAssertEqual(result?.fps, 15)
    }

    func testWithinRangeIsUnchanged() {
        let result = FrameRateCap.clamp(desiredFPS: 24, into: [(min: 15, max: 30)])
        XCTAssertEqual(result?.fps, 24)
        XCTAssertEqual(result?.duration, CMTime(value: 1, timescale: 24))
    }

    func testAboveCeilingClampsDownToMaximum() {
        let result = FrameRateCap.clamp(desiredFPS: 60, into: [(min: 15, max: 30)])
        XCTAssertEqual(result?.fps, 30)
        XCTAssertEqual(result?.duration, CMTime(value: 1, timescale: 30))
    }

    func testLowTargetAchievableOnWideRangeCamera() {
        let result = FrameRateCap.clamp(desiredFPS: 12, into: [(min: 1, max: 30)])
        XCTAssertEqual(result?.fps, 12)
        XCTAssertEqual(result?.duration, CMTime(value: 1, timescale: 12))
    }

    /// Non-contiguous ranges: a value in the gap snaps to the nearest range edge.
    func testGapBetweenRangesSnapsToNearestEdge() {
        // Gap is (15, 24); 16 is nearer the lower range's ceiling (15).
        let result = FrameRateCap.clamp(desiredFPS: 16, into: [(min: 5, max: 15), (min: 24, max: 30)])
        XCTAssertEqual(result?.fps, 15)
    }

    func testEmptyRangesReturnsNil() {
        XCTAssertNil(FrameRateCap.clamp(desiredFPS: 12, into: []))
    }

    func testInvalidRangesAreIgnored() {
        // Zero/negative and inverted ranges are dropped; only (15,30) remains.
        let result = FrameRateCap.clamp(desiredFPS: 12, into: [(min: 0, max: 0), (min: 30, max: 15), (min: 15, max: 30)])
        XCTAssertEqual(result?.fps, 15)
    }
}
