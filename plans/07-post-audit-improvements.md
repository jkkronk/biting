# 07 — Post-Audit Fixes & Polish

## Context

Plans 01–06 are implemented and the `docs/AUDIT.md` backlog was worked as ten work
packages (114 tests, all green). A follow-up review (2026-06-09) re-verified the audit
fixes — the threading, generation-token, and overlay-epoch work all holds — and found a
small set of **new** issues, plus the audit's own "Still open (deferred)" list that was
parked rather than resolved.

This plan collects both into one final cleanup pass: four correctness fixes, the
deferred audit items worth doing, dead-code/style cleanup, and the remaining test-coverage
gaps. Everything here is small and independent; the plan exists so the work lands
coherently (with tests and an AUDIT.md status update) instead of as drive-by edits.

## Findings being addressed

New (review of 2026-06-09):

| # | Where | What | Severity |
|---|-------|------|----------|
| N1 | `Shoo/Views/SettingsView.swift:150-155` | "Show onboarding again" flips activation policy and opens the window manually, bypassing `AppState.enterForegroundWindow` — the onboarding window is never added to `trackedForegroundWindows`, so closing Settings while onboarding is open reverts the app to `.accessory` with onboarding still on screen (the exact bug WP3 fixed elsewhere) | bug |
| N2 | `Shoo/Camera/CameraController.swift:200-203` | If `canAddOutput` is false on *first* configure, the session is still marked `isConfigured` and emits `.running`: LED on, zero frames, no error. (The silent skip is load-bearing on *re*configure, where the output is still attached.) | bug (unlikely path) |
| N3 | `Shoo/App/AppState.swift:362-365` | `handleSnoozeExpiry()` bails when the one-shot timer fires marginally early (`until > now()`) and never re-arms, leaving `snoozeUntil`/`snoozeTimer` stale. Cosmetic (`effectiveState` re-checks the date; `AlertManager` self-expires) but easy to harden | improvement |
| N4 | `Shoo/Detection/HandFaceDetector.swift:16` | `private let proximity = ProximityAnalyzer()` is dead — `proximityScorer` is the real one | dead code |
| N5 | `Shoo/App/AppState.swift:542-550` | Sensitivity slider rebuilds the detector config on every drag tick | polish |
| N6 | `Shoo/App/AppState.swift:506` | `snoozeTimer` declared mid-file, far from its sibling properties at `:69-71` | style |
| N7 | `Shoo/Camera/PowerCoordinator.swift:101-110` | `deinit` removes every observer token from all three notification centers; harmless no-op for the wrong centers, but sloppy | style |
| N8 | `Shoo/App/AppState.swift:400-412` | `nextBoundaryDate()` ignores `activeWeekdays`, so the boundary timer also fires on inactive days. Harmless — `effectiveState` recomputes via `ActiveSchedule.isActive` — just spurious wakeups (≤2/day) | accepted, document |

Deferred from `docs/AUDIT.md` ("Still open"), picked up here:

| # | Where | What |
|---|-------|------|
| D1 | `Shoo/Views/OnboardingView.swift:30,170-185` | `finish` runs twice per close (`finishAndClose()` then `.onDisappear`), double-invoking `onOnboardingFinished` — guard with a flag |
| D2 | `Shoo/Models/AppSettings.swift:10` | Annotate `@MainActor` (de-facto main-actor today; prevents a future background mutation racing the `didSet` UserDefaults writes) |
| D3 | `AppSettings.swift:103,115,125` | Orphan settings with no UI: `displayDurationSeconds`, `clickToDismiss`, `soundName` — all three **are** consumed live by `AlertPresenter.present()` (`AlertPresenter.swift:51-58`), they're just unreachable. Decide & wire (see Design) |
| D4 | `Shoo/Detection/VisionFrameAnalyzer.swift:93` | `recognizedPoints(.all)` allocates all 21 joints per frame, ~8 used — request only the needed joint groups |
| D5 | `scripts/coverage.sh:21` | Depends on `python3`; add a `jq`/`awk` fallback |
| T1 | `ShooTests/` | `AlertPresenter` untested (fully injectable via `init(settings:overlay:sound:notifications:)`) |
| T2 | `ShooTests/` | `DeviceSelector` untested |
| T3 | `ShooTests/` | No multi-hand fixture: `VisionFrameAnalyzer` requests up to 2 hands and the scorer flattens all fingertips, but no test exercises two hands at once |

Deferred items **not** picked up (stay parked — see Out of scope): folding
`isVideoMirrored` into orientation derivation, `stop()` device teardown for long idle,
the sound-on-mute-during-escalation decision, `PauseReason.lowPower`.

## Goals / Definition of done

- All four correctness items (N1, N2, N3, D1) fixed, each with a covering test where a
  seam exists (N3 and D1 are testable today; N1/N2 are AppKit/AVFoundation shells —
  manual verification, documented below).
- Orphan settings resolved per the Design decision: UI for `displayDurationSeconds` and
  `clickToDismiss`; `soundName` documented as fixed (no UI until there is >1 sound).
- Dead code and style items (N4, N6, N7, D4) cleaned up; `AppSettings` is `@MainActor` (D2).
- Sensitivity changes debounced (N5); schedule-timer behavior documented (N8).
- `coverage.sh` no longer hard-requires `python3` (D5).
- New tests: `AlertPresenterTests`, `DeviceSelectorTests`, snooze-expiry re-arm, a
  two-hands fixture case. Suite stays green.
- `docs/AUDIT.md` resolution status updated so the deferred list reflects reality.

Done = `make ci` green, the manual checks in *Testing & verification* pass, and
AUDIT.md's "Still open" section only lists the intentionally-parked items.

## Design

### N1 — route "Show onboarding again" through `presentOnboarding()`

The button body becomes exactly:

```swift
Button("Show onboarding again") {
    settings.hasOnboarded = false
    appState.presentOnboarding()
}
```

`presentOnboarding()` already does the `.regular` flip, `openWindow`, activation, and —
critically — adds the key window to `trackedForegroundWindows` so the close-observer
reverts the activation policy only when *no* tracked window remains visible. No new code.

### N2 — fail loudly when the video output can't be attached

In `configure()`, the skip is only legitimate when the output is *already* attached
(reconfigure path — `tearDownConfiguration()` removes inputs but deliberately keeps the
output). Make that the explicit condition:

```swift
if session.canAddOutput(videoOutput) {
    videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    session.addOutput(videoOutput)
} else if !session.outputs.contains(videoOutput) {
    AppLogger.camera.error("Cannot attach video output for \(device.localizedName, privacy: .public)")
    session.commitConfiguration()
    emit(.failed("Camera doesn't support video capture"))
    return   // leaves isConfigured == false, like the input-failure path
}
```

`.failed` (not `.noDevice`) because a device exists but is unusable; `effectiveState`
already maps `.failed` to `.cameraError` and the menu-bar icon to the warning triangle.

### N3 — re-arm instead of bailing on an early snooze-timer fire

```swift
private func handleSnoozeExpiry() {
    guard let until = snoozeUntil else { return }
    if until <= now() {
        resume()
    } else {
        scheduleSnoozeTimer(until: until)   // fired early — re-arm to the real deadline
    }
}
```

Testable through the existing injectable clock: construct `AppState` with a controlled
`now`, snooze, invoke `handleSnoozeExpiry()` with the clock still before `until`, and
assert the snooze survives and a timer is re-armed (expose the check via the already-test-
visible state rather than the private timer — assert `snoozeUntil` unchanged and that a
subsequent expiry-with-clock-advanced resumes). Make `handleSnoozeExpiry` `internal` (it
is currently `private`) mirroring `ensurePermissionThenStart`'s test-visibility pattern.

### D1 — onboarding finish guard

`finish(markOnboarded:startIfPossible:)` runs from both `finishAndClose()` and
`.onDisappear`, double-firing `onOnboardingFinished`. Add a flag:

```swift
@State private var didFinish = false

private func finish(markOnboarded: Bool, startIfPossible: Bool) {
    guard !didFinish else { return }
    didFinish = true
    …
}
```

`.onDisappear` keeps its call (covers the user closing the window early); the guard makes
the pair idempotent.

### D3 — orphan settings: wire two, document one

All three are read live by `AlertPresenter.present()`, so the only gap is UI:

- **`displayDurationSeconds`** → `Stepper("Show reminder for: N s", in: 1...10)` in the
  Settings *Timing* section, alongside cooldown.
- **`clickToDismiss`** → `Toggle("Click overlay to dismiss")` in *How you're reminded*.
- **`soundName`** → keep fixed. There is exactly one shipped sound; a picker with one
  entry is noise. Add a doc comment on the property: "persisted for forward-compat;
  no UI until there is more than one sound."

### D2 — `@MainActor` on `AppSettings`

Annotate the class. Call sites are already main-actor (`AppState`, the SwiftUI views,
`AlertPresenter`). The one ripple is tests: `AppSettingsMigrationTests` (and any test
constructing `AppSettings`) must be `@MainActor` — a mechanical annotation.

### N5 — debounce sensitivity

```swift
settings.$sensitivity
    .removeDuplicates()
    .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
    .sink { … }
```

Slider-only; `watchedGestures` toggles are discrete events and stay un-debounced.

### N7 — per-center observer removal in `PowerCoordinator`

Store `(center, token)` pairs instead of bare tokens:

```swift
private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
…
deinit { for (center, token) in observers { center.removeObserver(token) } }
```

(`DistributedNotificationCenter` is an `NotificationCenter` subclass, so one array works.)

### D4 — request only needed hand-joint groups

`VisionFrameAnalyzer` uses the four fingertips + thumb tip. Replace
`recognizedPoints(.all)` with per-group calls (`.thumb`, `.indexFinger`, `.middleFinger`,
`.ringFinger`, `.littleFinger`) or `recognizedPoint(_:)` for the five tip joints,
preserving the existing confidence filtering. Behavior-identical; assert via the existing
`HandFaceDetectorTests` fixtures staying green.

### D5 — coverage.sh fallback

Prefer `jq` when present, fall back to the current `python3` one-liner, and degrade to
report-only (skip the floor gate, with a warning) when neither exists. CI (`macos-14`)
has both, so the gate never silently weakens there.

### N8 — document, don't change

A weekday-aware `nextBoundaryDate()` buys at most two avoided no-op timer fires per day
at the cost of real calendar complexity (per-weekday iteration, overnight windows). The
current daily cadence is *correct* — `effectiveState` always recomputes through
`ActiveSchedule.isActive`, which is weekday-aware. Add one comment line on
`nextBoundaryDate()` stating the timer may fire on inactive days by design.

## Implementation steps

Grouped so each lands as one reviewable commit; order is dependency-free except step 1
before step 6 (tests touch the same files).

1. **Correctness (N1, N2, N3, D1).**
   1. `SettingsView.swift` — replace the manual activation dance with `appState.presentOnboarding()`.
   2. `CameraController.swift` — explicit output-attach failure path emitting `.failed`.
   3. `AppState.swift` — `handleSnoozeExpiry()` re-arm; widen to `internal` for tests.
   4. `OnboardingView.swift` — `didFinish` guard.
2. **Settings UI (D3).** Add the display-duration stepper and click-to-dismiss toggle to
   `SettingsView`; doc-comment `soundName` in `AppSettings`.
3. **Cleanup (N4, N6, N7, D2, D4, N8).** Delete the dead `proximity` property; move the
   `snoozeTimer` declaration up beside `scheduleTimer`; per-center observer removal;
   `@MainActor` on `AppSettings` (+ test annotations); joint-group narrowing in
   `VisionFrameAnalyzer`; `nextBoundaryDate()` comment.
4. **Debounce (N5).** Add the 150 ms debounce to `observeSensitivity()`.
5. **Scripts (D5).** `coverage.sh` jq → python3 → warn-and-skip fallback chain.
6. **Tests (T1, T2, T3 + new behavior).**
   1. `ShooTests/AlertPresenterTests.swift` — stub `OverlayController`-API-shaped spy?
      No: `AlertPresenter` takes concrete `OverlayController`/`SoundPlayer`/
      `NotificationAlerter`. Introduce minimal protocols for the three (or make the
      existing concrete types' methods overridable spies) — prefer **protocols**
      (`OverlayShowing`, `SoundPlaying`, `NotificationPosting`) mirroring the
      `AlertPresenting` seam, defaulted in `init` so production call sites are unchanged.
      Tests: overlay-only when only overlay enabled; sound forced on `.persistent` even
      with `soundEnabled == false`; notification gated on its toggle; `displayDuration`/
      `clickToDismiss` pushed to the overlay on each present.
   2. `ShooTests/DeviceSelectorTests.swift` — selection precedence (stored-ID match →
      built-in → first), via whatever pure seam `DeviceSelector` exposes; if selection is
      inseparable from `AVCaptureDevice.DiscoverySession`, extract the ordering logic
      into a pure function first.
   3. Snooze re-arm test in `AppStateScheduleSnoozeTests.swift` (Design N3).
   4. Two-hands fixture in `HandFaceDetectorTests`/`FrameObservationFixture`: both hands'
      fingertips contribute; contact from the second hand alone still scores.
7. **Bookkeeping.** Update `docs/AUDIT.md` (move resolved deferred items to Resolved;
   leave the intentionally-parked ones with a one-line rationale). Run `make ci`.

## Files to create / modify

**Create:**
- `ShooTests/AlertPresenterTests.swift`
- `ShooTests/DeviceSelectorTests.swift`

**Modify:**
- `Shoo/Views/SettingsView.swift` — N1 fix; D3 controls
- `Shoo/Views/OnboardingView.swift` — D1 guard
- `Shoo/Camera/CameraController.swift` — N2
- `Shoo/Camera/PowerCoordinator.swift` — N7
- `Shoo/Camera/DeviceSelector.swift` — possible pure-function extraction for T2
- `Shoo/App/AppState.swift` — N3, N5, N6, N8 comment
- `Shoo/Models/AppSettings.swift` — D2, `soundName` doc comment
- `Shoo/Detection/HandFaceDetector.swift` — N4
- `Shoo/Detection/VisionFrameAnalyzer.swift` — D4
- `Shoo/Alerting/AlertPresenter.swift` — T1 protocol seams (behavior-preserving)
- `scripts/coverage.sh` — D5
- `ShooTests/AppStateScheduleSnoozeTests.swift`, `ShooTests/AppSettingsMigrationTests.swift`,
  `ShooTests/HandFaceDetectorTests.swift`, `ShooTests/FrameObservationFixture.swift` — new
  cases + `@MainActor` annotations
- `docs/AUDIT.md` — status update

## Edge cases & risks

- **N2 reconfigure path:** the `!session.outputs.contains(videoOutput)` condition must
  keep the existing reconfigure behavior (output already attached → skip is correct).
  Manual check: unplug/replug an external camera and confirm recovery still works.
- **N3 visibility widening:** `handleSnoozeExpiry` becomes `internal`; keep the doc
  comment noting it's internal-for-tests (same convention as `ensurePermissionThenStart`).
- **D2 `@MainActor` fallout:** any non-annotated test or preview constructing
  `AppSettings` stops compiling — fix is mechanical, but build the test target before
  assuming the blast radius is small. If `AppSettings` is constructed in a `nonisolated`
  context anywhere (it isn't today), that call site needs a hop, not an annotation.
- **N5 debounce vs. tests:** if any test drives `settings.sensitivity` and synchronously
  asserts detector config, the debounce introduces asynchrony. Audit existing tests first;
  if needed, inject the scheduler (`debounce(for:scheduler:)` with an immediate scheduler
  in tests) rather than sprinkling waits.
- **D4 Vision API behavior:** per-group `recognizedPoints(_:)` must apply the same
  `handPointConfidence` floor; verify against the recorded fixtures, not just compilation.
- **T1 seam creep:** keep the three new protocols minimal (exactly the methods
  `AlertPresenter` calls) so this stays a test seam, not an abstraction layer.
- **AlertPresenter spy timing:** `present()` reads settings live; tests must mutate the
  injected `AppSettings` (isolated suite, as in existing tests) before each call.

## Testing & verification

- `make ci` (generate, lint strict, build unsigned, full test suite + coverage) green.
- New unit tests pass: AlertPresenter fan-out matrix, DeviceSelector precedence, snooze
  re-arm, two-hands fixture.
- Manual (no seam): 
  - **N1:** Settings → "Show onboarding again" → close *Settings* window while onboarding
    is open → app stays `.regular` and onboarding stays usable; close onboarding → app
    returns to `.accessory` (menu-bar only, no Dock icon).
  - **D1:** finish onboarding via the button → no double log/start; close the onboarding
    window mid-flow via ⌘W → still marked onboarded, `.accessory` restored once.
  - **D3:** change "Show reminder for" and click-to-dismiss in Settings, fire a debug
    alert, confirm hold time and click behavior follow the settings.
- `scripts/coverage.sh` runs on a machine without `python3` on PATH (temporarily shadow
  it) and degrades with a warning instead of erroring.

## Dependencies & sequencing

No dependencies on other plans; everything here is post-01–06 cleanup. Independent of
plan 05 (signing/submission), which remains the only open feature plan. Suggested commit
order = the numbered implementation steps; steps 1–5 can land in any order, step 6
after the production changes it tests, step 7 last.

## Out of scope

- `DEVELOPMENT_TEAM` / signing / release pipeline — plan 05.
- Folding `isVideoMirrored` into the orientation derivation — the mirror-invariance is
  documented and regression-tested (WP10); revisit only if rotated external cameras
  become a real use case.
- `stop()` full device teardown for long-idle agents — deliberate trade against resume
  latency; unchanged.
- Sound-forced-on-`.persistent`-while-muted (`AlertPresenter.swift:57`) — current
  behavior is intentional ("gentle nudge up"); revisit with user feedback, not here.
- `PauseReason.lowPower` — kept; referenced by tests.
- Weekday-aware `nextBoundaryDate()` — documented as by-design (N8).
- Detection-quality tuning, new features, App Store work.
