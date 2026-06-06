# Architecture

Shoo is a small, single-process macOS menu-bar app. It captures webcam frames, runs two on-device Vision requests per frame, decides whether a hand is touching/approaching the face, and—when so—shows a brief centered overlay reminding the user to stop.

## Pipeline

```
┌─────────────┐   CVPixelBuffer   ┌──────────────────┐
│ CameraManager│ ───────────────▶ │ HandFaceDetector │
│ AVCaptureSession                │  Vision requests │
└─────────────┘                   └────────┬─────────┘
                                           │ face CGRect + hand points
                                           ▼
                                  ┌──────────────────┐
                                  │ ProximityAnalyzer│  pure logic → Bool
                                  └────────┬─────────┘
                                           │ handInFace
                                           ▼
                                  ┌──────────────────┐
                                  │   AlertManager   │  state machine: arming/
                                  │                  │  cooldown/snooze/pause,
                                  └────────┬─────────┘  escalation, stats
                                           │ present(level:)
                                           ▼
                                  ┌──────────────────┐
                                  │  AlertPresenter  │  fan-out to enabled modes
                                  └────────┬─────────┘
                       overlay / sound / notification / VoiceOver
```

## Modules

- **App** — `ShooApp` (`@main`) builds a `MenuBarExtra` scene, a `Settings` scene, and a dedicated onboarding `Window` (`WindowID.onboarding`). `AppState` is the app-wide `ObservableObject` that owns the running on/off state and wires the camera → detector → alert chain. A small `ShooAppDelegate` (`@NSApplicationDelegateAdaptor`) presents first-run onboarding once (gated by `AppSettings.hasOnboarded`): because the app is `LSUIElement`, it temporarily flips `NSApp.setActivationPolicy(.regular)` + `activate(ignoringOtherApps:)` so the onboarding window can take focus, then restores `.accessory` when onboarding finishes/closes. `openWindow`/`dismissWindow` are captured from the menu content's `.onAppear` into `AppState.windowOpener` so the delegate (which has no SwiftUI `@Environment`) can drive the window.
- **Camera** — `CameraManager` configures an `AVCaptureSession` with an `AVCaptureVideoDataOutput` and forwards `CVPixelBuffer`s on a serial queue. `CameraPermission` wraps the `AVCaptureDevice` authorization flow and publishes status for the UI.
- **Detection** — `HandFaceDetector` runs `VNDetectFaceRectanglesRequest` and `VNDetectHumanHandPoseRequest` per frame via a `VNImageRequestHandler`, then feeds the results to `ProximityAnalyzer`. `ProximityAnalyzer` is a **pure** value type (no AVFoundation/Vision imports) so it can be unit-tested in isolation.
- **Alerting** — `AlertManager` is a clock-injectable **state machine** (`idle → arming → cooldown`, plus `snoozed`/`paused`) with sustained-frame hysteresis on both edges, a per-fire cooldown, snooze-for-N-minutes, pause/resume, and gentle **escalation** (`.first → .persistent`) when the behavior persists across cooldown cycles. It stays pure (no AppKit) and fans each fire out through an `AlertPresenting`. `AlertPresenter` reads `AppSettings` live and dispatches to the enabled **modes**: the centered overlay (always), an optional system sound, an optional `UNUserNotifications` banner, plus a VoiceOver announcement. `OverlayController` retains a single borderless, non-activating `NSPanel` that fades in/out (window alpha + content scale, honoring Reduce Motion), targets the screen under the mouse, floats above full-screen apps at `.screenSaver` level, and never steals focus. `CatchStatsStore` records a tiny, local-only per-day catch count for a future stats view.
- **Views** — `MenuBarView` is a **state-driven** popover keyed off `AppState.effectiveState` (`watching`/`paused`/`snoozed`/`needsPermission`/`permissionDenied`/`noCamera`/`outsideSchedule`): a status dot + line, the right primary affordance per state (grant access, open System Settings, recheck, snooze menu / resume, "watch anyway"), a daily "reminders today" count, Settings, and Quit. `SettingsView` is a `TabView` (Detection / Reminders / Schedule / General / About) with a "Reset to Defaults" confirmation in General. `OnboardingView` is a paged step machine (Welcome → Privacy → Camera access → All set) that only triggers the camera prompt at an explicit tap.
- **Models** — `AppSettings` is an `ObservableObject` that persists user preferences in `UserDefaults` (`@Published` + `didSet`, defaults via `register(defaults:)`). It is **schema-versioned**: `settingsSchemaVersion` + a `migrateIfNeeded()` hook (ordered `migrateVXtoVY()` steps) so keys can be added/renamed safely; `resetToDefaults()` clears managed keys and reassigns each `@Published`. Pure value types live in `SettingsTypes.swift` (`AlertMode`, `GestureMask`, `WeekdaySet`, and the unit-tested `ActiveSchedule.isActive(at:)` covering overnight/all-day/weekday/DST cases).
- **Support** — `AppLogger` (an `os.Logger` wrapper), `LaunchAtLogin` (an `SMAppService` helper exposing a `State` incl. `.requiresApproval`, a `Result`-returning `setEnabled`, and a Login-Items opener; `AppState` syncs it back from the live status on activation), `SystemSettings` (deep-links to Privacy → Camera), and `AppInfo` (bundle version/build/copyright for About).

## Threading

- Camera frames arrive on a dedicated serial dispatch queue.
- Vision requests run on that queue (or a detection queue) to keep the main thread free.
- UI updates (overlay, menu state) are dispatched back to the main actor.

## Performance notes

- Throttle processing to ~10–15 fps; nail-biting is slow, so we don't need 60 fps.
- Consider downscaling frames before Vision to cut CPU/GPU cost.
- Pause the session when watching is disabled or the display is locked.

## Why Vision (not MediaPipe / cloud)

On-device, no dependencies, good battery behavior, and a clean App Store privacy story. `VNDetectHumanHandPoseRequest` gives 21 landmarks per hand; `VNDetectFaceRectanglesRequest` gives the face box. That's enough to reason about overlap without shipping a model or sending data off-device.
