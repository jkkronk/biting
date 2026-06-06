import AppKit
import Combine
import Foundation

/// App-wide state and the glue that wires the detection pipeline together.
///
/// Owns the camera (behind the ``FrameSource`` seam), detector, alert manager, and the
/// ``PowerCoordinator``, and exposes a single `isWatching` switch that the menu-bar UI
/// toggles. Created once in ``ShooApp``.
@MainActor
final class AppState: ObservableObject {
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

    private let camera: FrameSource
    private let detector = HandFaceDetector()
    private let stats: CatchStatsStore
    private let presenter: AlertPresenter
    private let alerts: AlertManager
    private let power: PowerCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var foregroundWindowObserver: NSObjectProtocol?
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

    init(frameSource: FrameSource = CameraController()) {
        self.camera = frameSource
        self.power = PowerCoordinator(frameSource: frameSource)
        // Alerting layer: shared clock keeps the state machine and stats in lock-step.
        let clock: () -> Date = { Date() }
        let stats = CatchStatsStore(clock: clock)
        let presenter = AlertPresenter(settings: settings)
        self.stats = stats
        self.presenter = presenter
        self.alerts = AlertManager(presenter: presenter, stats: stats, clock: clock)
        self.alerts.escalationEnabled = settings.escalationEnabled
        wirePipeline()
        // Overlay dismiss/snooze affordances loop back to the manager.
        presenter.bindOverlay(
            onDismiss: { [weak self] in self?.alerts.dismiss() },
            onSnooze: { [weak self] in self?.alerts.snooze(minutes: 5) }
        )
        // Push the initial sensitivity-derived config and keep it in sync thereafter.
        detector.updateConfig(DetectorConfig.from(sensitivity: settings.sensitivity))
        observeSensitivity()
        observeAlertSettings()
        // Keep the menu's "reminders today" counter fresh.
        self.alerts.onFire = { [weak self] in self?.refreshTriggersToday() }
        refreshTriggersToday()
        // Reflect the real login-item state (it can desync from settings via System Settings).
        syncLaunchAtLogin()
        installForegroundWindowObserver()
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
        isWatching ? stopWatching() : startWatching()
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
            if isWatching {
                isWatching = false
                sessionState = .noPermission(current)
            } else if case .running = sessionState {
                sessionState = .noPermission(current)
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
        let until = Date().addingTimeInterval(TimeInterval(minutes) * 60)
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
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()),
            let target = calendar.date(
                bySettingHour: startMinutes / 60,
                minute: startMinutes % 60,
                second: 0,
                of: tomorrow
            )
        else { return }
        snoozeUntil = target
        let minutes = max(1, Int(target.timeIntervalSinceNow / 60))
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
        let interval = max(1, until.timeIntervalSinceNow)
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.handleSnoozeExpiry() }
        }
    }

    private func handleSnoozeExpiry() {
        guard let until = snoozeUntil, until <= Date() else { return }
        resume()
    }

    // MARK: - Plan 04: scheduling

    /// Whether watching is permitted by the active-hours schedule right now.
    /// Advisory — actually gating the camera session on boundaries is plan 02's concern;
    /// this drives the menu's `.outsideSchedule` state and "Watch anyway" override.
    var isWithinActiveHours: Bool {
        scheduleOverride || settings.activeSchedule.isActive(at: Date())
    }

    /// Ignore the active-hours schedule until the next launch (menu "Watch anyway").
    func overrideSchedule() {
        scheduleOverride = true
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
        case outsideSchedule
    }

    /// The state the menu renders. Permission problems take precedence, then snooze, then the
    /// schedule, then watch intent.
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
        default:
            break
        }
        if let until = snoozeUntil, until > Date() {
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
        triggersToday = stats.count(on: Date())
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

    private var snoozeTimer: Timer?

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
                    self.alerts.handleDetection(result, cooldown: self.settings.cooldownSeconds)
                }
            }
        }
    }

    /// Rebuild the detector config whenever the sensitivity slider changes and push it onto
    /// the detection queue (the detector handles the cross-thread hop).
    private func observeSensitivity() {
        settings.$sensitivity
            .removeDuplicates()
            .sink { [weak self] sensitivity in
                self?.detector.updateConfig(DetectorConfig.from(sensitivity: sensitivity))
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
