# 02 — Camera & Capture Lifecycle

## Context

Shoo is an always-on macOS menu-bar agent (`LSUIElement`, no dock icon, sandboxed, Mac App Store, macOS 14+) that watches the webcam and shows a centered "Stop!" overlay when hands approach the face. All processing is on-device via Apple Vision; nothing leaves the Mac.

This plan owns the **camera and capture lifecycle**: configuring, starting, stopping, and recovering an `AVCaptureSession`; getting the camera-permission flow right; selecting and tracking devices (including Continuity/external cameras and hot-swap); reacting to interruptions and runtime errors; and pausing/resuming around screen lock, display/system sleep, low-power mode, and thermal pressure. It does **not** cover the Vision/detection math (plan 01), the overlay (plan 03), or onboarding UI (plan 04).

The current `CameraManager` (`Shoo/Camera/CameraManager.swift`) is a working skeleton: it configures a single default device, attaches an `AVCaptureVideoDataOutput`, and forwards every `CVPixelBuffer` on a serial queue via `onFrame`. It has several `TODO`s: surfacing device failure, throttling frame rate, and tuning preset. Critically, `AppState.cameraStatus` (`Shoo/App/AppState.swift:14`) is declared and read by the menu UI but **never updated** — `startWatching()` calls `camera.start()` directly without ever requesting permission or writing status back. This plan fixes that.

Relevant existing files (all under `/Users/JonatanMBA/Documents/code/biting`):
- `Shoo/Camera/CameraManager.swift` — session owner; `onFrame` callback; `sessionQueue`.
- `Shoo/Camera/CameraPermission.swift` — `AVCaptureDevice` authorization wrapper (`Status`, `current`, `request()`).
- `Shoo/App/AppState.swift` — `@MainActor` `ObservableObject`; `startWatching`/`stopWatching`/`toggleWatching`; `cameraStatus`; pipeline wiring.
- `Shoo/Views/MenuBarView.swift` — toggle + `statusText` switching on `appState.cameraStatus`.
- `Shoo/Support/AppLogger.swift` — `AppLogger.camera` (`os.Logger`).
- `Shoo/Info.plist` — `NSCameraUsageDescription`, `LSUIElement`.
- `Shoo/Shoo.entitlements` — `com.apple.security.app-sandbox`, `com.apple.security.device.camera`.

## Goals / Definition of done

1. **Robust session lifecycle.** `start()`/`stop()` are idempotent, thread-safe on `sessionQueue`, and never double-configure or leak. Stopping fully ends the capture (camera LED off) within one run loop.
2. **Correct permission flow.** `startWatching()` resolves authorization first: `notDetermined` → prompt; `authorized` → start; `denied`/`restricted` → do not start, surface status, offer deep-link to System Settings. `AppState.cameraStatus` is always kept current (this is the scaffold bug fixed).
3. **Status surfacing.** A single source of truth (`CameraSessionState`) drives `MenuBarView`: distinguishes *watching*, *paused (auto)*, *no permission*, *no device*, *interrupted*, and *error*. The menu text and symbol reflect it.
4. **Device handling.** Sensible default-device selection that prefers a built-in/Continuity camera; graceful handling of zero cameras, device disconnect mid-session, and reconnect; auto re-selection of a working device.
5. **Interruption & error recovery.** Observe `AVCaptureSession.wasInterruptedNotification`, `interruptionEndedNotification`, and `runtimeErrorNotification`; auto-restart with bounded backoff after recoverable errors; surface unrecoverable ones.
6. **Power/lifecycle policy.** Capture is paused on screen lock, display sleep, and system sleep, and resumed on unlock/wake (only if the user still has watching enabled). A defined throttling/pause policy responds to `ProcessInfo.thermalState` and low-power mode.
7. **Capture-side perf config.** Frame rate is capped (~12 fps target) and resolution kept modest (`.medium`/640×480-class), owned here, coordinated with plan 01's budget. `alwaysDiscardsLateVideoFrames = true`.
8. **Privacy.** The session only runs while actively watching; the green camera indicator is on only then. No frames are retained.
9. **Testability.** Frame production is abstracted behind a `FrameSource` protocol so `AppState`/detection/alerting can be driven by a `MockFrameSource` with no real camera.
10. Builds clean; existing 5 tests still pass; new unit tests for the state machine and a mock frame source pass.

## Current state

- `CameraManager` configures once (`isConfigured` guard), uses `AVCaptureDevice.default(for: .video)`, preset `.medium`, `alwaysDiscardsLateVideoFrames = true`, and forwards frames on `sessionQueue`. No frame-rate cap, no error/interruption observers, no device-change observers, no teardown beyond `stopRunning()`, no failure surfacing.
- `CameraPermission` correctly maps `AVAuthorizationStatus` and exposes async `request()`, but nobody calls it — `AppState.startWatching()` skips straight to `camera.start()`.
- `AppState.cameraStatus` is `@Published private(set)` and read by `MenuBarView`, but never written → the menu always shows "Camera permission not yet granted" / stale state.
- No protocol abstraction: `AppState` holds a concrete `CameraManager`, so the camera cannot be mocked in tests.
- No power/lifecycle handling: the session would keep the camera live across screen lock and sleep, contradicting `docs/ARCHITECTURE.md` ("Pause the session when watching is disabled or the display is locked") and the privacy posture.

## Design

### Component overview

```
AppState (@MainActor)
  ├─ owns  CameraController            (was CameraManager; conforms to FrameSource)
  │         ├─ AVCaptureSession on sessionQueue
  │         ├─ DeviceSelector          (picks/ranks AVCaptureDevices)
  │         ├─ SessionObservers        (interruption / runtime-error / device-change)
  │         └─ publishes CameraSessionState  → AppState
  ├─ owns  PowerCoordinator            (screen lock / sleep / thermal / low-power)
  └─ owns  CameraPermission (static)   (unchanged API, now actually called)
```

`AppState` remains the only `@MainActor` orchestrator. `CameraController` does all AVFoundation work on its private `sessionQueue` and reports state changes back to the main actor.

### `FrameSource` protocol (testability)

Introduce a protocol so detection can be exercised without hardware:

```swift
// Shoo/Camera/FrameSource.swift
import CoreVideo

protocol FrameSource: AnyObject {
    /// Delivered for every frame, on the source's delivery queue.
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }
    /// Reports lifecycle/auth/device state transitions, always on the main actor.
    var onStateChange: ((CameraSessionState) -> Void)? { get set }

    func start()   // idempotent: ensures session running if permitted
    func stop()    // idempotent: fully tears down capture
}
```

`CameraController` conforms; `MockFrameSource` (test target) conforms and lets tests push synthetic `CVPixelBuffer`s and synthetic state transitions. `AppState` holds `private let camera: FrameSource`, injected via `init(frameSource:)` (default `CameraController()`).

### `CameraSessionState` (single source of truth)

```swift
// Shoo/Camera/CameraSessionState.swift
enum CameraSessionState: Equatable {
    case idle                       // not watching; session stopped
    case starting                   // permission/config in flight
    case running                    // delivering frames
    case pausedAuto(PauseReason)    // user still wants to watch, but auto-paused
    case noPermission(CameraPermission.Status)  // .denied / .restricted / .notDetermined
    case noDevice                   // no usable camera present
    case interrupted(String)        // AVCaptureSession interruption, human-readable
    case failed(String)             // unrecoverable runtime error

    enum PauseReason: Equatable { case screenLocked, displayAsleep, systemAsleep, thermal, lowPower }
}
```

`AppState` mirrors this into `@Published private(set) var sessionState: CameraSessionState` and derives the existing `cameraStatus` from it (keep `cameraStatus` for the current `MenuBarView` switch, or migrate the view — see Files section). `menuBarSymbolName` and `statusText` are computed from `sessionState`.

### Permission flow (fix the scaffold bug)

`AppState.startWatching()` becomes async-aware:

```swift
func startWatching() {
    isWatching = true
    Task { await ensurePermissionThenStart() }
}

private func ensurePermissionThenStart() async {
    switch CameraPermission.current {
    case .authorized:
        camera.start()
    case .notDetermined:
        let result = await CameraPermission.request()
        cameraStatus = result
        if result == .authorized { camera.start() }
        else { sessionState = .noPermission(result); isWatching = false }
    case .denied, .restricted:
        cameraStatus = CameraPermission.current
        sessionState = .noPermission(CameraPermission.current)
        isWatching = false   // can't watch without permission
    }
}
```

- On `denied`/`restricted`, `MenuBarView` shows the message and a **"Open System Settings"** button that deep-links to the Camera privacy pane:
  `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)`.
  (This URL is the macOS 13+ scheme; validate at implementation time and keep a fallback to `…?Privacy_Camera` without the leading pane id.)
- `CameraPermission` gains a convenience `static func openSystemSettings()` wrapping that call so the URL lives in one place.
- Re-check `CameraPermission.current` when the menu/popover appears (`MenuBarExtra` content `onAppear`) and when the app becomes active, because the user may have changed the setting in System Settings while the app ran. If it flips to `authorized` and `isWatching` is desired, auto-start.

### Device selection

Replace `AVCaptureDevice.default(for: .video)` with an explicit `AVCaptureDevice.DiscoverySession` so we can rank and react to changes:

```swift
let discovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
    mediaType: .video,
    position: .unspecified)
```

Notes:
- `.continuityCamera` and `.deskViewCamera` exist on macOS 14+. `.external` covers generic USB webcams. Guard types that may be unavailable with `#available` / availability of the enum case; on older toolchains fall back to `.builtInWideAngleCamera` + `.external`.
- **Ranking:** prefer (1) a remembered device if its `uniqueID` is still present, else (2) the system default (`AVCaptureDevice.default(for: .video)`) if it is in the discovery list, else (3) the first built-in, else (4) the first available. Skip `.deskViewCamera` for our use (it's the overhead-desk view, wrong framing) unless it is the only device.
- Persist the chosen device `uniqueID` in `UserDefaults` (key `"cameraDeviceID"`) so selection is stable across launches. Device picking UI is plan 04; this plan just respects a stored ID if present.
- If discovery returns zero devices → emit `.noDevice` (do not crash; the scaffold's `guard` silently committed an empty config — replace that).

### Device hot-swap / disconnect

Observe these on `NotificationCenter.default`:
- `AVCaptureDevice.wasDisconnectedNotification` — if the disconnected device is the active input, stop the session, reconfigure with the next-best device (or `.noDevice`), and restart on `sessionQueue`.
- `AVCaptureDevice.wasConnectedNotification` — if currently `.noDevice` (or the newly connected device is the user's remembered preferred one), reconfigure to use it.
- The session also posts `runtimeErrorNotification` when an input goes away; treat that path too (see below). Always mutate the session inside `beginConfiguration()`/`commitConfiguration()` on `sessionQueue`.

### Session interruptions & runtime errors

Register on `sessionQueue` (observers fire on an arbitrary thread; hop to `sessionQueue` for session mutation, to main for state):

- `AVCaptureSession.wasInterruptedNotification` → read `userInfo[AVCaptureSessionInterruptionReasonKey]` (`AVCaptureSession.InterruptionReason`); emit `.interrupted(reason)`. On macOS the common reason is `videoDeviceNotAvailableInBackground` / hardware contention; do **not** force-restart while interrupted.
- `AVCaptureSession.interruptionEndedNotification` → if the user still wants to watch and no other pause is active, `startRunning()` again and emit `.running`.
- `AVCaptureSession.runtimeErrorNotification` → read `userInfo[AVCaptureSessionErrorKey]` as `AVError`. For `.mediaServicesWereReset` and transient errors, attempt **bounded auto-restart**: stop, wait with exponential backoff (e.g. 0.5s, 1s, 2s, capped, max 4 attempts within a rolling window), reconfigure, `startRunning()`. If retries exhausted → emit `.failed(message)` and stop trying until the user toggles off/on.

### Power / lifecycle policy (`PowerCoordinator`)

A `@MainActor` helper that registers observers and tells `CameraController` to pause/resume. "Pause" means `session.stopRunning()` (camera LED off, true power/privacy savings) while remembering the user's intent (`isWatching` stays true so we resume).

Observers:
- **Screen lock/unlock:** `DistributedNotificationCenter.default()` names `"com.apple.screenIsLocked"` / `"com.apple.screenIsUnlocked"`. (These are allowed for sandboxed apps as read-only distributed notifications.) Lock → `pause(.screenLocked)`; unlock → `resume(.screenLocked)`.
- **Display sleep/wake:** `NSWorkspace.shared.notificationCenter` `screensDidSleepNotification` / `screensDidWakeNotification` → `.displayAsleep`.
- **System sleep/wake:** `NSWorkspace.shared.notificationCenter` `willSleepNotification` / `didWakeNotification` → `.systemAsleep`. Pause on will-sleep so we cleanly release the camera before suspend.
- **Thermal:** `ProcessInfo.thermalStateDidChangeNotification`. Policy: `.nominal`/`.fair` → normal; `.serious` → drop frame cap to ~6 fps (see throttle hook below); `.critical` → `pause(.thermal)`. Resume when it returns to `.fair`/`.nominal`.
- **Low-power mode:** `Process​Info.processInfo.isLowPowerModeEnabled` + `NSNotification.Name.NSProcessInfoPowerStateDidChange`. Policy: in low-power mode, halve the frame cap (~6 fps). (Do not hard-pause on low-power alone; only thermal-critical/lock/sleep pause.)

Pause/resume is reference-counted by reason so overlapping causes (e.g. locked *and* display asleep) don't prematurely resume: keep a `Set<PauseReason>`; the session runs only when the set is empty **and** `isWatching` **and** authorized.

### Frame-rate cap & format (capture-side perf)

Owned here; coordinate the target with plan 01.
- Set `videoOutput.alwaysDiscardsLateVideoFrames = true` (already present).
- Cap FPS by setting `AVCaptureConnection` / device `activeVideoMinFrameDuration`/`activeVideoMaxFrameDuration` (e.g. `CMTime(value: 1, timescale: 12)`), applied via `device.lockForConfiguration()` after choosing an `activeFormat`, or via the connection. Expose a `var targetFPS: Int` on `CameraController` so `PowerCoordinator` can lower it (12 → 6) under thermal/low-power pressure without a full reconfigure.
- Keep preset `.medium` (≈480p) — enough for face+hand Vision at arm's length; avoids needless CPU/GPU/bandwidth. Leave room for plan 01 to request a specific format if its budget needs it.
- Set `videoOutput.videoSettings` pixel format to a Vision-friendly type (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`) to avoid an extra conversion; confirm with plan 01.

### Teardown correctness

`stop()` on `sessionQueue`: if running, `stopRunning()`. Keep inputs/outputs configured so a later `start()` is fast, but ensure the camera indicator turns off (it does once `isRunning == false`). On full app quit / deinit, remove all notification observers and nil the delegate. Add an explicit `tearDown()` that removes inputs/outputs for the disconnect/reconfigure path.

## Implementation steps

1. **Introduce abstractions.**
   - Add `Shoo/Camera/FrameSource.swift` (protocol above).
   - Add `Shoo/Camera/CameraSessionState.swift` (enum above).
2. **Rename/expand `CameraManager` → `CameraController`.** Keep file at `Shoo/Camera/CameraManager.swift` or rename to `CameraController.swift` (update `project.yml` not needed — sources are globbed by directory). Conform to `FrameSource`; add `onStateChange`; keep `onFrame`. Make `start()`/`stop()` idempotent (they already guard on `isRunning`/`isConfigured`; preserve that).
3. **Device selection.** Add a `DeviceSelector` (small struct/enum, can live in `CameraController.swift` or `Shoo/Camera/DeviceSelector.swift`) building the `DiscoverySession`, applying the ranking, honoring stored `cameraDeviceID`. Replace the scaffold's `AVCaptureDevice.default(for:.video)` block; emit `.noDevice` instead of silently committing an empty session.
4. **Configure format & FPS.** In `configure()`, after adding input, set pixel format and apply `targetFPS` frame-duration cap via `lockForConfiguration()`. Add `func setTargetFPS(_:)` that re-applies under `sessionQueue`.
5. **Session observers.** Add a `registerSessionObservers()` called once after `configure()`: `wasInterruptedNotification`, `interruptionEndedNotification`, `runtimeErrorNotification` (scoped to `object: session`). Implement the recovery/backoff logic and state emission.
6. **Device observers.** Register `AVCaptureDevice.wasDisconnectedNotification` / `wasConnectedNotification`; implement reconfigure-on-`sessionQueue`.
7. **Permission flow in `AppState`.** Rewrite `startWatching()` to the async `ensurePermissionThenStart()` shown above; keep `stopWatching()`/`toggleWatching()`. Wire `camera.onStateChange = { [weak self] state in MainActor.assumeIsolated { self?.apply(state) } }` (or `Task { @MainActor }`) to update `sessionState` + derive `cameraStatus`.
8. **Re-check permission on appear/active.** In `MenuBarView` add `.onAppear { appState.refreshPermission() }`; in `AppState` add `refreshPermission()` that re-reads `CameraPermission.current`, updates state, and auto-starts if appropriate. Optionally observe `NSApplication.didBecomeActiveNotification`.
9. **System Settings deep link.** Add `CameraPermission.openSystemSettings()`; add an "Open System Settings" `Button` in `MenuBarView`, shown only for `.denied`/`.restricted`.
10. **`PowerCoordinator`.** Add `Shoo/Camera/PowerCoordinator.swift` (`@MainActor`). Register lock/sleep/thermal/low-power observers; expose `onPause/onResume(PauseReason)` callbacks (or hold a weak ref to `CameraController`). `AppState` owns it and connects it to `camera`. Implement the `Set<PauseReason>` reference counting and the run-only-when-empty rule. Hook thermal/low-power to `camera.setTargetFPS`.
11. **Wire into `AppState`.** Replace `private let camera = CameraManager()` with injected `FrameSource`; instantiate `PowerCoordinator`; keep `wirePipeline()` (frames → detector) intact since `onFrame` still exists.
12. **Logging.** Use `AppLogger.camera` at `.info` for lifecycle transitions, `.error` for failures, `.notice` for auto-pause/resume. No frame contents ever logged.
13. **Update `MenuBarView`.** Drive `statusText`/symbol from `sessionState` (add the new cases). Keep backward-compatible `cameraStatus` mapping if not migrating the view fully.

## Files to create / modify

**Create**
- `Shoo/Camera/FrameSource.swift` — `FrameSource` protocol.
- `Shoo/Camera/CameraSessionState.swift` — `CameraSessionState` enum + `PauseReason`.
- `Shoo/Camera/PowerCoordinator.swift` — `@MainActor` lock/sleep/thermal/low-power coordinator.
- `Shoo/Camera/DeviceSelector.swift` — discovery + ranking (optional; may inline into controller).
- `ShooTests/MockFrameSource.swift` — test double conforming to `FrameSource`.
- `ShooTests/CameraSessionStateTests.swift` — state-machine + pause-reason ref-counting tests.
- `ShooTests/AppStatePermissionTests.swift` — permission-gating tests using `MockFrameSource` and an injectable permission status.

**Modify**
- `Shoo/Camera/CameraManager.swift` — expand to `CameraController`: `FrameSource` conformance, `onStateChange`, device selection, FPS cap, format, observers, recovery, teardown. (Rename file to `CameraController.swift` is optional; directory-globbed by XcodeGen so no `project.yml` change.)
- `Shoo/Camera/CameraPermission.swift` — add `openSystemSettings()`; optionally an injectable status hook for tests.
- `Shoo/App/AppState.swift` — async permission gating, `sessionState`, inject `FrameSource`, own `PowerCoordinator`, `refreshPermission()`; keep existing pipeline wiring.
- `Shoo/Views/MenuBarView.swift` — status/symbol from `sessionState`; conditional "Open System Settings" button; `.onAppear` permission refresh.
- `Shoo/App/ShooApp.swift` — no change expected (still constructs `AppState()`); verify the default `FrameSource` is created.

**No change**
- `Shoo/Info.plist`, `Shoo/Shoo.entitlements` (camera + sandbox already correct; distributed-notification observation for screen-lock works under sandbox as read-only and needs no new entitlement — verify during implementation).
- `Shoo/Detection/*`, `Shoo/Alerting/*` (plans 01/03).

## Edge cases & risks

- **Scaffold bug:** `AppState.cameraStatus` never updated — fixed by the permission flow + `onStateChange`. This is the highest-value fix.
- **Empty/headless config:** scaffold silently `commitConfiguration()` with no input on device failure → must become `.noDevice`, not a half-configured session.
- **Permission changed externally:** user grants/revokes in System Settings while running → re-check on appear/active and on `MenuBarExtra` open.
- **`notDetermined` first run:** the system prompt appears only on `requestAccess`; ensure we call it exactly once and don't spam.
- **Continuity Camera availability:** `.continuityCamera`/`.deskViewCamera` may be absent on some hardware/macOS builds; guard enum cases and fall back. Continuity cameras connect/disconnect frequently (phone walks away) → must be handled by the disconnect/reconnect path without entering `.failed`.
- **Interruption vs. error confusion:** another app grabbing the camera posts an interruption (recover on `interruptionEnded`), not a runtime error — don't force-restart while interrupted, or you'll thrash.
- **Restart thrash:** unbounded auto-restart on `runtimeError` can hammer the device; enforce backoff + max-attempts window.
- **Overlapping pause reasons:** lock + display-sleep simultaneously; the `Set<PauseReason>` ref-count avoids premature resume.
- **System sleep race:** must release the camera on `willSleep` before suspend; resuming on `didWake` should reconfigure if the device tree changed during sleep.
- **Sandbox + distributed notifications:** `com.apple.screenIsLocked` is observable read-only under the sandbox, but confirm on a signed, sandboxed build (some distributed notifications are filtered). Fallback: rely on display-sleep + system-sleep notifications, which are not sandbox-restricted.
- **Thread-safety:** all session mutation strictly on `sessionQueue`; all `sessionState` writes on `@MainActor`; notification handlers must hop correctly. Avoid retain cycles via `[weak self]` and remove observers in `deinit`.
- **Privacy regression risk:** any path that leaves `startRunning()` active while paused would keep the green LED on — assert "session runs iff (watching && authorized && no pause reasons)".
- **App Store review:** `NSCameraUsageDescription` already present and accurate; ensure no analytics, matching `docs/PRIVACY.md`.

## Testing & verification

**Unit (XCTest, no hardware):**
- `CameraSessionStateTests`: pause/resume ref-counting (add `.screenLocked` then `.displayAsleep`; ensure stays paused until both clear); state transitions for permission denial, no-device, interruption, failure.
- `AppStatePermissionTests` (with `MockFrameSource` + injectable permission): `notDetermined→granted` starts; `notDetermined→denied` does not start and sets `.noPermission`; `denied` never starts; `authorized` starts immediately; `refreshPermission()` auto-starts when flips to authorized and `isWatching` desired.
- `MockFrameSource`: tests can push synthetic `CVPixelBuffer`s through `onFrame` to drive detection/alerting (consumed by plans 01/03/06).
- Verify existing `ProximityAnalyzerTests` (5 tests) still pass.

**Manual / device verification:**
- Toggle watch on/off; confirm green camera indicator on only while running; off within ~1s of stop/pause.
- First-run permission prompt appears once; deny → menu shows message + working "Open System Settings" deep link; grant later → auto-resumes.
- Lock screen / start screensaver → indicator off; unlock → on. Sleep display, then system; wake → resumes.
- Unplug/replug an external/Continuity camera mid-session → recovers to a working device or `.noDevice` then back.
- Open Photo Booth (grabs camera) → `.interrupted`; close it → resumes.
- Induce thermal pressure (or simulate via `ProcessInfo` override hook) and low-power mode → FPS drops; thermal-critical → pause.
- Instruments / Activity Monitor: confirm CPU is modest at the 12 fps cap and zero when paused.

**Static:** `swiftlint` clean (`.swiftlint.yml`); `xcodegen generate` still succeeds; project builds for the `Shoo` scheme.

## Dependencies & sequencing

- **Plan 01 (detection-engine):** consumes `onFrame` `CVPixelBuffer`s and the chosen pixel format/FPS. Coordinate the perf budget (target FPS, resolution, pixel-format) — capture-side config is owned here, the budget is shared. The `FrameSource`/`MockFrameSource` introduced here unblocks plan 01's testing. **Loose coupling; can proceed in parallel** once `FrameSource` lands.
- **Plan 03 (alerting-overlay):** independent; reuses `MockFrameSource` for end-to-end tests. No direct dependency.
- **Plan 04 (settings-onboarding):** will add a camera-picker UI and an onboarding/permission-priming screen. This plan exposes the stored `cameraDeviceID` and `CameraPermission.openSystemSettings()` that plan 04 builds on. The "Open System Settings" button here is a minimal stopgap; plan 04 may relocate it into onboarding. **Plan 02 should land first** so plan 04 has a real state machine to drive.
- **Plan 05 (appstore-distribution):** depends on the camera entitlement/usage string (already present) and on the privacy posture being honored (session-only-when-watching). No code coupling; verify before submission.
- **Plan 06 (testing-ci):** consumes `MockFrameSource` and the new unit tests; ensures they run headless in CI. This plan provides the mock; plan 06 wires CI.

**Suggested order:** land `FrameSource` + `CameraSessionState` + the `AppState` permission fix first (small, unblocks 01/03/06), then device selection + observers + `PowerCoordinator`.

## Out of scope

- The Vision/detection math, request configuration, frame downscaling for Vision, and the proximity decision (**plan 01**).
- The overlay window/view and alert debounce/cooldown (**plan 03**).
- Settings UI, camera-picker UI, onboarding/permission-priming screens, launch-at-login (**plan 04**) — except exposing the hooks they need.
- App Store packaging, signing, notarization, privacy questionnaire (**plan 05**).
- CI pipeline setup (**plan 06**).
- Audio capture, recording, screenshots, or any persistence of frames (explicitly never — see `docs/PRIVACY.md`).
- Multi-camera simultaneous capture (`AVCaptureMultiCamSession`) — single camera only.
