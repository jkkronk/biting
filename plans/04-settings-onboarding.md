# 04 — Settings, Onboarding & Menu UX

## Context

Shoo is a sandboxed, Mac-App-Store-targeted macOS 14+ menu-bar agent (`LSUIElement = true`,
no dock icon, no main window). Its UI today is exactly two SwiftUI scenes declared in
`Shoo/App/ShooApp.swift`:

- `MenuBarExtra("Shoo", systemImage:)` with `.menuBarExtraStyle(.window)` hosting `MenuBarView`.
- `Settings { SettingsView() }`.

Both scenes receive the shared `AppState` (`Shoo/App/AppState.swift`, `@MainActor`,
`ObservableObject`) via `.environmentObject`. `AppState` owns `let settings = AppSettings()`
(`Shoo/Models/AppSettings.swift`), the camera, detector, and alert manager.

This plan covers the **user-facing shell**: first-run onboarding + camera-permission priming,
menu-bar popover UX, the full preferences surface, launch-at-login correctness, optional
active-hours scheduling, an About screen, and settings persistence/versioning/migration.

It deliberately does **not** cover camera/session internals (plan 02), detection (plan 01),
or the overlay/alert sound (plan 03) — it only defines the **settings keys and UI** those
plans read from. Where this plan references a setting another plan consumes (e.g. `alertSound`,
`startWatchingOnLaunch`), it owns the storage and UI; the other plan owns the behavior.

## Goals / Definition of done

1. **First-run onboarding** runs once (gated by a persisted `hasOnboarded` flag). It explains
   *why* the camera is needed and the on-device privacy promise *before* triggering the macOS
   camera prompt, requests access at an explicit user action, gracefully handles denial with a
   one-tap path to System Settings → Privacy → Camera, and ends in an "all set" state. It is
   presented in a real, focusable window despite the app being `LSUIElement`.
2. **Menu popover** clearly communicates: watching/paused/snoozed state, camera-permission
   state (with a "Grant access…" / "Open System Settings…" affordance when not authorized),
   quick pause/snooze, an open-Settings button, and Quit. Denied/not-determined/no-device
   states render sensibly instead of a dead toggle.
3. **Preferences** are organized into tabbed sections (Detection, Reminders, Schedule, General,
   About) covering current + planned keys, with a working "Reset to Defaults".
4. **Launch-at-login** toggle reflects the *actual* `SMAppService.mainApp.status` (including
   `.requiresApproval`), survives external changes, and surfaces errors instead of silently
   desyncing.
5. **Active hours** scheduling: optional, off by default; when on, watching is only permitted
   during selected weekdays + a daily time window.
6. **About** screen shows version/build, a privacy link, and acknowledgements — App-Store-appropriate.
7. **Persistence** is versioned with a `settingsSchemaVersion` key and a migration hook so future
   keys can be added/renamed safely. New defaults registered via `UserDefaults.register(defaults:)`.
8. Project still builds clean and all existing tests pass; new pure logic (active-hours, migration)
   is unit-tested.

## Current state

- `AppSettings` (`Shoo/Models/AppSettings.swift`): `ObservableObject` with three `@Published`
  properties (`sensitivity: Double`, `cooldownSeconds: Double`, `launchAtLogin: Bool`), each
  persisting in `didSet`, with `register(defaults:)` for fallbacks. Uses a `private enum Keys`.
- `SettingsView` (`Shoo/Views/SettingsView.swift`): single `Form` with `.formStyle(.grouped)`,
  fixed `width: 380`; passes `appState.settings` to a private `SettingsForm` as `@ObservedObject`.
  Drives launch-at-login through `LaunchAtLogin.setEnabled` in `.onChange`.
- `MenuBarView` (`Shoo/Views/MenuBarView.swift`): a `Toggle` bound to `appState.toggleWatching()`,
  a `statusText` derived from `appState.cameraStatus`, `Settings…` (via `@Environment(\.openSettings)`),
  and Quit. Fixed `width: 240`.
- `AppState`: `isWatching` (settable), `cameraStatus` (`private(set)`, **never updated** today —
  stuck at `.notDetermined`), `startWatching()`/`stopWatching()`/`toggleWatching()`.
  `startWatching()` has a `// TODO: request camera permission if needed`.
- `LaunchAtLogin` (`Shoo/Support/LaunchAtLogin.swift`): `isEnabled` computed from
  `SMAppService.mainApp.status == .enabled`; `setEnabled` calls `register()`/`unregister()`,
  logs on failure. **No `.requiresApproval` handling; no sync-back into `AppSettings`.**
- `CameraPermission` (`Shoo/Camera/CameraPermission.swift`): `Status` enum
  (`notDetermined/authorized/denied/restricted`) + `current` (non-prompting) + `request()` (async).
- `Info.plist`: `LSUIElement = true`, `NSCameraUsageDescription` present.
- `Shoo.entitlements`: `com.apple.security.app-sandbox` + `com.apple.security.device.camera` only
  (no network entitlement — privacy link must open in the default browser, which is allowed).
- No onboarding flow, no `Window` scene, no About screen, no scheduling, no snooze.

Gaps this plan closes: `cameraStatus` is never refreshed; onboarding/priming is absent; the
permission-denied path is text-only; launch-at-login can desync; no schema versioning.

## Design

### 1. Settings model: expanded `AppSettings`

Keep the existing pattern (`@Published` + `didSet` persistence + `register(defaults:)`), extend
the `Keys` enum, and add a schema version. Do **not** switch to `@AppStorage`: a single
`ObservableObject` shared via `environmentObject` is already the project's idiom, gives one source
of truth across the menu + settings + onboarding windows, and centralizes migration. (`@AppStorage`
is acceptable for purely view-local toggles, but the cross-scene sharing here favors the
`ObservableObject`.)

New/expanded properties (all persisted in `didSet` exactly like the existing three):

| Property | Type | Default | Owner of behavior | Notes |
|---|---|---|---|---|
| `sensitivity` | `Double` | `0.5` | plan 01 | existing |
| `cooldownSeconds` | `Double` | `5.0` | plan 03 | existing |
| `launchAtLogin` | `Bool` | `false` | this plan | mirror of `SMAppService` status (see §5) |
| `startWatchingOnLaunch` | `Bool` | `true` | this plan / plan 02 | auto-start watching when authorized |
| `watchedGestures` | `GestureMask` (OptionSet, `Int`) | `.all` | plan 01 | which gesture types to flag |
| `alertSoundEnabled` | `Bool` | `true` | plan 03 | UI here, playback there |
| `alertMode` | `AlertMode` (enum `String`) | `.overlay` | plan 03 | overlay / overlayAndSound / silentBadge |
| `scheduleEnabled` | `Bool` | `false` | this plan | master switch for active hours |
| `activeWeekdays` | `WeekdaySet` (OptionSet, `Int`) | `.all` | this plan | bitmask, Sun…Sat |
| `activeStartMinutes` | `Int` | `540` (09:00) | this plan | minutes since local midnight |
| `activeEndMinutes` | `Int` | `1020` (17:00) | this plan | minutes since local midnight |
| `hasOnboarded` | `Bool` | `false` | this plan | gates onboarding window |
| `settingsSchemaVersion` | `Int` | `currentSchemaVersion` (=1) | this plan | migration anchor |

Supporting value types (new file `Shoo/Models/SettingsTypes.swift`, pure — unit-testable, no
AppKit/AVFoundation imports):

- `enum AlertMode: String, CaseIterable, Identifiable { case overlay, overlayAndSound, silentBadge }`
- `struct GestureMask: OptionSet { let rawValue: Int; static let nailBiting, nosePicking, lipBiting, hairPulling …; static let all }`
- `struct WeekdaySet: OptionSet { let rawValue: Int; static let sunday … saturday; static let all; static let weekdays }`
- `struct ActiveSchedule { var enabled; var weekdays: WeekdaySet; var startMinutes: Int; var endMinutes: Int; func isActive(at date: Date, calendar: Calendar = .current) -> Bool }`
  — pure function; handles the wrap-around case where `endMinutes <= startMinutes` (overnight window),
  and "all day" when start == end. This is the unit-tested core.

`AppSettings` gains:

- `static let currentSchemaVersion = 1`.
- `func resetToDefaults()` — removes the managed keys from `defaults`, re-reads, and reassigns each
  `@Published` (so observers update). Implemented by iterating a known `Keys` list.
- A computed `var activeSchedule: ActiveSchedule` assembling the four schedule properties, so
  `AppState` can ask `settings.activeSchedule.isActive(at:)`.

### 2. Persistence, versioning & migration

- On `AppSettings.init`, after `register(defaults:)` and loading values, call a private
  `migrateIfNeeded()`:
  - Read `storedVersion = defaults.integer(forKey: Keys.settingsSchemaVersion)` (0 if never set).
  - If `storedVersion < currentSchemaVersion`, run ordered migration steps in a `switch`/sequence
    (e.g. `migrateV0toV1()`), then `defaults.set(currentSchemaVersion, forKey: Keys.settingsSchemaVersion)`.
  - v0→v1 is a no-op today (just stamps the version) but establishes the hook; document the pattern
    in a code comment so future renames (e.g. `cooldownSeconds` → `reminderCooldown`) copy-then-delete
    the old key here.
- All new keys ship defaults through the existing `register(defaults:)` dictionary so a fresh
  install and an upgrade behave identically.

### 3. Onboarding & permission priming

**Presentation mechanic (the LSUIElement problem).** An `LSUIElement` app has no dock icon and no
auto-shown window, and a window opened from a `MenuBarExtra` action can appear *behind* the
frontmost app and without focus. Solution:

- Add a dedicated SwiftUI `Window` scene in `ShooApp`:
  ```swift
  Window("Welcome to Shoo", id: WindowID.onboarding) {
      OnboardingView().environmentObject(appState)
  }
  .windowResizability(.contentSize)
  .defaultPosition(.center)
  .windowToolbarStyle(.unified)   // or hide title bar via background
  ```
  with `enum WindowID { static let onboarding = "onboarding"; static let about = "about" }`.
- Trigger first-run open from a small `AppDelegate` adaptor
  (`@NSApplicationDelegateAdaptor(ShooAppDelegate.self)`), in
  `applicationDidFinishLaunching`: if `!appState.settings.hasOnboarded`, open the onboarding window
  and **activate the app** so it comes to front and can take keyboard focus:
  ```swift
  NSApp.setActivationPolicy(.regular)   // temporarily show in dock/switcher during onboarding
  openWindow(id: WindowID.onboarding)   // via stored openWindow action or NSApp window lookup
  NSApp.activate(ignoringOtherApps: true)
  ```
  Because `openWindow` is a SwiftUI `@Environment` value not available in the AppDelegate, capture
  it instead from a hidden helper view (`.onAppear` in the `MenuBarExtra` content stores
  `openWindow`/`dismissWindow` into `appState`), OR drive visibility with a `@Published
  showOnboarding` on `AppState` and gate the `Window` body — simplest is: keep a
  `WindowOpener` object on `AppState` holding the `openWindow` closure, set from the menu content's
  `.onAppear`. Document the chosen approach (recommended: `AppState.windowOpener`).
- **Activation policy dance:** flipping to `.regular` during onboarding gives a focusable window +
  dock presence; when onboarding finishes (or its window closes), flip back to `.accessory`
  (`NSApp.setActivationPolicy(.accessory)`) so we return to a pure menu-bar agent. Handle the
  window-close via a `.onDisappear` / `NSWindowDelegate` to restore `.accessory` even if the user
  closes the window early.

**Onboarding flow (`OnboardingView`, a `TabView`/paged step machine with `@State step`):**

1. **Welcome** — what Shoo does (one sentence), friendly illustration/SF Symbol
   (`hand.raised.fill`). "Continue".
2. **Privacy promise** — bullet list mirroring `docs/PRIVACY.md`: on-device Vision, no recording,
   no network, sandboxed. Reassure *before* asking. "Continue".
3. **Camera access** — explain the prompt is coming, then a primary button "Enable Camera Access"
   that calls `await CameraPermission.request()` (the macOS prompt fires here, at explicit user
   intent — never on launch). Branch on the result:
   - `.authorized` → advance to step 4.
   - `.denied`/`.restricted` → show inline denial state with "Open System Settings" button (see
     below) + "I'll do this later" (advance anyway; menu will keep nudging).
4. **All set** — confirmation, a "Start watching now" toggle prefilled from
   `startWatchingOnLaunch`, and "Done". "Done" sets `settings.hasOnboarded = true`, closes the
   window (`dismissWindow(id:)` / window delegate), restores `.accessory` policy, and — if
   authorized and start-on-launch — calls `appState.startWatching()`.

**Open System Settings to camera privacy** (used in onboarding *and* the menu): a helper
`SystemSettings.openCameraPrivacy()`:
```swift
let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
NSWorkspace.shared.open(url)
```
Provide a fallback to `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera`
(newer System Settings) — try the latter first on macOS 13+, then the former. Put this in a new
`Shoo/Support/SystemSettings.swift`. (Allowed under sandbox; opening a URL via `NSWorkspace` does
not require the network entitlement.)

**Re-entry:** add a "Show onboarding again" affordance only in the About tab (debug-friendly,
sets `hasOnboarded = false` and opens the window) — not strictly required, but cheap and helps QA.

### 4. Menu-bar popover UX

Rework `MenuBarView` into clear state-driven sections. Drive everything from `AppState`
(`cameraStatus`, `isWatching`, plus new `snoozeUntil: Date?` and a computed
`effectiveState: WatchState`). Define `enum WatchState { case watching, paused, snoozed(until:Date),
needsPermission, permissionDenied, noCamera, outsideSchedule }` computed in `AppState` from camera
status + isWatching + snooze + schedule.

Popover layout (top → bottom):

- **Header row:** app name + a colored status dot + one-line status string from `effectiveState`.
- **Primary control, state-dependent:**
  - `needsPermission` → "Grant Camera Access" button → `Task { await appState.requestCameraAccess() }`.
  - `permissionDenied`/`restricted` → "Open System Settings…" → `SystemSettings.openCameraPrivacy()`.
  - `noCamera` → disabled explanatory text "No camera found. Connect a webcam." + a "Recheck" button.
  - authorized → the existing watch `Toggle`, plus a **Snooze** menu (`Menu("Snooze")` with 15 min /
    30 min / 1 hour / "until tomorrow morning" → sets `appState.snooze(for:)`), and a "Resume now"
    button when snoozed.
  - `outsideSchedule` → info text "Paused by schedule until HH:mm" + "Watch anyway" override.
- **Stats (optional, lightweight):** a `triggersToday` counter on `AppState` (in-memory + persisted
  daily via a `statsDate` + `statsCount` key; resets when the date rolls over). Show "N reminders
  today". Keep it modest; full analytics are out of scope.
- **Divider**, then `Settings…` (keeps `openSettings()`), and `Quit Shoo`.

`AppState` additions to support this:
- `func refreshCameraStatus()` → `cameraStatus = CameraPermission.current` (call on
  `MenuBarExtra` content `.onAppear` and on `NSApplication.didBecomeActiveNotification`, fixing the
  never-updated bug).
- `func requestCameraAccess() async` → `cameraStatus = await CameraPermission.request()`; if
  authorized and `startWatchingOnLaunch`, start.
- `snooze(for:)` / `resume()` and a `snoozeUntil` timer that auto-resumes.
- `effectiveState` and `triggersToday`.

Keep `frame(width:)` but bump to ~260–280 to fit the richer content; let height be intrinsic.

### 5. Launch-at-login correctness (`SMAppService`)

- `LaunchAtLogin` gains `enum State { case enabled, requiresApproval, notRegistered, unavailable }`
  derived from `SMAppService.mainApp.status` (`.enabled → enabled`, `.requiresApproval →
  requiresApproval`, `.notRegistered → notRegistered`, `.notFound/@unknown → unavailable`).
- `setEnabled(_:) -> Result<State, Error>` (return the resulting state instead of `Void`) so the UI
  can react. On `.requiresApproval` after `register()`, prompt the user with a button to open
  Login Items: `SMAppService.openSystemSettingsLoginItems()`.
- **Sync-back:** `AppState` (or the General settings view) refreshes `settings.launchAtLogin` from
  `LaunchAtLogin.state == .enabled` on appear / `didBecomeActive`, so a user disabling the login
  item in System Settings is reflected in the toggle (fixes desync). The toggle's `.onChange` calls
  `setEnabled` and then re-reads state to set the toggle authoritatively (avoid trusting the
  optimistic value).
- **Sandbox/App Store notes:** `SMAppService.mainApp` registers the *main app itself* as a login
  item — fully supported for sandboxed Mac App Store apps (no helper executable, so no
  helper-sandbox concerns). Keep default `false` (Apple review expects opt-in, no auto-launch
  without consent). No `SMPrivilegedExecutables`, no embedded login helper needed.
- Error handling: failures are logged (existing `AppLogger.app`) **and** surfaced in the General
  tab as an inline warning row ("Couldn't update Login Items — open System Settings"); never
  silently swallow.

### 6. Active hours / scheduling

- General gate: `scheduleEnabled` toggle. When off, schedule never blocks watching.
- UI (Schedule tab): weekday multi-select (seven toggle chips or a `Picker`-row set bound to
  `WeekdaySet`), and two time pickers for start/end backed by `activeStartMinutes`/`activeEndMinutes`
  (use `DatePicker(.. , displayedComponents: .hourAndMinute)` bridged to minutes via a computed
  `Binding<Date>`).
- Enforcement is **advisory in this plan**: `AppState` exposes
  `var isWithinActiveHours: Bool { !settings.scheduleEnabled || settings.activeSchedule.isActive(at: Date()) }`
  and an `effectiveState` of `.outsideSchedule`. Actually *gating the camera session* on schedule
  (a timer that starts/stops watching at window boundaries) is a behavior detail coordinated with
  plan 02; this plan provides the pure `ActiveSchedule.isActive`, the settings, the menu state, and
  a `Timer`/`Task` skeleton in `AppState` that re-evaluates at the next boundary. Document that
  plan 02 wires the actual `camera.start()/stop()` calls to these boundaries.
- Edge: DST transitions and overnight windows handled inside `ActiveSchedule.isActive` (compare
  minutes-since-midnight from `Calendar.current` components, not absolute time math).

### 7. About screen

- Add an `About` tab in Settings (and/or a separate `Window(id: WindowID.about)` reachable from the
  menu's `Settings…` → About tab; a tab is simplest and avoids a second activation dance).
- Content: app icon, "Shoo", version string from
  `Bundle.main.infoDictionary["CFBundleShortVersionString"]` + build from `CFBundleVersion`,
  a "Privacy Policy" link (`Link` opening the repo `docs/PRIVACY.md` GitHub URL or a hosted page —
  opens in browser, sandbox-safe), an "Acknowledgements" disclosure (none/third-party-free today —
  state "No third-party code; built with Apple Vision, SwiftUI, and ServiceManagement"), and
  copyright from `NSHumanReadableCopyright`.
- Provide a tiny `AppInfo` helper (`Shoo/Support/AppInfo.swift`) exposing `version`, `build`,
  `displayName`, `copyright` read from `Bundle.main`.

### 8. Settings window structure

Convert `SettingsView` from a single `Form` to a `TabView` with `.tabViewStyle` default (the
macOS preferences look), tabs: **Detection**, **Reminders**, **Schedule**, **General**, **About**,
each a small `Form { … }.formStyle(.grouped)`. Add a footer "Reset to Defaults…" button (with a
confirmation `.alert`) in the General tab calling `settings.resetToDefaults()`. Preserve the
existing Detection (sensitivity) and Reminders (cooldown) controls; move launch-at-login into
General alongside `startWatchingOnLaunch` and the alert-mode/sound toggles (whose behavior plan 03
owns). Use per-tab `.frame(width: 420)` for consistency.

## Implementation steps

1. **Settings value types.** Create `Shoo/Models/SettingsTypes.swift` with `AlertMode`,
   `GestureMask`, `WeekdaySet`, `ActiveSchedule` (pure, no AppKit). Add unit-test target file
   `ShooTests/ActiveScheduleTests.swift` covering normal window, overnight wrap, all-day, weekday
   masking, and a DST-day spot check.
2. **Expand `AppSettings`.** Add the new keys to `Keys`, the `@Published` properties (+`didSet`
   persistence), defaults in `register(defaults:)`, `currentSchemaVersion`, `migrateIfNeeded()`,
   `resetToDefaults()`, and `var activeSchedule`. Add `migrate v0→v1` no-op stamping the version.
   Add `ShooTests/AppSettingsMigrationTests.swift` using a throwaway `UserDefaults(suiteName:)`.
3. **`SystemSettings` + `AppInfo` helpers.** Create `Shoo/Support/SystemSettings.swift`
   (`openCameraPrivacy()`) and `Shoo/Support/AppInfo.swift`.
4. **Harden `LaunchAtLogin`.** Add `State`, `state` computed property, change `setEnabled` to return
   `Result<State, Error>`, add `openLoginItemsSettings()` wrapper over
   `SMAppService.openSystemSettingsLoginItems()`.
5. **Extend `AppState`.** Add `snoozeUntil`, `triggersToday`, `WatchState`, `effectiveState`,
   `refreshCameraStatus()`, `requestCameraAccess() async`, `snooze(for:)`/`resume()`,
   `isWithinActiveHours`, `windowOpener` storage, and schedule-boundary `Task`. Wire
   `cameraStatus` refresh on `didBecomeActive`. Sync `launchAtLogin` from `LaunchAtLogin.state`.
6. **Onboarding.** Create `Shoo/Views/OnboardingView.swift` (paged step machine) and
   `Shoo/App/ShooAppDelegate.swift` (`applicationDidFinishLaunching` opens onboarding when
   `!hasOnboarded`, does the `.regular`↔`.accessory` activation dance). Add `WindowID` enum.
7. **`ShooApp` scenes.** Add `@NSApplicationDelegateAdaptor(ShooAppDelegate.self)`, the
   `Window(id: WindowID.onboarding)` scene, and an `.onAppear` in the `MenuBarExtra` content that
   stores `openWindow`/`dismissWindow` into `appState.windowOpener` and calls `refreshCameraStatus()`.
8. **Menu UX.** Rewrite `MenuBarView` per §4 (state-driven sections, snooze menu, permission CTAs,
   stats line). Bump `frame(width:)`.
9. **Settings UX.** Refactor `SettingsView` into a `TabView` (Detection/Reminders/Schedule/General/
   About), build the Schedule and About tabs, add Reset-to-Defaults with confirmation, move
   launch-at-login into General with state-aware row + sync-back + `requiresApproval` CTA.
10. **Wire-up & polish.** Ensure `startWatchingOnLaunch` is honored after onboarding/auth; ensure
    closing onboarding restores `.accessory`; verify `Settings…` still opens.
11. **Regenerate project & build.** `xcodegen generate` (new files under `Shoo/` and `ShooTests/`
    are globbed by the existing `sources:` paths in `project.yml`, so no spec edit needed), then
    `xcodebuild … build` and `… test`.

## Files to create / modify

**Create**
- `/Users/JonatanMBA/Documents/code/biting/Shoo/Models/SettingsTypes.swift`
- `/Users/JonatanMBA/Documents/code/biting/Shoo/Support/SystemSettings.swift`
- `/Users/JonatanMBA/Documents/code/biting/Shoo/Support/AppInfo.swift`
- `/Users/JonatanMBA/Documents/code/biting/Shoo/Views/OnboardingView.swift`
- `/Users/JonatanMBA/Documents/code/biting/Shoo/App/ShooAppDelegate.swift`
- `/Users/JonatanMBA/Documents/code/biting/ShooTests/ActiveScheduleTests.swift`
- `/Users/JonatanMBA/Documents/code/biting/ShooTests/AppSettingsMigrationTests.swift`

**Modify**
- `/Users/JonatanMBA/Documents/code/biting/Shoo/App/ShooApp.swift` — add delegate adaptor + `Window`
  scene + `WindowID`.
- `/Users/JonatanMBA/Documents/code/biting/Shoo/App/AppState.swift` — `WatchState`, snooze, stats,
  camera-status refresh, request flow, schedule, window opener.
- `/Users/JonatanMBA/Documents/code/biting/Shoo/Models/AppSettings.swift` — new keys, schema
  version, migration, reset, `activeSchedule`.
- `/Users/JonatanMBA/Documents/code/biting/Shoo/Support/LaunchAtLogin.swift` — `State`, richer
  `setEnabled`, login-items opener.
- `/Users/JonatanMBA/Documents/code/biting/Shoo/Views/MenuBarView.swift` — state-driven popover.
- `/Users/JonatanMBA/Documents/code/biting/Shoo/Views/SettingsView.swift` — `TabView`, Schedule/
  About tabs, reset, General with login-item state.
- `/Users/JonatanMBA/Documents/code/biting/docs/ARCHITECTURE.md` — note onboarding `Window`,
  activation-policy behavior, schema versioning (the doc currently says model is named `Settings`/
  `@AppStorage`; correct to `AppSettings`/`ObservableObject`).

No `project.yml`, `Info.plist`, or `Shoo.entitlements` changes are required (no new entitlements;
URL-opening is sandbox-safe). If a hosted privacy URL is used, add it to the About link only.

## Edge cases & risks

- **Window won't focus / appears behind frontmost app.** Mitigated by the `.regular` activation
  policy + `NSApp.activate(ignoringOtherApps:)` during onboarding; must restore `.accessory` on
  close (window delegate) or the app keeps a dock icon. Test closing the window via the red button.
- **`openWindow` unavailable in AppDelegate.** Resolved by capturing it from the menu content
  `.onAppear` into `AppState.windowOpener`; risk if the menu content hasn't appeared yet on a cold
  launch — fallback: drive onboarding visibility with a `@Published showOnboarding` gating the
  `Window` body, or open via `NSApp.windows` lookup after `openWindow`.
- **Camera prompt fires at the wrong time.** Never call `CameraPermission.request()` on launch;
  only from the explicit onboarding button or the menu "Grant Access" CTA.
- **Denied-then-granted-externally:** user grants camera in System Settings while app runs —
  `refreshCameraStatus()` on `didBecomeActive` picks it up. Same pattern for login-items desync.
- **`.requiresApproval` login item** (common on first registration): toggle must show "needs
  approval" and offer `openSystemSettingsLoginItems()`, not appear broken.
- **No camera device** (`AVCaptureDevice.default(for: .video) == nil`): authorization can be
  `.authorized` yet there's no device. Surface `noCamera` from `AppState` (coordinate exact signal
  with plan 02; for now infer from camera failure callback).
- **Overnight / all-day schedules & DST:** handled in pure `ActiveSchedule.isActive` via
  minutes-since-midnight; unit-tested. Avoid absolute-time arithmetic.
- **Reset to Defaults** must reassign `@Published` values (not just clear `UserDefaults`) or the UI
  won't refresh; also re-sync launch-at-login.
- **Sandbox:** opening `x-apple.systempreferences:` and `https` privacy links via `NSWorkspace` is
  permitted without extra entitlements; confirm during App Store review that no network entitlement
  is implied.
- **First-run double-open:** guard against opening the onboarding window twice if
  `applicationDidFinishLaunching` and the menu `.onAppear` both fire — gate on `hasOnboarded` and a
  `didPresentOnboarding` flag.

## Testing & verification

- **Unit (XCTest, pure):**
  - `ActiveScheduleTests` — in-window, out-of-window, boundary minutes, overnight wrap, all-day
    (start==end), weekday inclusion/exclusion, a DST-day evaluation.
  - `AppSettingsMigrationTests` — fresh defaults register correctly; `settingsSchemaVersion` stamped
    to `currentSchemaVersion`; `resetToDefaults()` restores documented defaults and bumps
    `@Published` values; round-trip persistence of each new key via an isolated
    `UserDefaults(suiteName:)`.
  - Keep existing `ProximityAnalyzerTests` green.
- **Manual / QA checklist:**
  1. Fresh install (delete app's `UserDefaults` domain) → onboarding window appears, centered,
     focused, with dock icon during onboarding only.
  2. Step 3 "Enable Camera Access" triggers the system prompt; Allow → step 4; Deny → inline
     "Open System Settings" works and lands on Privacy → Camera.
  3. Finish → `hasOnboarded` true; relaunch does **not** re-onboard; dock icon gone (`.accessory`).
  4. Menu shows correct state for: not-determined, authorized+watching, paused, snoozed (and
     auto-resume), denied (CTA), no-camera, outside-schedule.
  5. Snooze 15 min → state shows snoozed; "Resume now" works.
  6. Settings tabs render; sensitivity/cooldown still persist; Reset to Defaults restores values and
     the UI updates live.
  7. Launch-at-login: toggle on → appears in System Settings ▸ Login Items; toggle reflects
     `.requiresApproval` if shown; disabling it in System Settings updates the toggle after app
     reactivation.
  8. Schedule: enable, set window/weekdays; menu reflects `outsideSchedule` outside the window;
     "Watch anyway" overrides.
  9. About tab shows correct version/build/copyright; privacy link opens in browser.
- **Build:** `xcodegen generate` then
  `xcodebuild -project Shoo.xcodeproj -scheme Shoo build` and `… test` — clean, all tests pass.

## Dependencies & sequencing

- **Plan 01 (detection-engine):** owns `sensitivity` mapping and `watchedGestures` semantics; this
  plan only stores/render those settings. No hard ordering — can proceed in parallel; consumes the
  keys when ready.
- **Plan 02 (camera-lifecycle):** owns the real `cameraStatus` source of truth, the `noCamera`
  signal, and actually starting/stopping the session on schedule boundaries and on
  `startWatchingOnLaunch`. This plan should land **after** or alongside 02 for the camera-state and
  schedule-gating wiring; it defines the settings/menu surface 02 hooks into. The `cameraStatus`
  refresh added here also unblocks 02's UI feedback.
- **Plan 03 (alerting-overlay):** owns `alertMode`/`alertSoundEnabled`/`cooldownSeconds` *behavior*
  and the `triggersToday` increment. This plan provides the UI toggles + the stats counter storage;
  3 calls into them. Parallel-friendly.
- **Plan 05 (appstore-distribution):** depends on this plan's onboarding, About screen, privacy
  link, and launch-at-login default (`false`) for App Review compliance; 05 should run **after** 04.
- **Plan 06 (testing-ci):** consumes the new XCTest files; ensure they run in CI. 04 adds tests, 06
  wires the pipeline.

Recommended order: 02 → 04 (with 01/03 in parallel) → 05 → 06.

## Out of scope

- Camera capture/session configuration, throttling, downscaling, device selection (plan 02).
- Vision requests, proximity logic, sensitivity tuning, gesture classification (plan 01).
- Overlay rendering, fade animation, alert sound playback, cooldown/debounce behavior (plan 03).
- Code signing, notarization, entitlement changes, App Store Connect metadata/privacy questionnaire
  (plan 05).
- CI configuration (plan 06).
- Localization (English-only for now), full analytics/history beyond a daily "reminders today"
  counter, iCloud/settings sync, in-app purchase, and any networked privacy-policy hosting decision.
