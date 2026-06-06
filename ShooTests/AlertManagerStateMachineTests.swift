import XCTest
@testable import Shoo

/// Records `present`/`dismiss` calls so the state-machine tests can assert fire counts and
/// escalation levels without any AppKit.
@MainActor
private final class StubPresenter: AlertPresenting {
    private(set) var presentedLevels: [EscalationLevel] = []
    private(set) var dismissCount = 0

    func present(level: EscalationLevel) { presentedLevels.append(level) }
    func dismiss() { dismissCount += 1 }
}

/// Exercises ``AlertManager``'s transitions with an injected, controllable clock.
@MainActor
final class AlertManagerStateMachineTests: XCTestCase {
    private var now = Date(timeIntervalSinceReferenceDate: 0)
    private var presenter: StubPresenter!
    private var stats: CatchStatsStore!
    private var manager: AlertManager!
    private let cooldown: TimeInterval = 5

    override func setUp() {
        super.setUp()
        now = Date(timeIntervalSinceReferenceDate: 0)
        presenter = StubPresenter()
        let defaults = UserDefaults(suiteName: "AlertManagerStateMachineTests-\(UUID())")!
        stats = CatchStatsStore(defaults: defaults, key: "catchStats", clock: { [unowned self] in self.now })
        manager = AlertManager(presenter: presenter, stats: stats, clock: { [unowned self] in self.now })
    }

    private func feed(_ contact: Bool, count: Int = 1) {
        let result: DetectionResult = contact ? .mouthContact(confidence: 0.9) : .none
        for _ in 0..<count {
            manager.handleDetection(result, cooldown: cooldown)
        }
    }

    private func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    // MARK: - Arming / debounce

    func testRequiresSustainedHitsBeforeFiring() {
        feed(true)
        feed(true)
        XCTAssertTrue(presenter.presentedLevels.isEmpty, "should not fire before threshold")
        feed(true)  // third hit reaches requiredSustainedHits = 3
        XCTAssertEqual(presenter.presentedLevels, [.first])
    }

    func testOneDropoutWithinReleaseFramesDoesNotReset() {
        feed(true)
        feed(true)
        feed(false)  // single dropout; releaseFrames = 2 so arming is preserved
        feed(true)   // resumes; this is the third real hit
        XCTAssertEqual(presenter.presentedLevels, [.first], "a one-frame dropout should not reset the counter")
    }

    func testReleaseFramesMissesFullyResetArming() {
        feed(true)
        feed(true)
        feed(false, count: 2)  // releaseFrames met → reset to idle
        feed(true)
        feed(true)
        XCTAssertTrue(presenter.presentedLevels.isEmpty, "counter should have reset to zero")
        feed(true)
        XCTAssertEqual(presenter.presentedLevels, [.first])
    }

    // MARK: - Cooldown

    func testCooldownSuppressesReFireUntilElapsed() {
        feed(true, count: 3)  // fire #1
        XCTAssertEqual(presenter.presentedLevels.count, 1)

        advance(cooldown - 1)
        feed(true, count: 3)  // still cooling down
        XCTAssertEqual(presenter.presentedLevels.count, 1, "should not re-fire during cooldown")

        advance(2)  // now past cooldown
        feed(true)  // first frame past cooldown re-fires
        XCTAssertEqual(presenter.presentedLevels.count, 2)
    }

    func testTickDrainsElapsedCooldownWithoutFrames() {
        feed(true, count: 3)  // fire → enter cooldown
        XCTAssertEqual(presenter.presentedLevels, [.first])

        // Frames stop (e.g. watching stopped). Before cooldown elapses, tick keeps cooling.
        advance(2)
        manager.tick(now: now)
        guard case .cooldown = manager.state else {
            return XCTFail("should still be cooling down")
        }

        // Once elapsed, tick drains to idle so we don't stay stuck in cooldown.
        advance(cooldown)  // now well past the cooldown deadline
        manager.tick(now: now)
        XCTAssertEqual(manager.state, .idle)
    }

    func testEachFireRecordsExactlyOneCatch() {
        feed(true, count: 3)
        XCTAssertEqual(stats.count(on: now), 1)
        advance(cooldown + 1)
        feed(true)
        XCTAssertEqual(stats.count(on: now), 2)
    }

    // MARK: - Snooze

    func testSnoozeIgnoresFramesUntilExpiryThenResumes() {
        manager.snooze(minutes: 5)
        XCTAssertEqual(presenter.dismissCount, 1, "snooze dismisses any current overlay")
        feed(true, count: 10)
        XCTAssertTrue(presenter.presentedLevels.isEmpty, "frames ignored while snoozed")

        advance(5 * 60 + 1)
        manager.tick()  // expire snooze → idle
        feed(true, count: 3)
        XCTAssertEqual(presenter.presentedLevels, [.first], "resumes firing after snooze expiry")
    }

    // MARK: - Pause

    func testPauseIgnoresFramesUntilResume() {
        manager.pause()
        feed(true, count: 10)
        XCTAssertTrue(presenter.presentedLevels.isEmpty, "frames ignored while paused")

        manager.resume()
        feed(true, count: 3)
        XCTAssertEqual(presenter.presentedLevels, [.first])
    }

    // MARK: - Escalation

    func testEscalatesToPersistentAfterIgnoredCycles() {
        manager.escalationThreshold = 2

        feed(true, count: 3)  // fire #1 (.first), enter cooldown
        XCTAssertEqual(presenter.presentedLevels.last, .first)

        // Keep touching across the cooldown; the next frame past cooldown re-fires.
        advance(cooldown + 1)
        feed(true)  // ignoredCycles = 1, still .first
        XCTAssertEqual(presenter.presentedLevels.last, .first)

        advance(cooldown + 1)
        feed(true)  // ignoredCycles = 2 → .persistent
        XCTAssertEqual(presenter.presentedLevels.last, .persistent)
    }

    func testCleanReleaseResetsEscalation() {
        manager.escalationThreshold = 2

        feed(true, count: 3)              // fire #1
        advance(cooldown + 1)
        feed(true)                        // ignoredCycles = 1
        advance(cooldown + 1)
        feed(true)                        // ignoredCycles = 2 → .persistent
        XCTAssertEqual(presenter.presentedLevels.last, .persistent)

        // A clean release resets escalation back to .first.
        advance(cooldown + 1)
        feed(false, count: 2)             // releaseFrames met → idle, escalation reset
        feed(true, count: 3)              // fresh fire should be .first again
        XCTAssertEqual(presenter.presentedLevels.last, .first)
    }

    // MARK: - Debug fire

    func testDebugFirePresentsFirstLevel() {
        manager.fire()
        XCTAssertEqual(presenter.presentedLevels, [.first])
    }
}
