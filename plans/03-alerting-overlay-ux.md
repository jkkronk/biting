# 03 — Alerting & Overlay UX

## Context

Shoo is a sandboxed macOS menu-bar agent (`LSUIElement`, Mac App Store, macOS 14+) that watches the webcam and reminds the user to keep their hands away from their face. This plan covers the **user-facing reminder layer**: the overlay window, its animations, multi-display targeting, alert modes (overlay / sound / notification / escalation), the debounce/cooldown state machine, snooze/dismiss interactions, accessibility, and a lightweight local catch-count for a future stats view.

This plan does **not** cover the detection math (face/hand proximity) — that is plan 01 (`detection-engine`). The boundary is the single call `AlertManager.handleDetection(_ handInFace: Bool, cooldown:)` already wired in `AppState.wirePipeline()`. Everything downstream of that boolean is in scope here.

The relevant existing files are:

- `Shoo/Alerting/AlertManager.swift` — per-frame boolean → single event (debounce + cooldown). Currently calls `overlay.show()`.
- `Shoo/Alerting/OverlayWindow.swift` — borderless `NSPanel` centered on `NSScreen.main`, hard show/`orderOut`, `displayDuration = 2.5`.
- `Shoo/Alerting/OverlayView.swift` — SwiftUI "✋ Stop!" content.
- `Shoo/App/AppState.swift` — owns `AlertManager`, wires the pipeline.
- `Shoo/Models/AppSettings.swift` — `UserDefaults`-backed prefs (`sensitivity`, `cooldownSeconds`, `launchAtLogin`).

## Goals / Definition of done

1. Overlay fades in and out (scale + opacity) instead of a hard show/close, honoring **Reduce Motion**.
2. Overlay appears on the screen the user is actually looking at (screen with the mouse / key window), not always `NSScreen.main`, and behaves correctly over full-screen apps and across Spaces.
3. The overlay **never steals focus** and never activates Shoo; it can optionally be click-to-dismiss.
4. Alert modes are configurable through `AppSettings` and observed live: centered overlay (always on), optional sound, optional `UNUserNotifications` banner, optional gentle escalation when the behavior persists. Sensible defaults are defined.
5. `AlertManager` is a clearly specified **state machine** with sustained-frame hysteresis, per-session cooldown, snooze-for-N-minutes, and pause.
6. The user can dismiss the current overlay, snooze, or pause from the overlay and/or the menu bar.
7. Accessibility: VoiceOver announces the alert; Reduce Motion, Reduce Transparency, Increase Contrast, and Dynamic Type are respected.
8. A lightweight, local-only per-day catch count is recorded (data shape defined; no UI built here).
9. New logic is unit-testable: the state machine and the daily-stats store have tests with an injectable clock; UI/AppKit pieces are kept thin.

## Current state

- `AlertManager` (42 lines): `requiredSustainedHits = 3`, increments `consecutiveHits` on `true`, resets on `false`, fires when count ≥ threshold and `cooldown` has elapsed since `lastFiredAt`. No pause, no snooze, no hysteresis on the trailing edge, no stats, no notion of alert modes.
- `OverlayWindow` (55 lines): rebuilds a fresh `NSPanel` per show; `styleMask [.borderless, .nonactivatingPanel]`; `level = .statusBar`; `ignoresMouseEvents = true`; `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`; centers on `NSScreen.main`; `orderFrontRegardless()`; dismiss after `displayDuration` via `DispatchQueue.main.asyncAfter`. The `TODO` explicitly asks for fade animation.
- `OverlayView` (28 lines): static `VStack` with emoji + "Stop!" + subtitle on `.ultraThinMaterial`. No animation state, no accessibility wiring, no dismiss affordance.
- `AppSettings` exposes only `sensitivity`, `cooldownSeconds`, `launchAtLogin`. No alert-mode flags.
- `Shoo.entitlements`: `app-sandbox` + `device.camera`. **No notification-specific entitlement is required** for `UNUserNotificationCenter` under the sandbox, but the app must request runtime authorization.
- `Info.plist`: `LSUIElement` true. Good — keeps the overlay's app a true agent.

## Design

### Overview

```
AlertManager (state machine, @MainActor)
   │  decides WHEN to alert + at what escalation level
   ▼
AlertPresenter (new, @MainActor)          ← fan-out to enabled modes
   ├── OverlayController (rename/own OverlayWindow)  → fade in/out on active screen
   ├── SoundPlayer        (NSSound / system sound)
   └── NotificationCenter (UNUserNotificationCenter banner)
Stats: CatchStatsStore (new) ← increments a per-day counter on each fired alert
```

`AlertManager` stays pure-ish (no AppKit) and owns timing/state. `AlertPresenter` owns the side-effects and reads `AppSettings`. This keeps the state machine unit-testable without a screen.

### 1. AlertManager state machine

States (`enum AlertState`):

- `.idle` — watching, nothing pending.
- `.arming(hits: Int)` — consecutive positive frames accumulating toward `requiredSustainedHits`.
- `.cooldown(until: Date, level: EscalationLevel)` — alert just fired; suppress new alerts until `until`.
- `.snoozed(until: Date)` — user asked for quiet; positive frames are ignored entirely until `until`.
- `.paused` — watching off for alerts (distinct from camera off); positive frames ignored.

Inputs:

- `handInFace(Bool)` per frame (existing `handleDetection`).
- `snooze(minutes:)`, `dismiss()`, `pause()`, `resume()` from UI.
- `tick(now:)` injectable clock — use a `() -> Date` closure (default `Date.init`) so tests control time. Replace the implicit `Date()` calls.

Transitions (evaluated with `now = clock()`):

- In `.idle`/`.arming`: a `false` frame → reset to `.arming(hits: 0)` (equivalent to idle). A `true` frame → `hits += 1`; when `hits >= requiredSustainedHits` → **fire** and go to `.cooldown(until: now + cooldown, level: .first)`.
- **Trailing-edge hysteresis (new):** require `releaseFrames` (default 2) consecutive `false` frames before fully clearing `arming`, so a one-frame detection dropout mid-touch doesn't reset the counter. Track a small `missStreak`; only reset `hits` when `missStreak >= releaseFrames`.
- In `.cooldown(until, level)`: positive frames that *persist past* `until` → fire again, escalating `level` if `escalationEnabled` and the behavior has been continuous (see escalation below). Otherwise wait.
- `.snoozed(until)`/`.paused`: ignore all frames; on `tick` past `until`, snoozed → `.idle`.

**Escalation** (`EscalationLevel: .first, .persistent`): if `settings.escalationEnabled` and the user keeps a hand at the face across *N consecutive cooldown cycles* (`escalationThreshold`, default 2 — i.e. the user ignored the first reminder and is still touching after the cooldown), bump to `.persistent`. `.persistent` makes the overlay stay slightly longer and adds sound even if sound is otherwise off — a "gentle nudge up", never an alarm. A single clean release (a real `.idle` transition) resets level back to `.first`.

Each **fire** does two things: (a) call `presenter.present(level:)`, (b) call `stats.recordCatch(at: now)`.

`requiredSustainedHits` already exists; add `releaseFrames`, `escalationEnabled`, `escalationThreshold`. Drive `requiredSustainedHits` and cooldown from `AppSettings` (see settings below) rather than hard-coding, but keep safe defaults.

### 2. Overlay polish (fade in/out)

Use **two coordinated layers**:

- **Window appearance:** keep the `NSPanel` alive but animate `panel.animator().alphaValue` from 0→1 on show and 1→0 on dismiss using `NSAnimationContext.runAnimationGroup`. This is the reliable way to fade an `NSWindow`; SwiftUI's own opacity inside the hosting view does not affect the window's shadow/material edges, so the *window* alpha is the source of truth for fade.
- **Content transform:** drive a subtle scale (0.92 → 1.0 on appear, 1.0 → 0.96 on disappear) via a SwiftUI `@State var isVisible` + `.scaleEffect`/`.opacity` with `.animation(...)`. Toggle it right after `orderFront`.

Timing/easing (defaults): fade-in 0.22 s `easeOut`; hold = `displayDuration` (default 2.5 s, `.persistent` → 3.5 s); fade-out 0.30 s `easeIn`. Centralize as static constants in `OverlayController`.

**Reduce Motion:** when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true, skip the scale transform and use a **cross-fade only** with a shorter duration (0.12 s), or, if you want zero motion, set alpha instantly and rely on the system to honor the cross-fade. Read this once per show; also observe `NSWorkspace.shared.notificationCenter` `accessibilityDisplayOptionsDidChangeNotification` to stay current.

Replace the per-show `NSPanel` rebuild with a **single retained panel** that is reused (created lazily, hidden between alerts). Rebuilding each time discards the hosting view and makes fade state harder to manage. Cancel any in-flight dismiss work item when a new alert arrives (store the `DispatchWorkItem` / use a `Task` you can cancel) so re-fires during a hold don't double-schedule dismiss.

### 3. Multi-display targeting

Pick the target screen at show time, in this priority order:

1. Screen containing the mouse: `NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }`.
2. Screen of the current key/main window if any app's key window is known — not generally reachable for other apps from a sandboxed agent, so in practice fall back to:
3. `NSScreen.main` (the screen with the active/focused window per AppKit) and finally `NSScreen.screens.first`.

Implement as `OverlayController.targetScreen() -> NSScreen`. Center within `screen.visibleFrame` (not `frame`) so the panel isn't tucked under the menu bar on the built-in display, then offset upward by ~8% of height so it sits slightly above center (more glanceable). Re-resolve the screen on **every** show, which inherently handles display arrangement changes (screens added/removed/rearranged) — no caching of the screen object.

Full-screen apps & Spaces: keep `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`. `.canJoinAllSpaces` makes the panel follow the user across Spaces; `.fullScreenAuxiliary` lets it draw over another app's full-screen Space (the panel is auxiliary to whatever full-screen window is frontmost). Add `.ignoresCycle` so it never appears in Cmd-Tab/window cycling. Verified correct for this use case; the existing two flags are right, `.ignoresCycle` is the additive polish.

### 4. Window level & non-intrusiveness

- Keep `styleMask = [.borderless, .nonactivatingPanel]` and **do not** call `makeKeyAndOrderFront`; use `orderFrontRegardless()`. This guarantees no focus steal and no app activation. Confirm `NSApp.activate` is never called for the overlay.
- **Level:** raise from `.statusBar` to `.screenSaver` (`NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))` or the AppKit constant `.screenSaver`). `.statusBar` can sit *below* some full-screen UI; `.screenSaver` reliably floats above full-screen apps while still being below the actual screen saver / login. Avoid `.maximumWindow`/`MaximumWindowLevelKey` (Apple-discouraged, can cover system alerts).
- **Mouse events:** make this a setting. Default `ignoresMouseEvents = true` (purely informational, clicks pass through to the app behind). If `clickToDismiss` is enabled, set `ignoresMouseEvents = false` and add an `onTapGesture` in `OverlayView` that calls back to dismiss + optionally `snooze`. Because the panel is non-activating, a click dismisses without bringing Shoo forward.
- **Screen sharing / recording:** by default the overlay *should* be captured (it's the user's own reminder). Optionally expose `panel.sharingType = .none` later if users want it hidden from screen recordings; out of scope to wire a setting now, but note the hook.
- **Do Not Disturb / Focus:** the overlay is a window, not a notification, so Focus modes do **not** suppress it — which is desired (the reminder must work during focused work). The optional `UNUserNotifications` banner *will* be suppressed by Focus; that is acceptable and even appropriate. Do not try to bypass Focus.

### 5. Alert modes (tie to AppSettings)

Add to `AppSettings` (new `UserDefaults` keys + `@Published` + `register(defaults:)`):

| Setting | Type | Default | Notes |
|---|---|---|---|
| `overlayEnabled` | Bool | `true` | Always available; the core mode. |
| `soundEnabled` | Bool | `false` | Off by default (menu-bar agent should be quiet). |
| `soundName` | String | `"Pop"` | A named system sound (`NSSound(named:)`); validate, fall back to `NSSound.beep()`. |
| `notificationEnabled` | Bool | `false` | Requires runtime authorization. |
| `clickToDismiss` | Bool | `false` | Controls `ignoresMouseEvents`. |
| `escalationEnabled` | Bool | `true` | Gentle nudge if behavior persists. |
| `displayDurationSeconds` | Double | `2.5` | Overlay hold time. |

Defaults rationale: the app should be **calm and glanceable** out of the box — overlay only, no sound, no banner. Escalation on (but gentle) so a user who ignores the first reminder gets a slightly firmer one. Power users opt into sound/notifications in Settings (plan 04 builds that UI).

**Sound:** `AlertPresenter` plays `NSSound(named: NSSound.Name(settings.soundName))?.play()` on the main actor when `soundEnabled` (or when `.persistent` escalation forces it). No file shipping needed if using named system sounds; if a custom sound is desired later, bundle an `.aiff` and load by name. Keep volume modest.

**UNUserNotifications banner:** use `UNUserNotificationCenter.current()`.
- On first enable of `notificationEnabled`, call `requestAuthorization(options: [.alert, .sound])`; reflect the result in Settings (plan 04) and disable the toggle back to `false` if denied.
- On fire (when enabled and authorized), post a `UNNotificationRequest` with a `UNMutableNotificationContent` (`title = "Hands down ✋"`, `body = "You reached for your face."`) and a `nil`/immediate trigger. Use a **fixed identifier** so repeated alerts replace rather than stack (`removeDeliveredNotifications` / reuse id). No badge.
- Sandbox note: `UNUserNotificationCenter` needs **no extra entitlement**; it works in the sandbox once the user grants notification permission. Do not add a notifications entitlement.
- Tradeoff: notifications are good when the user has switched away (Shoo can't reliably know), but they're suppressed by Focus and can pile up. Hence default off; overlay is the primary channel.

**Escalation** ties together: level `.persistent` → longer overlay hold + force one sound ping, even with `soundEnabled == false`, capped at one ping per cooldown cycle so it stays gentle.

### 6. Snooze / dismiss / "I'm done"

- **Dismiss (this one):** fades out the current overlay immediately; does not change cooldown. Wire from click-to-dismiss and from a small "✕" in `OverlayView` when `clickToDismiss` is on.
- **Snooze N minutes:** `AlertManager.snooze(minutes:)` → `.snoozed(until: now + minutes*60)`. Surface as menu-bar submenu ("Snooze 5/15/30 min") and optionally a "Snooze" button in the overlay. While snoozed, the menu-bar symbol/status reflects it ("Snoozed until 3:42").
- **Pause / "I'm done for now":** `pause()` → `.paused`; `resume()` to re-enable. This is *alert* pause, separate from `AppState.stopWatching()` (which stops the camera). Distinguish in the menu: "Pause reminders" vs the existing watch toggle. (Plan 04 wires the menu items; this plan defines the methods and state.)

### 7. Accessibility

- **VoiceOver announcement:** on fire, post an announcement so VoiceOver users hear it even though the overlay is a non-key window:
  `NSAccessibility.post(element: NSApp.mainWindow ?? NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: "Stop. Hands away from your face.", .priority: NSAccessibilityPriorityLevel.high.rawValue])`.
  Do this once per fire (not per frame). Guard against spamming under escalation (announce once per cooldown cycle).
- **Reduce Motion:** see §2 — cross-fade only / no scale.
- **Reduce Transparency:** when `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` is true, swap `.ultraThinMaterial` for a solid `Color(nsColor: .windowBackgroundColor)` background in `OverlayView`.
- **Increase Contrast:** when `accessibilityDisplayShouldIncreaseContrast` is true, strengthen the border (`.white`/`.separator` opacity → 1.0, wider `lineWidth`) and use higher-contrast text colors (`.primary` instead of `.secondary` for the subtitle). SwiftUI exposes `@Environment(\.colorSchemeContrast)` inside the view; read it there.
- **Dynamic Type:** replace fixed `.font(.system(size:))` with semantic fonts (`.largeTitle`/`.title`/`.headline`) so they scale, but cap with `.dynamicTypeSize(...(.accessibility2))` so the panel doesn't overflow its fixed 360×180 frame; alternatively let the panel size to content via `sizeThatFits`. Make the panel size derive from the hosting view's fitting size rather than a hard-coded rect.
- Mark the content container with `.accessibilityElement(children: .combine)` and a label "Stop. Hands away from your face." so if VO does land on it, it reads sensibly.

### 8. Lightweight daily stats (data shape only)

Goal: count catches per day for a future stats view; local-only, tiny, no UI here.

Data shape — a `Codable` dict keyed by ISO day string:

```swift
struct CatchStats: Codable {
    /// "yyyy-MM-dd" (user-local calendar) → number of fired alerts that day.
    var countsByDay: [String: Int]
}
```

Store: `CatchStatsStore` (new, `@MainActor`) persists `CatchStats` as JSON in `UserDefaults` under key `"catchStats"` (small; fine for `UserDefaults`). API: `recordCatch(at: Date)` increments today's bucket; `count(on: Date) -> Int`; `last7Days() -> [(day: String, count: Int)]`. Prune entries older than ~90 days on write to bound size. Inject the same clock as `AlertManager` for testability. Only **fired** alerts (escalation re-fires count once each) increment; arming frames do not.

Privacy: counts only, no timestamps-of-day, no images, never leaves the device — consistent with `docs/PRIVACY.md`.

## Implementation steps

1. **AppSettings:** add keys/`@Published`/defaults for `overlayEnabled`, `soundEnabled`, `soundName`, `notificationEnabled`, `clickToDismiss`, `escalationEnabled`, `displayDurationSeconds` (table in §5). Keep the existing `didSet`-persist pattern.
2. **AlertManager rewrite:** introduce `enum AlertState` and `enum EscalationLevel`; add injectable `clock: () -> Date`; add `releaseFrames`, `escalationEnabled`, `escalationThreshold`; implement transitions (§1); add `snooze(minutes:)`, `dismiss()`, `pause()`, `resume()`, and a `tick()` (called from a lightweight timer or evaluated lazily on each `handleDetection`). Replace direct `overlay.show()` with `presenter.present(level:)` + `stats.recordCatch`. Keep `fire()` for the debug menu (fires `.first`).
3. **AlertPresenter (new):** `present(level:)` reads `AppSettings` and fans out to overlay/sound/notification + VoiceOver announcement. Holds references to `OverlayController`, `SoundPlayer`, and the notification helper. `@MainActor`.
4. **OverlayController (rename `OverlayWindow`):** retain a single lazy `NSPanel`; implement `show(level:)`/`dismiss()` with `NSAnimationContext` alpha fades + content scale; `targetScreen()` multi-display logic; `.screenSaver` level; `.ignoresCycle` added; click-to-dismiss wiring; Reduce Motion branch; cancelable dismiss `Task`/`DispatchWorkItem`.
5. **OverlayView:** add `isVisible` state + scale/opacity transitions; semantic fonts + Dynamic Type cap; Reduce Transparency / Increase Contrast branches via `@Environment`; accessibility label/combine; optional dismiss ✕ + Snooze button calling back through a closure.
6. **SoundPlayer (new, small):** `play(named:)` wrapping `NSSound`, main-actor, validates name, falls back to `NSSound.beep()`.
7. **Notifications (new helper):** `NotificationAlerter` — `requestAuthorizationIfNeeded()`, `post()`, fixed identifier replacement. No entitlement change.
8. **CatchStats + CatchStatsStore (new):** as §8.
9. **AppState wiring:** construct `AlertPresenter`, `CatchStatsStore`, pass `settings`/`clock` into `AlertManager`; expose `snooze/pause/resume` passthroughs for the menu (plan 04 consumes them). Update `handleDetection` call site if signature changes (prefer keeping the existing signature; read extra config from injected `settings`).
10. **Tests:** unit-test the state machine and stats store with a controllable clock (§Testing).

## Files to create / modify

Modify:
- `Shoo/Alerting/AlertManager.swift` — state machine, clock injection, snooze/pause, escalation, presenter + stats hookup.
- `Shoo/Alerting/OverlayWindow.swift` → rename to `OverlayController.swift` (type `OverlayController`) — single retained panel, fades, multi-display, level, click-to-dismiss, Reduce Motion. (Keep filename if renaming the Xcode target ref is costly; at minimum rename the type or document why not.)
- `Shoo/Alerting/OverlayView.swift` — animation state, accessibility, Dynamic Type, contrast/transparency branches, optional dismiss/snooze affordances.
- `Shoo/Models/AppSettings.swift` — new alert-mode settings.
- `Shoo/App/AppState.swift` — construct/inject presenter + stats; expose snooze/pause/resume.
- `docs/ARCHITECTURE.md` — update the Alerting paragraph to mention presenter, modes, stats.

Create:
- `Shoo/Alerting/AlertPresenter.swift`
- `Shoo/Alerting/SoundPlayer.swift`
- `Shoo/Alerting/NotificationAlerter.swift`
- `Shoo/Models/CatchStats.swift` (+ `CatchStatsStore`, or split into `Shoo/Models/CatchStatsStore.swift`)
- `ShooTests/AlertManagerStateMachineTests.swift`
- `ShooTests/CatchStatsStoreTests.swift`

No entitlement or `Info.plist` changes required for this plan (notifications need no sandbox entitlement; camera + sandbox already present). `LSUIElement` stays true.

## Edge cases & risks

- **Display disconnect mid-alert:** the panel's screen is unplugged while showing. Mitigate by re-resolving `targetScreen()` only at show; if the panel's current screen vanishes, observe `NSApplication.didChangeScreenParametersNotification` and re-center onto a still-present screen (or dismiss).
- **Rapid re-fire during a hold:** in-flight dismiss must be cancelable so escalation re-fires don't dismiss the freshly shown overlay. Use a single cancelable dismiss `Task`.
- **Snooze/pause persistence:** decide that snooze/pause are **session-only** (reset on relaunch) — simpler and less surprising than persisting "paused" across launches. Document this.
- **Clock skew / timezone change for stats:** day bucketing uses the user-local calendar at record time; a timezone change can shift buckets — acceptable for a casual counter; document.
- **Notification authorization denied:** must flip `notificationEnabled` back to `false` and not silently no-op forever. Surface in plan 04's Settings UI.
- **Reduce Motion + fade:** ensure the no-motion path still actually hides the window (don't leave alpha at a partial value if an animation is skipped).
- **VoiceOver spam:** announce once per cooldown cycle, not per fire-check; high priority can interrupt the user's reading if overused.
- **`.screenSaver` level over login/lock:** never show while the screen is locked — pause the camera/alerts on lock (coordinated with plan 02 camera-lifecycle); the overlay must not appear on the lock screen.
- **Sandbox + `NSSound(named:)`:** named system sounds are fine in the sandbox; a *file* sound must be inside the app bundle (read-only is allowed). Don't read user-supplied paths.
- **Multiple very fast displays / mismatched scale factors:** centering uses `visibleFrame` of the chosen screen, which is per-screen correct; no manual backing-scale math needed.

## Testing & verification

Unit (XCTest, no UI):
- `AlertManagerStateMachineTests`: inject a mutable `clock`. Verify: arming requires `requiredSustainedHits` positives; one dropout within `releaseFrames` does not reset; cooldown suppresses re-fire until elapsed; snooze ignores frames until expiry then resumes; pause ignores frames until resume; escalation reaches `.persistent` after `escalationThreshold` ignored cycles and resets after a clean release; each fire calls a stubbed presenter and stats exactly once.
- `CatchStatsStoreTests`: `recordCatch` increments today; cross-midnight (advance clock) creates a new bucket; `last7Days` ordering; pruning drops >90-day entries; round-trips through `UserDefaults` JSON. Use a throwaway `UserDefaults(suiteName:)`.
- Use a `presenter` protocol (`AlertPresenting`) so the manager takes a stub in tests; the real `AlertPresenter` is the AppKit implementation.

Manual / smoke (documented checklist, run via plan 06 CI is N/A for UI):
- Fade in/out looks smooth; Reduce Motion gives a clean cross-fade.
- Overlay appears on the display with the mouse; move mouse to a second display and re-trigger.
- Overlay floats over a full-screen app (e.g. full-screen Safari/Keynote) and follows across Spaces.
- Clicking through (default) passes to the app behind; with `clickToDismiss` on, a click dismisses without activating Shoo (front app stays active — verify menu bar / focus unchanged).
- Sound plays only when enabled or under `.persistent`.
- Notification appears when enabled+authorized and replaces rather than stacks.
- VoiceOver announces the alert once.
- Reduce Transparency / Increase Contrast / large Dynamic Type render correctly and don't clip.
- Snooze hides alerts for the chosen minutes; pause disables until resumed; both reflected in the menu status (plan 04).

## Dependencies & sequencing

- **01 detection-engine:** provides the `handInFace` boolean stream. This plan consumes it through the unchanged `handleDetection` entry point; can be built in parallel against the existing placeholder wiring.
- **02 camera-lifecycle:** must pause alerts/overlay on display lock/sleep and when watching stops. This plan defines `pause()/resume()`; plan 02 calls them on lock/unlock. Coordinate the "no overlay on lock screen" rule there.
- **04 settings-onboarding:** builds the Settings UI and menu items for the new toggles, snooze submenu, pause item, and notification-authorization flow. This plan defines the settings keys and `AlertManager`/`AppState` methods it will bind to.
- **05 appstore-distribution:** confirm no new entitlements (none added here) and that notification usage is described in the App Store privacy questionnaire (counts + local notifications only).
- **06 testing-ci:** runs the new XCTest targets; UI smoke checklist is manual.

Recommended order: settings keys + state-machine + stats (this plan, testable) → presenter/overlay/sound/notification (AppKit) → plan 04 wires UI → plan 02 coordinates lock behavior.

## Out of scope

- Detection math / proximity logic (plan 01).
- Camera capture, permission flow, lock/sleep pausing implementation (plan 02 — this plan only defines the pause API it should call).
- The Settings window UI and menu-bar item layout (plan 04 — this plan defines the bound state).
- A stats **view**/visualization (only the `CatchStats` data shape + store are in scope).
- App Store submission, entitlements review, code signing (plan 05).
- Custom bundled sound assets, sound packs, or per-mode haptics.
- Hiding the overlay from screen recordings via a setting (noted as a future `sharingType` hook, not wired).
- Persisting snooze/pause across app launches (explicitly session-only).
