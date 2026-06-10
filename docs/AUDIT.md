# Shoo — Code Audit (bugs & improvements)

_Read-only audit by a 5-agent review team across Camera/Lifecycle, Detection/Vision, Alerting/Overlay/Windows, App-State/Settings/Onboarding, and Build/CI/Compliance/Tests. Every item references real code that was read. Use this as the working backlog._

**Status legend:** `[ ]` open · `[~]` partial · `[x]` done
**Severity:** P0 Critical · P1 High · P2 Medium · P3 Low/polish

| Priority | Count |
|---|---|
| P0 Critical | 1 |
| P1 High | 5 |
| P2 Medium | 12 |
| P3 Low / polish | ~14 |

> Already fixed (context, not in counts): the AVFoundation frame-rate-range crash (`FrameRateCap.clamp`) and the Settings-window-won't-focus issue (`AppState.presentSettings()` activation dance).

## Resolution status (branch `audit-fixes`)

Worked the plan in `~/.claude/plans` as 10 work packages. Test count 102 → **114**, all green.

**Resolved:**
- **P0** — pixel-buffer lifetime (WP1).
- **All P1** — camera threading (WP2), window-activation by identity (WP3), `watchedGestures` wiring (WP4), time-driven state + clock seam (WP5), CI/docs hardening (WP8).
- **Most P2** — restart robustness, `deviceWasConnected` guard, emit ordering (WP2); overlay re-fire race, overlay-snooze consistency, cooldown auto-expiry, notification auth at launch, overlay position clamp (WP6); schedule-boundary timer, scoped `scheduleOverride`, `effectiveState` for camera errors, `refreshPermission` stops camera (WP5); login-item UX (WP7); README + release-gate (WP8).
- **Several P3 / dead code** — `reach` → `let`, `distanceToBox` rename, `AlertMode` removed (WP9); FPS single-source, thermal-branch collapse, PowerCoordinator `assumeIsolated`→`Task` (WP2); `foregroundWindowObserver` deinit (WP3); make-appicon comment (WP8).
- **Test gaps** — `effectiveState`/`WatchState` precedence, snooze targets, boundary computation (WP5); gesture-mask suppression (WP4); `FrameDownscaler` (WP1); cooldown drain (WP6); mirror invariance (WP10).

**Resolved by plan 07 (`plans/07-post-audit-improvements.md`, branch `plan-07-post-audit`).**
Test count 114 → **132**, all green. Picked up the deferred items plus new findings from the
2026-06 follow-up review:
- New fixes: Settings' "Show onboarding again" bypassed window-identity tracking (could
  revert to `.accessory` with onboarding still visible); silent "configured but no output"
  camera state now emits `.failed`; snooze timer re-arms on a marginally-early fire; dead
  `HandFaceDetector.proximity` removed; sensitivity-driven config rebuilds debounced;
  PowerCoordinator observers removed per-center.
- Deferred items closed: onboarding `finish` double-invocation guard; `AppSettings`
  `@MainActor`; `recognizedPoints(.all)` → per-joint queries; orphan settings
  (`displayDurationSeconds`/`clickToDismiss` got Settings UI, `soundName` documented as
  deliberately UI-less); `coverage.sh` jq/python3 fallback with report-only degradation.
- Test gaps closed: `AlertPresenter` (via `OverlayPresenting`/`SoundPlaying`/
  `NotificationPosting` seams) and `DeviceSelector` (via pure `CameraDescriptor` ranking
  core); snooze early-fire re-arm; two-hands fingertip pooling.

**Still open (intentionally parked):**
- P2: fold `isVideoMirrored` into orientation derivation — invariant is documented + tested
  instead; revisit only if rotated external cameras become a real use case.
- P3: `stop()` device teardown for long idle (trade against resume latency);
  sound-on-mute-during-escalation (current behavior intentional — revisit with user
  feedback); `PauseReason.lowPower` (kept — referenced by tests).
- `nextBoundaryDate()` ignores `activeWeekdays` by design (≤2 no-op timer fires/day;
  `effectiveState` recomputes through the weekday-aware `ActiveSchedule.isActive`).

---

## P0 — Critical

- [ ] **CVPixelBuffer used across queues without retention → use-after-recycle.**
  `Shoo/Camera/CameraController.swift:359-368` (`captureOutput`) → `Shoo/Detection/HandFaceDetector.swift:64-74` (`process`), stored at `:25` (`pendingFrame`), consumed at `:83/:95`.
  `captureOutput` hands the buffer from `CMSampleBufferGetImageBuffer` straight into `detectionQueue.async { ... }` and returns. With `alwaysDiscardsLateVideoFrames = true` and a finite pool, AVFoundation can recycle the backing IOSurface as soon as the delegate returns — Vision then reads a buffer that's being overwritten → garbage detections or crashes under load. Nothing retains the buffer/sample.
  **Fix:** Eliminate the cross-queue hazard — downscale **synchronously on `sessionQueue`** (where the buffer is valid) via the existing `FrameDownscaler` (which already outputs an owned pool buffer) and hand only that owned buffer to `detectionQueue`. Alternative: pass and retain the whole `CMSampleBuffer` (a Swift class) until `runPipeline` finishes.

---

## P1 — High

- [ ] **`sessionWasInterrupted` emits off `sessionQueue`; data race on `onStateChange`.**
  `CameraController.swift:257-263` (and the handler structure `:257-314`). Other AV notifications re-dispatch onto `sessionQueue`, but `sessionWasInterrupted` calls `emit(...)` directly from AVFoundation's delivery thread, which reads `self.onStateChange` (`:346`) — mutated on the main actor (`AppState.swift:384`). Inconsistent threading + benign-but-real race.
  **Fix:** Wrap every `@objc` AV handler body in `sessionQueue.async { [weak self] in … }` so all `emit`/session access shares one serialization domain.

- [ ] **Activation-policy restore is title-string–coupled and has two uncoordinated restore paths.**
  `AppState.swift:133-148` (willClose observer matches `title == "Welcome to Shoo" || title.contains("Settings")`) vs `ShooAppDelegate.swift:52-54` (`finishOnboarding()` unconditionally forces `.accessory`).
  The Settings window title is **localized** (`contains("Settings")` fails on non-English systems), the observer runs for *every* window (object: nil) and could fold in the overlay panel, and closing onboarding while Settings is open can wrongly drop to `.accessory`.
  **Fix:** Track the windows you intentionally opened (weak refs to the onboarding + settings `NSWindow`), match by identity not title, exclude the overlay panel, and route `finishOnboarding`'s restore through the same single guarded check.

- [ ] **`watchedGestures` is a dead setting — never wired into detection.**
  `AppSettings.swift:138-140`, UI at `SettingsView.swift:44-67`; consumed nowhere (`AppState` only pushes `sensitivity`). Unchecking "Nose picking" still fires reminders.
  **Fix:** Thread `watchedGestures` into `DetectorConfig`/`HandFaceDetector` with an `observeWatchedGestures()` sink mirroring `observeSensitivity()` — or hide the toggles until per-gesture classification exists.

- [ ] **`triggersToday` never resets at the date rollover while the app stays open.**
  `AppState.swift:27` + `refreshTriggersToday()` only called at init/on-fire/menu-appear. The "N reminders today" count goes stale across midnight for a long-idle agent (doc comment overstates "resets at the date rollover").
  **Fix:** Observe `.NSCalendarDayChanged` (or a timer to next `startOfDay`) → `refreshTriggersToday()`.

- [ ] **CI "no-drift" check is fragile against XcodeGen/SwiftLint version variance.**
  `.github/workflows/ci.yml:33-46,49` installs unpinned `xcodegen`/`swiftlint`, then fails on any `git diff` of the committed `Shoo.xcodeproj` (`objectVersion = 77`). A Homebrew bump changes pbxproj formatting → spurious red unrelated to `project.yml`. Same risk: an unpinned SwiftLint rule change turns green→red.
  **Fix:** Pin exact XcodeGen + SwiftLint versions in CI and `scripts/bootstrap.sh`; or stop committing `.xcodeproj` (the `.gitignore:20` toggle exists) and generate fresh in CI, dropping the drift check.

---

## P2 — Medium

- [ ] **Restart backoff can latch `.failed` permanently under steady low-rate errors + races `interruptionEnded`.**
  `CameraController.swift:265-276, 317-340`. The window only resets after 30s quiet, so errors every ~5s exhaust `maxRestartAttempts` and emit a terminal `.failed`; a pending backoff `asyncAfter` can also tear down a session just resumed by `interruptionEnded`.
  **Fix:** Reset the window/attempts on each *successful* `startRunning()`; add a monotonic "restart generation" token so stale `asyncAfter` blocks bail.

- [ ] **`deviceWasConnected` tears down a healthy running session for the already-active camera.**
  `CameraController.swift:301-313`. A spurious re-enumeration of the preferred (and currently active) device triggers `tearDownConfiguration()` + rebuild → LED flicker / dropped frames.
  **Fix:** Guard with `device.uniqueID != activeDevice?.uniqueID` before reconfiguring.

- [ ] **`emit` uses independent `Task { @MainActor }` → states can arrive out of order.**
  `CameraController.swift:345-348`. Unstructured Tasks aren't FIFO vs the `sessionQueue` calls that spawned them; rapid `.starting`→`.running` can land reversed, leaving stale UI.
  **Fix:** Emit via a single `DispatchQueue.main.async` (FIFO), or carry a monotonic sequence number and drop stale states in `AppState.apply`.

- [ ] **Front-camera mirroring invariant is load-bearing but undocumented; orientation mapping ignores mirroring.**
  `CameraController.swift:371-389`; geometry at `FaceGeometry.swift:21-51`. Correct *today* (all region math is x-symmetric, FaceTime cam is angle 0 → `.up`), but `isVideoMirrored` is never consulted and the rotated-external-cam branches are untested/likely wrong; a future asymmetric region would break only on mirrored input and pass all (un-mirrored) fixtures.
  **Fix:** Document the mirror-invariance as an explicit invariant in `FaceGeometry`/`ProximityAnalyzer`; add a mirrored-input fixture test (x → 1−x asserts identical `FrameScore`). If rotated cams matter, fold `isVideoMirrored` into the `CGImagePropertyOrientation` derivation.

- [ ] **Overlay fade-out completion can hide an overlay a newer fire just showed.**
  `OverlayController.swift:61-105`. A `dismiss()` fade's completion calls `orderOut(nil)`; if `show()` (escalation re-fire) runs during that ~0.30s, the stale completion hides the freshly re-shown panel.
  **Fix:** Guard the completion with a generation/epoch counter incremented on every `show()`/`dismiss()`; bail if it changed.

- [ ] **Overlay "Snooze" hard-codes 5 min and diverges from menu snooze state.**
  `AppState.swift:88` (`alerts.snooze(minutes: 5)`). It quiets `AlertManager` only — the menu still shows "watching", `snoozeUntil`/auto-resume aren't updated.
  **Fix:** Route overlay snooze through `AppState.snooze(for:)` with a configurable duration so menu state + timer stay consistent.

- [ ] **Schedule boundary transitions don't drive the UI.**
  `AppState.swift:308-358`. `effectiveState` is computed over wall-clock but only re-renders on an `@Published` change; crossing active-hours start/end republishes nothing, so the menu shows stale `.watching`/`.outsideSchedule` until a reopen. (Schedule is advisory only — camera isn't actually gated.)
  **Fix:** Schedule a timer to the next schedule boundary that republishes, mirroring the snooze timer.

- [ ] **`scheduleOverride` ("Watch anyway") is permanent for the whole process lifetime.**
  `AppState.swift:31,315-318`. Once tapped it ignores the schedule for *all* future windows until relaunch, with no way back.
  **Fix:** Clear it at the next schedule boundary (tie into the boundary timer), or offer a "Respect schedule again" affordance.

- [ ] **Login-item toggle can desync; `.requiresApproval` snaps the toggle off.**
  `SettingsView.swift:237-248`, `LaunchAtLogin.swift:46-58`. A redundant second `LaunchAtLogin.state` read (`:246`) discards the authoritative `Result`; `SMAppService.status` lags after `register()`, and the toggle's `get` treats `.requiresApproval` as off — so enabling looks like it failed.
  **Fix:** Trust the `Result` (drop the second read); treat `.requiresApproval` as "on" for the toggle and surface the approval banner; on `.failure` don't overwrite state.

- [ ] **`refreshPermission()` stops watching but leaves the camera session running.**
  `AppState.swift:205-222`. The revoked-permission branch flips `isWatching=false` and hand-sets `sessionState` but never calls `camera.stop()`/`detector.reset()`, so capture state can diverge (LED may stay on).
  **Fix:** Route through `stopWatching()` instead of hand-setting `sessionState`.

- [ ] **`effectiveState` ignores `.failed`/`.interrupted`/`.pausedAuto` → menu dot disagrees with the menu-bar symbol.**
  `AppState.swift:336-358` vs `menuBarSymbolName` `:64-71`. A `.failed(...)` camera shows green/yellow "Watching"/"Paused" in the popover while the bar icon correctly shows a warning triangle.
  **Fix:** Handle `.failed`/`.interrupted` (and optionally `.pausedAuto`) in `effectiveState`.

- [ ] **README is stale vs actual state/toolchain.**
  `README.md:7,13-19,26`. Says "Xcode 15+" but `objectVersion = 77` needs Xcode 16+; still calls detection "stubbed/scaffold" though the full pipeline is wired (`AppState.swift:382-400`); diagram names non-existent `CameraManager`/`OverlayWindow` (now `CameraController`/`OverlayController`).
  **Fix:** Bump to Xcode 16+, refresh status, correct type names.

- [ ] **Release path dead-ends (expected, pre-submission).**
  `project.yml:18` (`DEVELOPMENT_TEAM: ""`), `release.yml`, `Fastfile:44-48`. A `v*.*.*` tag yields only an unsigned archive; `fastlane release` errors by design. Not a code bug — flagged so it isn't mistaken for a working pipeline. Resolve with plan 05 (Team ID + manual CI signing). Consider gating release on `workflow_dispatch` until then.

---

## P3 — Low / polish

- [ ] **`MainActor.assumeIsolated` for ProcessInfo/thermal/screen notifications is a runtime trap** if delivery thread ever changes. `PowerCoordinator.swift:44-73`, `AppState.swift:386`, `OverlayController.swift:48`. Prefer `Task { @MainActor }`/`DispatchQueue.main.async`.
- [ ] **`ProximityAnalyzer.reach` is a mutable `var`** that, if set to 0, makes `score` (`:38`) produce `NaN`/`inf` that latches the gesture. `ProximityAnalyzer.swift:14,20-23`. Make it `let` (set via clamping init) or clamp in `score`.
- [ ] **FPS default duplicated** in `CameraController.targetFPS = 12` (`:38`) and `FrameThrottle(targetFPS: 12)` (`:43`), diverging if one changes. Derive both from one constant.
- [ ] **`AlertManager` cooldown only expires on a live frame; `tick()` doc overpromises.** `AlertManager.swift:93-95,179-204`. Expire `.cooldown`→`.idle` in `expireTimedStates`, or tighten the doc.
- [ ] **Escalation `ignoredCycles` not reset when a snooze expires.** `AlertManager.swift:217-222`. Reset it on snooze→idle so escalation doesn't fire a cycle early after snooze.
- [ ] **`NotificationAlerter.isAuthorized` not refreshed at launch.** `NotificationAlerter.swift:26-44`. A previously-granted permission is ignored until the Settings toggle is touched. Read `center.notificationSettings()` once at launch / in `post()`.
- [ ] **Persistent-escalation force-plays a sound even when sound is muted.** `SoundPlayer.swift:11-20`, `AlertPresenter.swift:51-53`. Confirm intended or gate behind a setting.
- [ ] **`foregroundWindowObserver` never removed in `deinit`** (matters for `#Preview`/test `AppState` instances which each add a process-wide observer). `AppState.swift:56,133-148`. Add `deinit` removal (mirror `OverlayController`).
- [ ] **Onboarding `finish` double-invocation** (`finishAndClose()` then `.onDisappear`). `OnboardingView.swift:30,170-185`. Guard with a `didFinish` flag.
- [ ] **`AppSettings` isn't `@MainActor`** though de-facto main-actor; annotate (or document) to prevent a future background mutation racing the `didSet` UserDefaults writes. `AppSettings.swift:10`.
- [ ] **`stop()` doesn't release the device** (leaves `isConfigured`/input attached) for a long-idle agent. `CameraController.swift:60-68`. Consider `tearDownConfiguration()` on stop (weigh resume cost).
- [ ] **`signedDistanceToBox` is non-negative** (misnomer). `ProximityAnalyzer.swift:79-83`. Rename `distanceToBox`.
- [ ] **Overlay can be pushed off short external displays** (+8% nudge above center). `OverlayController.swift:179-188`. Clamp origin to keep the 180pt panel within `visibleFrame`.
- [ ] **`recognizedPoints(.all)` allocates all joints per frame** then uses ~8. `VisionFrameAnalyzer.swift:93`. Request only the needed groups (negligible at ≤12 fps).
- [ ] **`make-appicon.sh` comment says "10 PNGs"** but 7 unique files map to 10 slots. `make-appicon.sh:8`. Reword; optionally add a CI assertion that each icon PNG matches its declared dimensions.
- [ ] **`coverage.sh` depends on `python3`** (unstated). `scripts/coverage.sh:21`. Fine on `macos-14`; an `awk`/`jq` fallback is more robust.

---

## Dead code / cleanup

- [ ] **`AlertMode` enum is entirely unused** (`SettingsTypes.swift:12-26`) — the boolean toggles are the source of truth. Remove.
- [ ] **`CameraSessionState.PauseReason.lowPower` is never used** (`CameraSessionState.swift:33`) — `PowerCoordinator` only throttles for low-power, never pauses. Wire or remove.
- [ ] **`displayDurationSeconds`, `clickToDismiss`, `soundName` have no Settings UI** (`AppSettings.swift:103,115,125`) — persisted/reset but unreachable. Add controls or document as fixed.
- [ ] **`PowerCoordinator` `.serious`/`.nominal` thermal branches are identical** (`:82-91`) — collapse and let `applyThrottlePolicy` own the FPS decision.

---

## Test coverage gaps

The pure-logic core is strongly covered (ActiveSchedule incl. DST/overnight/boundaries, AppSettings migration/reset, FrameRateCap, GestureDetector hysteresis/EMA, AlertManager arm/cooldown/snooze/pause/escalation, CatchStats midnight bucketing, ProximityAnalyzer, FaceGeometry, DetectorConfig). Gaps:

- [ ] **`AppState.effectiveState` / `WatchState` precedence — untested.** The permission > noCamera > snooze > schedule > watch ordering (`AppState.swift:336-358`) is branchy and drives the whole menu. Add table-driven tests.
- [ ] **AppState snooze logic — untested.** `snooze(for:)`, `snoozeUntilTomorrowMorning()` (9am-fallback math `:267-283`), `resume()`, snooze-timer expiry. Needs an injectable clock seam for the `Timer` at `:293-299`.
- [ ] **`isWithinActiveHours` + `scheduleOverride` composition — untested** (the `ActiveSchedule.isActive` primitive is tested; its use in AppState isn't).
- [ ] **Gesture mask → end-to-end suppression — untested** (and currently not wired; see P1 `watchedGestures`).
- [ ] **`AlertPresenter` and `DeviceSelector`** are partially testable (injectable settings / pure-ish selection) but untested.

UI/AppKit shells (`MenuBarView`, `SettingsView`, `OnboardingView`, `OverlayController`, `CameraController`, `VisionFrameAnalyzer`, `NotificationAlerter`, `SoundPlayer`, `LaunchAtLogin`) are reasonably left to manual testing. Flakiness risk is low (clocks/calendars injected, isolated UserDefaults suites).

---

## Recommended fix order

1. **P0 pixel-buffer lifetime** (stability — do first; the downscale-on-sessionQueue refactor also simplifies threading).
2. **P1 threading + window-activation + dead `watchedGestures` + `triggersToday` rollover** (correctness + a user-visible "setting does nothing").
3. **P1 CI pinning** (cheap; stops future spurious red).
4. **P2 batch** by area: camera lifecycle robustness → schedule/menu state timers → login-item UX → overlay re-fire race.
5. **P3 / dead code / test gaps** as cleanup, ideally each with a covering test (especially `effectiveState` and snooze logic, which need a clock seam).
