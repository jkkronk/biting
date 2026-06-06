import XCTest
@testable import Shoo

/// Tests the pure pause-reason reference counting and basic state-machine semantics
/// that drive ``CameraController``'s run-only-when-empty policy — without hardware.
final class CameraSessionStateTests: XCTestCase {
    func testEmptySetIsNotPaused() {
        let set = PauseReasonSet()
        XCTAssertFalse(set.isPaused)
        XCTAssertNil(set.primaryReason)
    }

    func testOverlappingReasonsStayPausedUntilBothClear() {
        var set = PauseReasonSet()
        set.insert(.screenLocked)
        set.insert(.displayAsleep)
        XCTAssertTrue(set.isPaused)

        // Clearing one reason must NOT resume while the other remains.
        set.remove(.screenLocked)
        XCTAssertTrue(set.isPaused, "Should stay paused while display is still asleep")

        // Clearing the last reason resumes.
        set.remove(.displayAsleep)
        XCTAssertFalse(set.isPaused)
    }

    func testRemovingUnknownReasonIsHarmless() {
        var set = PauseReasonSet()
        set.insert(.thermal)
        set.remove(.lowPower)  // never inserted
        XCTAssertTrue(set.isPaused)
        set.remove(.thermal)
        XCTAssertFalse(set.isPaused)
    }

    func testInsertingSameReasonTwiceIsIdempotent() {
        var set = PauseReasonSet()
        set.insert(.systemAsleep)
        set.insert(.systemAsleep)
        set.remove(.systemAsleep)
        XCTAssertFalse(set.isPaused, "Single remove should clear an idempotent insert")
    }

    func testClearRemovesAllReasons() {
        var set = PauseReasonSet()
        set.insert(.screenLocked)
        set.insert(.thermal)
        set.clear()
        XCTAssertFalse(set.isPaused)
    }

    func testStateEquality() {
        XCTAssertEqual(CameraSessionState.running, .running)
        XCTAssertEqual(CameraSessionState.pausedAuto(.thermal), .pausedAuto(.thermal))
        XCTAssertNotEqual(CameraSessionState.pausedAuto(.thermal), .pausedAuto(.lowPower))
        XCTAssertEqual(CameraSessionState.noPermission(.denied), .noPermission(.denied))
        XCTAssertNotEqual(CameraSessionState.noPermission(.denied), .noPermission(.restricted))
        XCTAssertEqual(CameraSessionState.interrupted("x"), .interrupted("x"))
        XCTAssertNotEqual(CameraSessionState.interrupted("x"), .interrupted("y"))
    }

    func testPauseReasonDescriptionsAreNonEmpty() {
        for reason in CameraSessionState.PauseReason.allCases {
            XCTAssertFalse(reason.description.isEmpty)
        }
    }
}
