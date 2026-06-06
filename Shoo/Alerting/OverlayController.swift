import AppKit
import SwiftUI

/// Hosts ``OverlayView`` in a single, retained borderless, non-activating, floating panel.
///
/// Fades in/out (window alpha + content scale), targets the screen under the mouse, floats
/// above full-screen apps, follows the user across Spaces, and never steals focus. The
/// panel is created lazily and reused between alerts so fade state is easy to manage.
@MainActor
final class OverlayController {
    /// Animation timings (seconds). `holdFor(level:)` derives the on-screen hold.
    private enum Timing {
        static let fadeIn: TimeInterval = 0.22
        static let fadeOut: TimeInterval = 0.30
        /// Reduced-motion cross-fade — short, no scale.
        static let reducedFade: TimeInterval = 0.12
        /// Extra hold for `.persistent` escalation.
        static let persistentExtra: TimeInterval = 1.0
    }

    /// Base hold time; updated from `AppSettings.displayDurationSeconds`.
    var displayDuration: TimeInterval = 2.5

    /// Whether the panel accepts clicks (driven from `clickToDismiss`). When false, clicks
    /// pass straight through to the app behind.
    var clickToDismiss: Bool = false {
        didSet { panel?.ignoresMouseEvents = !clickToDismiss }
    }

    /// Optional callbacks invoked from overlay affordances (click / ✕ / Snooze button).
    var onDismiss: (() -> Void)?
    var onSnooze: (() -> Void)?

    private var panel: NSPanel?
    private let model = OverlayModel()
    /// In-flight auto-dismiss; cancelled when a new alert arrives so re-fires don't dismiss
    /// the freshly-shown overlay.
    private var dismissTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    /// Bumped on every `show()`. A fade-out completion handler captures the value at dismiss
    /// time and bails if it changed, so a re-fire during the fade isn't hidden by the stale
    /// completion of the previous dismiss.
    private var generation = 0

    init() {
        // Re-center if the display arrangement changes while the panel is showing.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recenterIfVisible() }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: - Show / dismiss

    /// Show the reminder at the given escalation level, fading in and scheduling auto-dismiss.
    func show(level: EscalationLevel = .first) {
        let panel = ensurePanel()
        dismissTask?.cancel()
        generation &+= 1  // invalidate any pending fade-out completion from a prior dismiss

        positionOnTargetScreen(panel)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.reduceMotion = reduceMotion

        // Fresh cheeky line every appearance.
        model.message = StopMessages.random()

        // Window starts transparent; fade alpha to 1. Content scales up unless reduce-motion.
        panel.alphaValue = 0
        panel.orderFrontRegardless()  // never key/activates — no focus steal
        model.isVisible = false

        let fade = reduceMotion ? Timing.reducedFade : Timing.fadeIn
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        // Drive the SwiftUI content transition just after ordering in.
        model.isVisible = true

        scheduleDismiss(after: holdFor(level: level))
    }

    /// Fade the overlay out immediately (e.g. click-to-dismiss). Idempotent.
    func dismiss() {
        dismissTask?.cancel()
        guard let panel, panel.isVisible else { return }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.isVisible = false  // content scales/fades down
        let gen = generation

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? Timing.reducedFade : Timing.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            // If a newer show() ran during the fade, it bumped `generation` — don't hide the
            // freshly re-displayed overlay.
            guard let self, self.generation == gen else { return }
            panel?.alphaValue = 0
            panel?.orderOut(nil)
        }
    }

    // MARK: - Scheduling

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func holdFor(level: EscalationLevel) -> TimeInterval {
        switch level {
        case .first: return displayDuration
        case .persistent: return displayDuration + Timing.persistentExtra
        }
    }

    // MARK: - Panel lifecycle

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // `.screenSaver` reliably floats above full-screen apps while staying below the
        // actual screen saver / login window.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = !clickToDismiss
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let root = OverlayView(
            model: model,
            onDismiss: { [weak self] in self?.handleDismissTap() },
            onSnooze: { [weak self] in self?.handleSnoozeTap() }
        )
        panel.contentView = NSHostingView(rootView: root)
        self.panel = panel
        return panel
    }

    private func handleDismissTap() {
        onDismiss?()
        dismiss()
    }

    private func handleSnoozeTap() {
        onSnooze?()
        dismiss()
    }

    // MARK: - Multi-display targeting

    /// Pick the screen to show on at show time: the screen under the mouse, then
    /// `NSScreen.main`, then the first screen. Re-resolved on every show so display
    /// rearrangement is handled automatically.
    func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let underMouse = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return underMouse
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Center the panel within the target screen's `visibleFrame`, nudged ~8% above center
    /// so it sits slightly high (more glanceable) and clear of the menu bar.
    private func positionOnTargetScreen(_ panel: NSPanel) {
        guard let screen = targetScreen() else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        // Center, nudged ~8% high, then clamp so the panel stays fully on a short display.
        let rawX = frame.midX - size.width / 2
        let rawY = frame.midY - size.height / 2 + frame.height * 0.08
        let origin = NSPoint(
            x: min(max(rawX, frame.minX), max(frame.minX, frame.maxX - size.width)),
            y: min(max(rawY, frame.minY), max(frame.minY, frame.maxY - size.height))
        )
        panel.setFrameOrigin(origin)
    }

    /// Re-center onto a still-present screen if the arrangement changed mid-show.
    private func recenterIfVisible() {
        guard let panel, panel.isVisible else { return }
        positionOnTargetScreen(panel)
    }
}
