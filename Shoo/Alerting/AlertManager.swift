import Foundation

/// How firmly a reminder is presented. `.persistent` is a gentle nudge up after the user
/// has ignored a first reminder and kept touching across cooldown cycles — never an alarm.
enum EscalationLevel: Equatable {
    case first
    case persistent
}

/// The ``AlertManager`` state machine's current mode.
enum AlertState: Equatable {
    /// Watching, nothing pending.
    case idle
    /// Consecutive positive frames accumulating toward `requiredSustainedHits`.
    case arming(hits: Int)
    /// An alert just fired; suppress new alerts until `until`.
    case cooldown(until: Date, level: EscalationLevel)
    /// User asked for quiet; positive frames ignored until `until`.
    case snoozed(until: Date)
    /// Alerts off (distinct from camera off); positive frames ignored until `resume()`.
    case paused
}

/// Turns the detector's per-frame ``DetectionResult`` into user-facing reminders.
///
/// A clearly-specified state machine (see ``AlertState``) with sustained-frame hysteresis on
/// both edges, a per-fire cooldown, snooze-for-N-minutes, pause, and gentle escalation. Pure
/// timing logic (no AppKit) with an injectable clock so it is fully unit-testable; all
/// side-effects go through an ``AlertPresenting`` and a ``CatchStatsStore``.
@MainActor
final class AlertManager {
    /// Consecutive positive frames required before firing.
    var requiredSustainedHits: Int = 3
    /// Consecutive `false` frames required to fully clear `arming` — absorbs a one-frame
    /// detection dropout mid-touch so the counter doesn't reset spuriously.
    var releaseFrames: Int = 2
    /// Whether to escalate to `.persistent` when the behavior persists across cycles.
    var escalationEnabled: Bool = true
    /// How many ignored cooldown cycles (the user kept touching) before escalating.
    var escalationThreshold: Int = 2

    /// Current machine state (read-only to callers; useful for the menu / tests).
    private(set) var state: AlertState = .idle

    /// Invoked on the main actor each time a reminder actually fires, so ``AppState`` can
    /// refresh its "reminders today" counter (plan 04's menu stats). Optional.
    var onFire: (() -> Void)?

    private let presenter: AlertPresenting
    private let stats: CatchStatsStore
    private let clock: () -> Date

    /// Trailing-edge hysteresis: consecutive misses seen while arming.
    private var missStreak = 0
    /// Consecutive cooldown cycles the user kept touching through; drives escalation.
    private var ignoredCycles = 0

    init(
        presenter: AlertPresenting,
        stats: CatchStatsStore,
        clock: @escaping () -> Date = Date.init
    ) {
        self.presenter = presenter
        self.stats = stats
        self.clock = clock
    }

    // MARK: - Frame input

    /// Feed a single detection result. `cooldown` is read from settings each call so the
    /// slider takes effect live.
    func handleDetection(_ result: DetectionResult, cooldown: TimeInterval) {
        let now = clock()
        expireTimedStates(now: now)

        switch state {
        case .paused:
            return  // ignore all frames until resume()

        case .snoozed:
            return  // expireTimedStates handles the transition back to .idle

        case .idle, .arming:
            handleArming(result.isContact, now: now, cooldown: cooldown)

        case .cooldown(let until, let level):
            handleCooldown(result.isContact, now: now, until: until, level: level, cooldown: cooldown)
        }
    }

    /// Advance time-based transitions without a new frame (e.g. from a UI timer or when
    /// watching stops mid-cooldown): snooze expiry → `.idle`, and an elapsed cooldown →
    /// `.idle` so the machine doesn't stay stuck in `.cooldown` once frames stop arriving.
    func tick(now: Date? = nil) {
        let t = now ?? clock()
        expireTimedStates(now: t)
        if case .cooldown(let until, _) = state, t >= until {
            state = .idle
            resetArming()
        }
    }

    // MARK: - UI controls

    /// Quiet all reminders for `minutes`; positive frames are ignored entirely until expiry.
    func snooze(minutes: Int) {
        let until = clock().addingTimeInterval(TimeInterval(minutes) * 60)
        state = .snoozed(until: until)
        resetArming()
        ignoredCycles = 0
        presenter.dismiss()
        AppLogger.alerting.info("Snoozed for \(minutes) min")
    }

    /// Dismiss the currently-showing overlay without changing cooldown/state.
    func dismiss() {
        presenter.dismiss()
    }

    /// Turn reminders off (distinct from stopping the camera) until ``resume()``.
    func pause() {
        state = .paused
        resetArming()
        ignoredCycles = 0
        presenter.dismiss()
        AppLogger.alerting.info("Reminders paused")
    }

    /// Re-enable reminders after ``pause()`` / a snooze.
    func resume() {
        state = .idle
        resetArming()
        AppLogger.alerting.info("Reminders resumed")
    }

    /// Whether reminders are currently suppressed (paused or snoozed). For menu status.
    var isSuppressed: Bool {
        switch state {
        case .paused, .snoozed: return true
        default: return false
        }
    }

    /// When a snooze expires, if any. Lets the menu show "Snoozed until 3:42".
    var snoozedUntil: Date? {
        if case .snoozed(let until) = state { return until }
        return nil
    }

    /// Fire a `.first`-level reminder immediately. Exposed for a debug menu item.
    func fire() {
        fireAlert(level: .first, now: clock(), cooldown: 0)
    }

    // MARK: - Transitions

    private func handleArming(_ contact: Bool, now: Date, cooldown: TimeInterval) {
        guard contact else {
            // Trailing-edge hysteresis: only reset after `releaseFrames` consecutive misses.
            missStreak += 1
            if missStreak >= releaseFrames {
                resetArming()
                state = .idle
                ignoredCycles = 0  // a clean release resets escalation
            }
            return
        }

        missStreak = 0
        let hits = currentHits + 1
        if hits >= requiredSustainedHits {
            fireAlert(level: .first, now: now, cooldown: cooldown)
        } else {
            state = .arming(hits: hits)
        }
    }

    private func handleCooldown(
        _ contact: Bool,
        now: Date,
        until: Date,
        level: EscalationLevel,
        cooldown: TimeInterval
    ) {
        guard now >= until else {
            // Still cooling down. Track whether the user is persisting through the cycle.
            if contact { missStreak = 0 } else { missStreak += 1 }
            return
        }

        // Cooldown elapsed.
        guard contact else {
            // Behavior stopped — require a clean release before re-arming.
            missStreak += 1
            if missStreak >= releaseFrames {
                resetArming()
                state = .idle
                ignoredCycles = 0
            }
            return
        }

        // Still touching after the cooldown → the first reminder was ignored. Re-fire,
        // escalating if the behavior has persisted across enough cycles.
        ignoredCycles += 1
        let nextLevel: EscalationLevel = (escalationEnabled && ignoredCycles >= escalationThreshold)
            ? .persistent
            : level
        fireAlert(level: nextLevel, now: now, cooldown: cooldown)
    }

    /// Fire: present, record a catch, and enter cooldown.
    private func fireAlert(level: EscalationLevel, now: Date, cooldown: TimeInterval) {
        AppLogger.alerting.info("Firing stop reminder (level: \(String(describing: level), privacy: .public))")
        presenter.present(level: level)
        stats.recordCatch(at: now)
        onFire?()
        resetArming()
        state = .cooldown(until: now.addingTimeInterval(cooldown), level: level)
    }

    /// Expire snooze (→ idle, clearing escalation). Cooldown expiry is intentionally NOT done
    /// here: this runs on every frame, and the frame-driven `handleCooldown` needs to see the
    /// still-`.cooldown` state to drive re-fire/escalation. The no-frame cooldown drain lives
    /// in `tick()`.
    private func expireTimedStates(now: Date) {
        if case .snoozed(let until) = state, now >= until {
            state = .idle
            resetArming()
            ignoredCycles = 0  // a completed snooze clears escalation
        }
    }

    private var currentHits: Int {
        if case .arming(let hits) = state { return hits }
        return 0
    }

    private func resetArming() {
        missStreak = 0
        if case .arming = state { state = .arming(hits: 0) }
    }
}
