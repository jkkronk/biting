import AppKit
import Combine
import CoreVideo
import Foundation
import ImageIO

/// App-wide state and the glue that wires the detection pipeline together.
///
/// Owns the camera (behind the ``FrameSource`` seam), detector, alert manager, and the
/// ``PowerCoordinator``, and exposes a single `isWatching` switch that the menu-bar UI
/// toggles. Created once in ``ShooApp``.
@MainActor
final class AppState: ObservableObject {
    /// How long the overlay's "Snooze" button quiets watching for.
    static let overlaySnoozeMinutes = 5

    /// Whether Shoo is actively watching the webcam (user intent).
    @Published var isWatching: Bool = false

    /// Single source of truth for capture lifecycle, mirrored from the ``FrameSource``.
    @Published private(set) var sessionState: CameraSessionState = .idle

    /// User-facing camera authorization status, derived from `sessionState`/permission.
    @Published private(set) var cameraStatus: CameraPermission.Status = CameraPermission.current

    /// When set (and in the future), watching is snoozed until this instant; the menu shows
    /// a "snoozed" state and a "Resume now" affordance. Distinct from a session pause.
    @Published private(set) var snoozeUntil: Date?

    /// In-memory mirror of how many reminders fired today (persisted daily; resets at the
    /// date rollover). Surfaced in the menu as "N reminders today".
    @Published private(set) var triggersToday: Int = 0

    /// When the user overrides the active-hours schedule from the menu ("Watch anyway"),
    /// scheduling is ignored until the next launch. Pure menu affordance.
    @Published private(set) var scheduleOverride: Bool = false

    let settings = AppSettings()

    /// Captures SwiftUI's `openWindow`/`dismissWindow` actions (set from the menu content's
    /// `.onAppear`) so the ``ShooAppDelegate`` — which has no `@Environment` — can present the
    /// onboarding window. See plan 04 §3.
    let windowOpener = WindowOpener()

    /// Captures SwiftUI's `openSettings` action (set from the menu's `.onAppear`) so the menu
    /// can present the Settings window with the activation-policy dance an `LSUIElement` app
    /// needs to actually show & focus it.
    var openSettingsAction: (() -> Void)?

    /// Restores the menu-bar-agent activation policy after onboarding closes. Wired by
    /// ``ShooApp`` to ``ShooAppDelegate/finishOnboarding()``.
    var onOnboardingFinished: (() -> Void)?

    /// Injectable wall clock — defaults to `Date()`. Tests inject a controlled clock so snooze,
    /// schedule, and daily-stats logic is deterministic.
    let now: () -> Date

    private let camera: FrameSource
    private let detector = HandFaceDetector()
    private let stats: CatchStatsStore
    private let presenter: AlertPresenter
    private let alerts: AlertManager
    private let power: PowerCoordinator
    /// The most recent processed camera frame, captured on the main actor just before a
    /// detection is handled. Read by ``presenter``'s snapshot provider to put a photo in the
    /// reminder overlay. In-memory only — never persisted.
    private var latestFrame: (buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation)?
    private var cancellables = Set<AnyCancellable>()
    private var foregroundWindowObserver: NSObjectProtocol?
    private var dayChangeObserver: NSObjectProtocol?
    private var scheduleTimer: Timer?
    private var snoozeTimer: Timer?
    /// Windows we intentionally brought to the foreground (Settings / onboarding). Activation
    /// policy reverts to `.accessory` only when none of these remain visible — tracked by
    /// identity, not by (localized) window title. Weak, so closed windows drop out.
    private let trackedForegroundWindows = NSHashTable<NSWindow>.weakObjects()

    /// Override hooks so tests can drive the permission gate without real hardware or
    /// triggering the system prompt.
    var permissionProvider: () -> CameraPermission.Status = { CameraPermission.current }
    var permissionRequester: () async -> CameraPermission.Status = { await CameraPermission.request() }

    /// SF Symbol shown in the menu bar; reflects the current session state.
    var menuBarSymbolName: String {
        switch sessionState {
        case .running: return "hand.raised.fill"
        case .pausedAuto: return "hand.raised.slash"
        case .noPermission, .noDevice, .failed, .interrupted: return "exclamationmark.triangle"
        case .idle, .starting: return "hand.raised.slash"
        }
    }

    init(frameSource: FrameSource = CameraController(),
         now: @escaping () -> Date = { Date() }) {
        self.now = now
        self.camera = frameSource
        self.power = PowerCoordinator(frameSource: frameSource)
        // Alerting layer: shared clock keeps the state machine and stats in lock-step.
        let stats = CatchStatsStore(clock: now)
        let presenter = AlertPresenter(settings: settings)
        self.stats = stats
        self.presenter = presenter
        self.alerts = AlertManager(presenter: presenter, stats: stats, clock: now)
        self.alerts.escalationEnabled = settings.escalationEnabled
        wirePipeline()
        // Overlay dismiss/snooze affordances loop back through AppState so the menu's snooze
        // state + auto-resume timer stay consistent (not just the alert-only quiet).
        presenter.bindOverlay(
            onDismiss: { [weak self] in self?.alerts.dismiss() },
            onSnooze: { [weak self] in self?.snooze(for: AppState.overlaySnoozeMinutes) }
        )
        // Put a small camera photo in the overlay (when enabled). Evaluated at present-time so
        // it reflects the frame current when the reminder fires.
        presenter.snapshotProvider = { [weak self] in
            guard let self, self.settings.snapshotInReminderEnabled,
                  let frame = self.latestFrame else { return nil }
            return CameraSnapshot.image(from: frame.buffer, orientation: frame.orientation)
        }
        // Push the initial sensitivity + watched-gesture config and keep it in sync.
        detector.updateConfig(currentDetectorConfig())
        observeSensitivity()
        observeWatchedGestures()
        observeAlertSettings()
        // Keep the menu's "reminders today" counter fresh.
        self.alerts.onFire = { [weak self] in self?.refreshTriggersToday() }
        refreshTriggersToday()
        // Reflect the real login-item state (it can desync from settings via System Settings).
        syncLaunchAtLogin()
        installForegroundWindowObserver()
        installDayRolloverObserver()
        observeSchedule()
        scheduleBoundaryTimer()
        // Honor a notification permission granted in a previous session without re-toggling.
        Task { await presenter.refreshNotificationAuthorization() }
    }

    // MARK: - Control

    func startWatching() {
        isWatching = true
        Task { await ensurePermissionThenStart() }
    }

    func stopWatching() {
        isWatching = false
        camera.stop()
        detector.reset()  // clear temporal state so we don't resume mid-gesture
    }

    func toggleWatching() {
        if isWatching { stopWatching() } else { startWatching() }
    }

    // MARK: - Windows

    /// Open the Settings window. As an accessory (menu-bar-only) app we must flip to `.regular`
    /// and activate so the window is focused and frontmost; the close observer restores
    /// `.accessory` once no tracked foreground window remains.
    func presentSettings() {
        enterForegroundWindow { [weak self] in self?.openSettingsAction?() }
    }

    /// Open the onboarding window with the same activation dance + identity tracking.
    func presentOnboarding() {
        enterForegroundWindow { [weak self] in self?.windowOpener.open(id: WindowID.onboarding) }
    }

    /// Flip to `.regular`, run `open`, activate, then track the window that became key so the
    /// revert logic keys off window *identity* rather than a localized title.
    private func enterForegroundWindow(_ open: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        open()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if let window = NSApp.keyWindow { self?.trackedForegroundWindows.add(window) }
            }
        }
    }

    /// Revert to a pure menu-bar agent (`.accessory`) once none of the tracked foreground
    /// windows (Settings / onboarding) remain visible. The overlay panel is never tracked, so
    /// it can't keep us in `.regular`. Idempotent — safe to call from multiple close paths.
    func revertActivationIfNoForegroundWindows() {
        guard NSApp.activationPolicy() == .regular else { return }
        let anyVisible = trackedForegroundWindows.allObjects.contains { $0.isVisible }
        if !anyVisible { NSApp.setActivationPolicy(.accessory) }
    }

    private func installForegroundWindowObserver() {
        foregroundWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // willClose fires before the window hides; defer a tick, then re-evaluate.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.revertActivationIfNoForegroundWindows() }
            }
        }
    }

    deinit {
        if let observer = foregroundWindowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = dayChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        scheduleTimer?.invalidate()
        snoozeTimer?.invalidate()
    }

    // MARK: - Alert controls (consumed by plan 04's menu)

    /// Quiet reminders for `minutes` (overlay/sound/notification suppressed).
    func snoozeAlerts(minutes: Int) { alerts.snooze(minutes: minutes) }

    /// Turn reminders off until ``resumeAlerts()`` — distinct from stopping the camera.
    func pauseAlerts() { alerts.pause() }

    /// Re-enable reminders after a pause/snooze.
    func resumeAlerts() { alerts.resume() }

    /// Fire a reminder immediately (debug menu).
    func fireAlert() { alerts.fire() }

    /// Whether reminders are currently suppressed (paused or snoozed).
    var alertsSuppressed: Bool { alerts.isSuppressed }

    /// When the current snooze expires, if any.
    var snoozedUntil: Date? { alerts.snoozedUntil }

    /// Request notification authorization for the banner mode (plan 04 Settings).
    func requestNotificationAuthorization() async -> Bool {
        await presenter.requestNotificationAuthorization()
    }

    /// Resolve authorization, then start the camera (or surface why we can't).
    /// Internal (not private) so tests can await the gating directly.
    func ensurePermissionThenStart() async {
        sessionState = .starting
        switch permissionProvider() {
        case .authorized:
            cameraStatus = .authorized
            camera.start()
        case .notDetermined:
            let result = await permissionRequester()
            cameraStatus = result
            if result == .authorized {
                camera.start()
            } else {
                sessionState = .noPermission(result)
                isWatching = false
            }
        case .denied:
            cameraStatus = .denied
            sessionState = .noPermission(.denied)
            isWatching = false
        case .restricted:
            cameraStatus = .restricted
            sessionState = .noPermission(.restricted)
            isWatching = false
        }
    }

    /// Re-read permission (e.g. on menu appear / app activation): the user may have
    /// flipped the setting in System Settings while we ran. Auto-starts if appropriate.
    func refreshPermission() {
        let current = permissionProvider()
        cameraStatus = current
        switch current {
        case .authorized:
            // If the user wants to watch but we weren't running, (re)start.
            if isWatching, !isRunning {
                camera.start()
            }
        case .denied, .restricted, .notDetermined:
            // Permission revoked mid-session: actually stop capture (releases the camera +
            // resets the detector) rather than just flipping flags. `cameraStatus` (set above)
            // already drives `effectiveState` to the right permission state.
            if isWatching || isRunning {
                stopWatching()
            }
        }
    }

    /// Whether the capture session is currently delivering frames.
    private var isRunning: Bool {
        if case .running = sessionState { return true }
        return false
    }

    // MARK: - Plan 04: camera-status refresh & request

    /// Re-read the (non-prompting) camera authorization status into `cameraStatus`.
    /// Call on menu/app activation so a change made in System Settings is reflected, fixing
    /// the never-updated-status bug. Also re-syncs the login-item toggle.
    func refreshCameraStatus() {
        refreshPermission()
        syncLaunchAtLogin()
    }

    /// Request camera access at an explicit user action (onboarding / menu CTA). On grant,
    /// auto-start if the user opted into starting on launch. Never called on app launch.
    func requestCameraAccess() async {
        let result = await permissionRequester()
        cameraStatus = result
        if result == .authorized {
            if settings.startWatchingOnLaunch {
                startWatching()
            }
        } else {
            sessionState = .noPermission(result)
        }
    }

    // MARK: - Plan 04: watch-level snooze

    /// Snooze *watching* for `minutes` (also quiets reminders). Surfaced in the menu as a
    /// "snoozed" state with auto-resume; distinct from a session pause.
    func snooze(for minutes: Int) {
        let until = now().addingTimeInterval(TimeInterval(minutes) * 60)
        snoozeUntil = until
        snoozeAlerts(minutes: minutes)
        scheduleSnoozeTimer(until: until)
    }

    /// Snooze until tomorrow at the active-hours start (or 9am if no schedule), capped so the
    /// menu's "until HH:mm" reads naturally.
    func snoozeUntilTomorrowMorning() {
        let calendar = Calendar.current
        let startMinutes = settings.scheduleEnabled ? settings.activeStartMinutes : 540
        guard
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now()),
            let target = calendar.date(
                bySettingHour: startMinutes / 60,
                minute: startMinutes % 60,
                second: 0,
                of: tomorrow
            )
        else { return }
        snoozeUntil = target
        let minutes = max(1, Int(target.timeIntervalSince(now()) / 60))
        snoozeAlerts(minutes: minutes)
        scheduleSnoozeTimer(until: target)
    }

    /// Resume watching/reminders immediately, cancelling any active snooze.
    func resume() {
        snoozeUntil = nil
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        resumeAlerts()
    }

    private func scheduleSnoozeTimer(until: Date) {
        snoozeTimer?.invalidate()
        let interval = max(1, until.timeIntervalSince(now()))
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.handleSnoozeExpiry() }
        }
    }

    /// Internal (not private) so tests can drive expiry through the injected clock.
    func handleSnoozeExpiry() {
        guard let until = snoozeUntil else { return }
        if until <= now() {
            resume()
        } else {
            // The one-shot timer fired marginally early — re-arm to the real deadline
            // instead of bailing and leaving snoozeUntil/snoozeTimer stale forever.
            scheduleSnoozeTimer(until: until)
        }
    }

    // MARK: - Plan 04: scheduling

    /// Whether watching is permitted by the active-hours schedule right now.
    /// Advisory — actually gating the camera session on boundaries is plan 02's concern;
    /// this drives the menu's `.outsideSchedule` state and "Watch anyway" override.
    var isWithinActiveHours: Bool {
        scheduleOverride || settings.activeSchedule.isActive(at: now())
    }

    /// Ignore the active-hours schedule until the next schedule boundary (menu "Watch anyway").
    /// Scoped, not permanent: ``handleScheduleBoundary()`` clears it so it doesn't bleed into
    /// future active/inactive windows.
    func overrideSchedule() {
        scheduleOverride = true
    }

    /// Recompute schedule-derived state when active-hours settings change.
    private func observeSchedule() {
        Publishers.Merge4(
            settings.$scheduleEnabled.map { _ in () },
            settings.$activeStartMinutes.map { _ in () },
            settings.$activeEndMinutes.map { _ in () },
            settings.$activeWeekdays.map { _ in () }
        )
        .sink { [weak self] in
            self?.objectWillChange.send()
            self?.scheduleBoundaryTimer()
        }
        .store(in: &cancellables)
    }

    /// The next instant the active-hours schedule could flip (next start or end time), or nil
    /// when scheduling is off. Pure given `now()` so it's unit-testable.
    ///
    /// Deliberately ignores `activeWeekdays`: on inactive days the timer fires as a no-op
    /// (≤2/day) and `effectiveState` recomputes through the weekday-aware
    /// `ActiveSchedule.isActive`, so the UI is always correct. Weekday-aware boundary math
    /// isn't worth the calendar complexity.
    func nextBoundaryDate() -> Date? {
        guard settings.scheduleEnabled else { return nil }
        let calendar = Calendar.current
        let reference = now()
        let candidates = [settings.activeStartMinutes, settings.activeEndMinutes]
        let times: [Date] = candidates.compactMap { minutes in
            guard let today = calendar.date(
                bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: reference
            ) else { return nil }
            return today > reference ? today : calendar.date(byAdding: .day, value: 1, to: today)
        }
        return times.min()
    }

    /// Arm a one-shot timer to the next schedule boundary so the menu re-renders when the
    /// active/inactive window flips (a computed `effectiveState` won't update on its own).
    private func scheduleBoundaryTimer() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        guard let next = nextBoundaryDate() else { return }
        let interval = max(1, next.timeIntervalSince(now()))
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.handleScheduleBoundary() }
        }
    }

    private func handleScheduleBoundary() {
        scheduleOverride = false   // a boundary passed; stop overriding the schedule
        objectWillChange.send()    // re-render the menu's computed effectiveState
        scheduleBoundaryTimer()    // arm the next boundary
    }

    /// Refresh the daily counter at the date rollover so a long-idle agent doesn't show a
    /// stale "N reminders today" across midnight.
    private func installDayRolloverObserver() {
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshTriggersToday() }
        }
    }

    // MARK: - Plan 04: effective watch state (drives the menu)

    /// A single, menu-friendly summary computed from camera status, watch intent, snooze, and
    /// the active-hours schedule.
    enum WatchState: Equatable {
        case watching
        case paused
        case snoozed(until: Date)
        case needsPermission
        case permissionDenied
        case noCamera
        case cameraError(reason: String)
        case outsideSchedule
    }

    /// The state the menu renders. Permission problems take precedence, then hard camera
    /// errors, then snooze, then the schedule, then watch intent. Keeping `.failed`/
    /// `.interrupted` here means the popover label/dot agree with `menuBarSymbolName`.
    var effectiveState: WatchState {
        switch cameraStatus {
        case .notDetermined:
            return .needsPermission
        case .denied, .restricted:
            return .permissionDenied
        case .authorized:
            break
        }
        switch sessionState {
        case .noDevice:
            return .noCamera
        case .failed(let message):
            return .cameraError(reason: message)
        case .interrupted(let reason):
            return .cameraError(reason: reason)
        default:
            break
        }
        if let until = snoozeUntil, until > now() {
            return .snoozed(until: until)
        }
        if !isWithinActiveHours {
            return .outsideSchedule
        }
        return isWatching ? .watching : .paused
    }

    // MARK: - Plan 04: daily stats

    /// Refresh `triggersToday` from the catch-stats store (called on each fire and on appear).
    func refreshTriggersToday() {
        triggersToday = stats.count(on: now())
    }

    // MARK: - Plan 04: launch-at-login sync

    /// Authoritatively re-read the login-item state from `SMAppService` and mirror it into
    /// settings, so a user toggling the item in System Settings is reflected in the UI.
    func syncLaunchAtLogin() {
        let enabled = (LaunchAtLogin.state == .enabled)
        if settings.launchAtLogin != enabled {
            settings.launchAtLogin = enabled
        }
    }

    // MARK: - Wiring

    private func wirePipeline() {
        // Mirror camera state into our published source of truth.
        camera.onStateChange = { [weak self] state in
            // `onStateChange` is documented to arrive on the main actor.
            MainActor.assumeIsolated {
                self?.apply(state)
            }
        }

        // Camera frames → detector. Detector ``DetectionResult`` → alerts.
        camera.onFrame = { [weak self] pixelBuffer, orientation in
            guard let self else { return }
            self.detector.process(pixelBuffer, orientation: orientation) { result in
                Task { @MainActor in
                    // Stash the current frame before handling so a synchronous fire can put it
                    // in the overlay (the pooled buffer is safe to cross queues).
                    self.latestFrame = (pixelBuffer, orientation)
                    self.alerts.handleDetection(result, cooldown: self.settings.cooldownSeconds)
                }
            }
        }
    }

    /// The detector config derived from both the sensitivity slider and the watched-gesture
    /// selection (disabled gestures are gated out by region).
    private func currentDetectorConfig() -> DetectorConfig {
        DetectorConfig.from(sensitivity: settings.sensitivity)
            .applying(gestures: settings.watchedGestures)
    }

    /// Rebuild the detector config whenever the sensitivity slider changes and push it onto
    /// the detection queue (the detector handles the cross-thread hop). Debounced: a slider
    /// drag emits many values per second and each rebuild is a queue hop + analyzer swap.
    private func observeSensitivity() {
        settings.$sensitivity
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.detector.updateConfig(self.currentDetectorConfig())
            }
            .store(in: &cancellables)
    }

    /// Rebuild the detector config when the watched-gesture selection changes, so disabling a
    /// gesture stops it firing live.
    private func observeWatchedGestures() {
        settings.$watchedGestures
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.detector.updateConfig(self.currentDetectorConfig())
            }
            .store(in: &cancellables)
    }

    /// Keep the alert manager's escalation toggle in sync with settings. The presenter reads
    /// the other alert-mode settings live on each fire, so they need no observer here.
    private func observeAlertSettings() {
        settings.$escalationEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.alerts.escalationEnabled = enabled }
            .store(in: &cancellables)
    }

    /// Apply a state transition reported by the camera, keeping `cameraStatus` consistent.
    private func apply(_ state: CameraSessionState) {
        sessionState = state
        switch state {
        case .noPermission(let status):
            cameraStatus = status
        case .running:
            cameraStatus = .authorized
        default:
            break
        }
    }
}

/// Stores SwiftUI's window actions so non-SwiftUI code (the `AppDelegate`) can open/close the
/// onboarding window. Populated from the menu content's `.onAppear` (plan 04 §3) — `openWindow`
/// is an `@Environment` value only available inside the view hierarchy.
@MainActor
final class WindowOpener {
    var open: ((String) -> Void)?
    var dismiss: ((String) -> Void)?

    func open(id: String) { open?(id) }
    func dismiss(id: String) { dismiss?(id) }
}
