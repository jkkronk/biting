import XCTest
@testable import Shoo

/// Permission-gating tests using ``MockFrameSource`` and ``AppState``'s injectable
/// permission hooks — no real camera or system prompt involved.
@MainActor
final class AppStatePermissionTests: XCTestCase {
    private func makeState(
        mock: MockFrameSource,
        status: CameraPermission.Status,
        requested: CameraPermission.Status? = nil
    ) -> AppState {
        let state = AppState(frameSource: mock)
        state.permissionProvider = { status }
        if let requested {
            state.permissionRequester = { requested }
        }
        return state
    }

    func testAuthorizedStartsImmediately() async {
        let mock = MockFrameSource()
        let state = makeState(mock: mock, status: .authorized)

        state.isWatching = true
        await state.ensurePermissionThenStart()

        XCTAssertEqual(mock.startCount, 1)
        XCTAssertTrue(state.isWatching)
        XCTAssertEqual(state.cameraStatus, .authorized)
    }

    func testNotDeterminedThenGrantedStarts() async {
        let mock = MockFrameSource()
        let state = makeState(mock: mock, status: .notDetermined, requested: .authorized)

        state.isWatching = true
        await state.ensurePermissionThenStart()

        XCTAssertEqual(mock.startCount, 1)
        XCTAssertTrue(state.isWatching)
        XCTAssertEqual(state.cameraStatus, .authorized)
    }

    func testNotDeterminedThenDeniedDoesNotStart() async {
        let mock = MockFrameSource()
        let state = makeState(mock: mock, status: .notDetermined, requested: .denied)

        state.isWatching = true
        await state.ensurePermissionThenStart()

        XCTAssertEqual(mock.startCount, 0)
        XCTAssertFalse(state.isWatching)
        XCTAssertEqual(state.sessionState, .noPermission(.denied))
    }

    func testDeniedNeverStarts() async {
        let mock = MockFrameSource()
        let state = makeState(mock: mock, status: .denied)

        state.isWatching = true
        await state.ensurePermissionThenStart()

        XCTAssertEqual(mock.startCount, 0)
        XCTAssertFalse(state.isWatching)
        XCTAssertEqual(state.sessionState, .noPermission(.denied))
    }

    func testRestrictedNeverStarts() async {
        let mock = MockFrameSource()
        let state = makeState(mock: mock, status: .restricted)

        state.isWatching = true
        await state.ensurePermissionThenStart()

        XCTAssertEqual(mock.startCount, 0)
        XCTAssertEqual(state.sessionState, .noPermission(.restricted))
    }

    func testRefreshPermissionAutoStartsWhenFlipsToAuthorized() async {
        let mock = MockFrameSource()
        // Start denied: user wants to watch but is blocked.
        let state = makeState(mock: mock, status: .denied)
        state.isWatching = true
        await state.ensurePermissionThenStart()
        XCTAssertEqual(mock.startCount, 0)
        // isWatching got cleared by the denial; user re-toggles intent.
        state.isWatching = true

        // User flips to authorized in System Settings; refresh notices and starts.
        state.permissionProvider = { .authorized }
        state.refreshPermission()

        XCTAssertEqual(mock.startCount, 1)
        XCTAssertEqual(state.cameraStatus, .authorized)
    }

    func testRefreshPermissionDropsWatchingWhenRevoked() async {
        let mock = MockFrameSource()
        let state = makeState(mock: mock, status: .authorized)
        state.isWatching = true
        await state.ensurePermissionThenStart()
        XCTAssertEqual(mock.startCount, 1)

        // Access revoked while running.
        state.permissionProvider = { .denied }
        state.refreshPermission()

        XCTAssertFalse(state.isWatching)
        XCTAssertEqual(state.sessionState, .noPermission(.denied))
    }

    func testFramesFlowThroughMock() {
        let mock = MockFrameSource()
        _ = makeState(mock: mock, status: .authorized)

        var received = 0
        // The pipeline wiring sets onFrame; layer an observer by pushing a frame and
        // asserting the source's callback fires without crashing the detector path.
        let priorOnFrame = mock.onFrame
        mock.onFrame = { buffer, orientation in
            received += 1
            priorOnFrame?(buffer, orientation)
        }
        mock.pushFrame()
        XCTAssertEqual(received, 1)
    }
}
