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

/// Seam over the overlay channel so ``AlertPresenter``'s fan-out logic is unit-testable
/// with a spy. ``OverlayController`` is the production conformance.
@MainActor
protocol OverlayPresenting: AnyObject {
    var displayDuration: TimeInterval { get set }
    var clickToDismiss: Bool { get set }
    var onDismiss: (() -> Void)? { get set }
    var onSnooze: (() -> Void)? { get set }
    func show(level: EscalationLevel, snapshot: NSImage?)
    func dismiss()
}

/// Seam over the sound channel. ``SoundPlayer`` is the production conformance.
@MainActor
protocol SoundPlaying: AnyObject {
    func play(named name: String)
}

/// Seam over the notification channel. ``NotificationAlerter`` is the production conformance.
@MainActor
protocol NotificationPosting: AnyObject {
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool
    func refreshAuthorization() async
    func post()
}

/// Fans a fired alert out to every enabled mode (overlay / sound / notification) plus a
/// VoiceOver announcement. Reads ``AppSettings`` live so toggles take effect immediately.
///
/// `AlertManager` stays pure (no AppKit); all the side-effects live here.
@MainActor
final class AlertPresenter: AlertPresenting {
    private let settings: AppSettings
    private let overlay: OverlayPresenting
    private let sound: SoundPlaying
    private let notifications: NotificationPosting

    init(
        settings: AppSettings,
        overlay: OverlayPresenting? = nil,
        sound: SoundPlaying? = nil,
        notifications: NotificationPosting? = nil
    ) {
        self.settings = settings
        self.overlay = overlay ?? OverlayController()
        self.sound = sound ?? SoundPlayer()
        self.notifications = notifications ?? NotificationAlerter()
    }

    /// Supplies the camera snapshot shown in the overlay, evaluated at present-time. Set by
    /// ``AppState``; returns nil when the snapshot setting is off or no frame is available.
    /// Kept off the ``AlertPresenting`` protocol so the test stub is unaffected.
    var snapshotProvider: (() -> NSImage?)?

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
            overlay.show(level: level, snapshot: snapshotProvider?())
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

    /// Refresh notification authorization without prompting (called at launch).
    func refreshNotificationAuthorization() async {
        await notifications.refreshAuthorization()
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
