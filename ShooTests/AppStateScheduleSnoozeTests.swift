import XCTest
@testable import Shoo

/// Time-driven AppState logic, made deterministic via the injected `now` clock and the
/// MockFrameSource. Covers effectiveState precedence, snooze targets, and schedule boundaries.
@MainActor
final class AppStateScheduleSnoozeTests: XCTestCase {
    private func authorizedState(now: @escaping () -> Date = { Date() }) -> (AppState, MockFrameSource) {
        let mock = MockFrameSource()
        let state = AppState(frameSource: mock, now: now)
        state.permissionProvider = { .authorized }
        state.refreshPermission()  // cameraStatus → .authorized
        return (state, mock)
    }

    // MARK: - effectiveState precedence

    func testEffectiveStateReportsCameraError() {
        let (state, mock) = authorizedState()
        mock.emit(.failed("Boom"))
        XCTAssertEqual(state.effectiveState, .cameraError(reason: "Boom"))
        mock.emit(.interrupted("Camera in use by another app"))
        XCTAssertEqual(state.effectiveState, .cameraError(reason: "Camera in use by another app"))
    }

    func testSnoozeTakesPrecedenceAndShowsSnoozedState() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let (state, _) = authorizedState(now: { base })
        state.isWatching = true

        state.snooze(for: 10)

        XCTAssertEqual(state.effectiveState, .snoozed(until: base.addingTimeInterval(600)))
        XCTAssertEqual(state.snoozeUntil, base.addingTimeInterval(600))
    }

    func testResumeClearsSnooze() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let (state, _) = authorizedState(now: { base })
        state.isWatching = true
        state.snooze(for: 10)

        state.resume()

        // Snooze cleared; no longer in the snoozed state (exact post-state depends on the
        // shared schedule setting, so assert the snooze specifically).
        XCTAssertNil(state.snoozeUntil)
        if case .snoozed = state.effectiveState { XCTFail("should no longer be snoozed") }
    }

    func testSnoozeExpiryRearmsWhenTimerFiresEarly() {
        var current = Date(timeIntervalSince1970: 1_000_000)
        let (state, _) = authorizedState(now: { current })
        state.isWatching = true
        state.snooze(for: 10)
        let until = Date(timeIntervalSince1970: 1_000_000).addingTimeInterval(600)

        // Timer fired marginally early: the snooze must survive (and re-arm), not get stuck.
        state.handleSnoozeExpiry()
        XCTAssertEqual(state.snoozeUntil, until)

        // Past the deadline the same path resumes and clears the snooze.
        current = until.addingTimeInterval(1)
        state.handleSnoozeExpiry()
        XCTAssertNil(state.snoozeUntil)
    }

    // MARK: - Snooze targets

    func testSnoozeUntilTomorrowMorningTargetsNineAM() {
        let calendar = Calendar.current
        let base = Date(timeIntervalSince1970: 1_000_000)
        let (state, _) = authorizedState(now: { base })
        let saved = state.settings.scheduleEnabled
        defer { state.settings.scheduleEnabled = saved }
        state.settings.scheduleEnabled = false  // → 9am fallback

        state.snoozeUntilTomorrowMorning()

        let expected = calendar.date(
            bySettingHour: 9, minute: 0, second: 0,
            of: calendar.date(byAdding: .day, value: 1, to: base)!)
        XCTAssertEqual(state.snoozeUntil, expected)
    }

    // MARK: - Schedule boundary

    func testNextBoundaryDatePicksNextStartOrEnd() {
        let calendar = Calendar.current
        let day = Date(timeIntervalSince1970: 1_000_000)
        let at8am = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
        let (state, _) = authorizedState(now: { at8am })

        // Save & restore so we don't leak into the shared defaults suite.
        let savedEnabled = state.settings.scheduleEnabled
        let savedStart = state.settings.activeStartMinutes
        let savedEnd = state.settings.activeEndMinutes
        defer {
            state.settings.scheduleEnabled = savedEnabled
            state.settings.activeStartMinutes = savedStart
            state.settings.activeEndMinutes = savedEnd
        }

        state.settings.scheduleEnabled = true
        state.settings.activeStartMinutes = 9 * 60   // 09:00
        state.settings.activeEndMinutes = 17 * 60     // 17:00

        // At 08:00 the next boundary is today's 09:00 start.
        let expected = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)
        XCTAssertEqual(state.nextBoundaryDate(), expected)
    }

    func testNextBoundaryDateNilWhenScheduleDisabled() {
        let (state, _) = authorizedState()
        let saved = state.settings.scheduleEnabled
        defer { state.settings.scheduleEnabled = saved }
        state.settings.scheduleEnabled = false
        XCTAssertNil(state.nextBoundaryDate())
    }
}
