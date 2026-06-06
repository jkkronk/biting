import AppKit

/// What ``AlertManager`` calls to surface a reminder. Abstracted as a protocol so the state
/// machine can be unit-tested with a stub that records calls, while the real
/// ``AlertPresenter`` performs the AppKit side-effects.
@MainActor
protocol AlertPresenting: AnyObject {
    /// Surface a reminder at the given escalation level.
    func present(level: EscalationLevel)
    /// Dismiss the currently-showing reminder, if any.
    func dismiss()
}

/// Fans a fired alert out to every enabled mode (overlay / sound / notification) plus a
/// VoiceOver announcement. Reads ``AppSettings`` live so toggles take effect immediately.
///
/// `AlertManager` stays pure (no AppKit); all the side-effects live here.
@MainActor
final class AlertPresenter: AlertPresenting {
    private let settings: AppSettings
    private let overlay: OverlayController
    private let sound: SoundPlayer
    private let notifications: NotificationAlerter

    init(
        settings: AppSettings,
        overlay: OverlayController? = nil,
        sound: SoundPlayer? = nil,
        notifications: NotificationAlerter? = nil
    ) {
        self.settings = settings
        self.overlay = overlay ?? OverlayController()
        self.sound = sound ?? SoundPlayer()
        self.notifications = notifications ?? NotificationAlerter()
    }

    /// Wire overlay dismiss/snooze affordances back to the manager (set by ``AppState``).
    func bindOverlay(onDismiss: @escaping () -> Void, onSnooze: @escaping () -> Void) {
        overlay.onDismiss = onDismiss
        overlay.onSnooze = onSnooze
    }

    func present(level: EscalationLevel) {
        // Overlay (the core channel).
        if settings.overlayEnabled {
            overlay.displayDuration = settings.displayDurationSeconds
            overlay.clickToDismiss = settings.clickToDismiss
            overlay.show(level: level)
        }

        // Sound: on if enabled, or forced once by a `.persistent` escalation nudge.
        if settings.soundEnabled || level == .persistent {
            sound.play(named: settings.soundName)
        }

        // Optional banner (suppressed by Focus — acceptable; overlay is primary).
        if settings.notificationEnabled {
            notifications.post()
        }

        announce()
    }

    func dismiss() {
        overlay.dismiss()
    }

    /// Request notification authorization (called by plan 04's Settings when the user
    /// enables the toggle). Returns whether notifications are authorized afterward.
    @discardableResult
    func requestNotificationAuthorization() async -> Bool {
        await notifications.requestAuthorizationIfNeeded()
    }

    /// Post a high-priority VoiceOver announcement once per fire so VO users hear the
    /// reminder even though the overlay is a non-key window.
    private func announce() {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Stop. Hands away from your face.",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
