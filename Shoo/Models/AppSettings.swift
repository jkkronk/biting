import Combine
import Foundation

/// User preferences, persisted in `UserDefaults`.
///
/// Named `AppSettings` (not `Settings`) to avoid colliding with SwiftUI's `Settings`
/// scene. An `ObservableObject` so it can be shared through ``AppState`` and observed
/// by the menu, settings, and onboarding windows — one source of truth across scenes,
/// which also centralizes migration (see ``migrateIfNeeded()``).
///
/// `@MainActor`: all real call sites (``AppState``, the SwiftUI views, ``AlertPresenter``)
/// are main-actor already; the annotation makes that a compiler guarantee so a future
/// background mutation can't race the `didSet` UserDefaults writes.
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let sensitivity = "sensitivity"
        static let cooldownSeconds = "cooldownSeconds"
        static let launchAtLogin = "launchAtLogin"
        // Alert-mode keys (plan 03).
        static let overlayEnabled = "overlayEnabled"
        static let soundEnabled = "soundEnabled"
        static let soundName = "soundName"
        static let notificationEnabled = "notificationEnabled"
        static let clickToDismiss = "clickToDismiss"
        static let escalationEnabled = "escalationEnabled"
        static let displayDurationSeconds = "displayDurationSeconds"
        static let snapshotInReminderEnabled = "snapshotInReminderEnabled"
        // Plan 04: start/onboarding/gestures/schedule.
        static let startWatchingOnLaunch = "startWatchingOnLaunch"
        static let watchedGestures = "watchedGestures"
        static let scheduleEnabled = "scheduleEnabled"
        static let activeWeekdays = "activeWeekdays"
        static let activeStartMinutes = "activeStartMinutes"
        static let activeEndMinutes = "activeEndMinutes"
        static let hasOnboarded = "hasOnboarded"
        static let settingsSchemaVersion = "settingsSchemaVersion"

        /// The keys ``resetToDefaults()`` clears so registered defaults shine back through.
        /// Deliberately excludes `settingsSchemaVersion` (a migration anchor, not a preference).
        static let managed: [String] = [
            sensitivity, cooldownSeconds, launchAtLogin,
            overlayEnabled, soundEnabled, soundName, notificationEnabled,
            clickToDismiss, escalationEnabled, displayDurationSeconds,
            snapshotInReminderEnabled,
            startWatchingOnLaunch, watchedGestures,
            scheduleEnabled, activeWeekdays, activeStartMinutes, activeEndMinutes,
            hasOnboarded,
        ]
    }

    /// Bump when adding/renaming keys and add a matching migration step in ``migrateIfNeeded()``.
    static let currentSchemaVersion = 1

    private let defaults: UserDefaults

    /// Defaults registered with `UserDefaults` so a fresh install and an upgrade behave
    /// identically. Centralized so ``resetToDefaults()`` can re-read after clearing.
    private static let registeredDefaults: [String: Any] = [
        Keys.sensitivity: 0.5,
        Keys.cooldownSeconds: 5.0,
        Keys.launchAtLogin: false,
        Keys.overlayEnabled: true,
        Keys.soundEnabled: false,
        Keys.soundName: "Pop",
        Keys.notificationEnabled: false,
        Keys.clickToDismiss: false,
        Keys.escalationEnabled: true,
        Keys.displayDurationSeconds: 2.5,
        Keys.snapshotInReminderEnabled: true,
        Keys.startWatchingOnLaunch: true,
        Keys.watchedGestures: GestureMask.all.rawValue,
        Keys.scheduleEnabled: false,
        Keys.activeWeekdays: WeekdaySet.all.rawValue,
        Keys.activeStartMinutes: 540,   // 09:00
        Keys.activeEndMinutes: 1020,    // 17:00
        Keys.hasOnboarded: false,
    ]

    /// 0…1, mapped to a ``DetectorConfig`` via `DetectorConfig.from(sensitivity:)`
    /// (higher = triggers earlier/easier). Pushed into the detector by ``AppState``.
    @Published var sensitivity: Double {
        didSet { defaults.set(sensitivity, forKey: Keys.sensitivity) }
    }

    /// Minimum seconds between reminders.
    @Published var cooldownSeconds: Double {
        didSet { defaults.set(cooldownSeconds, forKey: Keys.cooldownSeconds) }
    }

    /// Whether the app registers as a login item. Mirrors `SMAppService` status; kept in sync
    /// by ``AppState`` (see plan 04 §5).
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    // MARK: - Alert modes (plan 03)

    /// The core mode: the centered overlay reminder. On by default.
    @Published var overlayEnabled: Bool {
        didSet { defaults.set(overlayEnabled, forKey: Keys.overlayEnabled) }
    }

    /// Play a short system sound on each reminder. Off by default — a menu-bar agent
    /// should stay quiet unless the user opts in.
    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    /// Named system sound (`NSSound(named:)`); falls back to `NSSound.beep()` if invalid.
    /// Persisted for forward-compat but deliberately has no Settings UI — there is exactly
    /// one shipped sound; add a picker only when there is more than one.
    @Published var soundName: String {
        didSet { defaults.set(soundName, forKey: Keys.soundName) }
    }

    /// Post a `UNUserNotifications` banner on each reminder. Requires runtime
    /// authorization; off by default.
    @Published var notificationEnabled: Bool {
        didSet { defaults.set(notificationEnabled, forKey: Keys.notificationEnabled) }
    }

    /// When on, the overlay accepts clicks and a click dismisses it (otherwise clicks
    /// pass through to the app behind).
    @Published var clickToDismiss: Bool {
        didSet { defaults.set(clickToDismiss, forKey: Keys.clickToDismiss) }
    }

    /// Gentle escalation when the behavior persists across cooldown cycles. On by default.
    @Published var escalationEnabled: Bool {
        didSet { defaults.set(escalationEnabled, forKey: Keys.escalationEnabled) }
    }

    /// How long the overlay holds before fading out (seconds).
    @Published var displayDurationSeconds: Double {
        didSet { defaults.set(displayDurationSeconds, forKey: Keys.displayDurationSeconds) }
    }

    /// Show a small camera snapshot in the reminder overlay (instead of the ✋ icon). On by
    /// default; the snapshot is transient and never persisted.
    @Published var snapshotInReminderEnabled: Bool {
        didSet { defaults.set(snapshotInReminderEnabled, forKey: Keys.snapshotInReminderEnabled) }
    }

    // MARK: - Start / onboarding / gestures (plan 04)

    /// Auto-start watching on launch (and after onboarding) when authorized. On by default;
    /// behavior owned by plan 02.
    @Published var startWatchingOnLaunch: Bool {
        didSet { defaults.set(startWatchingOnLaunch, forKey: Keys.startWatchingOnLaunch) }
    }

    /// Which gesture types to flag (semantics owned by plan 01). Stored as the option-set raw.
    @Published var watchedGestures: GestureMask {
        didSet { defaults.set(watchedGestures.rawValue, forKey: Keys.watchedGestures) }
    }

    /// Whether first-run onboarding has completed. Gates the onboarding window.
    @Published var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Keys.hasOnboarded) }
    }

    // MARK: - Active hours / scheduling (plan 04)

    /// Master switch for active-hours scheduling. Off by default.
    @Published var scheduleEnabled: Bool {
        didSet { defaults.set(scheduleEnabled, forKey: Keys.scheduleEnabled) }
    }

    /// Weekdays the schedule is active (bitmask, Sun…Sat).
    @Published var activeWeekdays: WeekdaySet {
        didSet { defaults.set(activeWeekdays.rawValue, forKey: Keys.activeWeekdays) }
    }

    /// Daily window start, minutes since local midnight.
    @Published var activeStartMinutes: Int {
        didSet { defaults.set(activeStartMinutes, forKey: Keys.activeStartMinutes) }
    }

    /// Daily window end, minutes since local midnight.
    @Published var activeEndMinutes: Int {
        didSet { defaults.set(activeEndMinutes, forKey: Keys.activeEndMinutes) }
    }

    /// The four schedule properties assembled into the pure ``ActiveSchedule`` so callers
    /// (e.g. ``AppState``) can evaluate `isActive(at:)` without reaching into UserDefaults.
    var activeSchedule: ActiveSchedule {
        ActiveSchedule(
            enabled: scheduleEnabled,
            weekdays: activeWeekdays,
            startMinutes: activeStartMinutes,
            endMinutes: activeEndMinutes
        )
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Self.registeredDefaults)

        self.sensitivity = defaults.double(forKey: Keys.sensitivity)
        self.cooldownSeconds = defaults.double(forKey: Keys.cooldownSeconds)
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.overlayEnabled = defaults.bool(forKey: Keys.overlayEnabled)
        self.soundEnabled = defaults.bool(forKey: Keys.soundEnabled)
        self.soundName = defaults.string(forKey: Keys.soundName) ?? "Pop"
        self.notificationEnabled = defaults.bool(forKey: Keys.notificationEnabled)
        self.clickToDismiss = defaults.bool(forKey: Keys.clickToDismiss)
        self.escalationEnabled = defaults.bool(forKey: Keys.escalationEnabled)
        self.displayDurationSeconds = defaults.double(forKey: Keys.displayDurationSeconds)
        self.snapshotInReminderEnabled = defaults.bool(forKey: Keys.snapshotInReminderEnabled)
        self.startWatchingOnLaunch = defaults.bool(forKey: Keys.startWatchingOnLaunch)
        self.watchedGestures = GestureMask(rawValue: defaults.integer(forKey: Keys.watchedGestures))
        self.hasOnboarded = defaults.bool(forKey: Keys.hasOnboarded)
        self.scheduleEnabled = defaults.bool(forKey: Keys.scheduleEnabled)
        self.activeWeekdays = WeekdaySet(rawValue: defaults.integer(forKey: Keys.activeWeekdays))
        self.activeStartMinutes = defaults.integer(forKey: Keys.activeStartMinutes)
        self.activeEndMinutes = defaults.integer(forKey: Keys.activeEndMinutes)

        migrateIfNeeded()
    }

    // MARK: - Versioning & migration

    /// Run ordered schema migrations, then stamp the current version.
    ///
    /// Pattern for future renames: in the relevant `migrateVXtoVY()` step, copy the old key
    /// onto the new one, reassign the `@Published` property, then `defaults.removeObject` the
    /// old key — all *before* stamping the new version.
    private func migrateIfNeeded() {
        let storedVersion = defaults.integer(forKey: Keys.settingsSchemaVersion)  // 0 if never set
        guard storedVersion < Self.currentSchemaVersion else { return }

        if storedVersion < 1 {
            migrateV0toV1()
        }

        defaults.set(Self.currentSchemaVersion, forKey: Keys.settingsSchemaVersion)
    }

    /// v0 → v1: no data change today; establishes the migration hook and stamps the version.
    private func migrateV0toV1() {
        // Intentionally empty. Future: copy/rename legacy keys here.
    }

    // MARK: - Reset

    /// Restore documented defaults: clear the managed keys so registered fallbacks shine
    /// through, then re-read and reassign every `@Published` so observers (the UI) refresh.
    func resetToDefaults() {
        for key in Keys.managed {
            defaults.removeObject(forKey: key)
        }
        sensitivity = defaults.double(forKey: Keys.sensitivity)
        cooldownSeconds = defaults.double(forKey: Keys.cooldownSeconds)
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        overlayEnabled = defaults.bool(forKey: Keys.overlayEnabled)
        soundEnabled = defaults.bool(forKey: Keys.soundEnabled)
        soundName = defaults.string(forKey: Keys.soundName) ?? "Pop"
        notificationEnabled = defaults.bool(forKey: Keys.notificationEnabled)
        clickToDismiss = defaults.bool(forKey: Keys.clickToDismiss)
        escalationEnabled = defaults.bool(forKey: Keys.escalationEnabled)
        displayDurationSeconds = defaults.double(forKey: Keys.displayDurationSeconds)
        snapshotInReminderEnabled = defaults.bool(forKey: Keys.snapshotInReminderEnabled)
        startWatchingOnLaunch = defaults.bool(forKey: Keys.startWatchingOnLaunch)
        watchedGestures = GestureMask(rawValue: defaults.integer(forKey: Keys.watchedGestures))
        hasOnboarded = defaults.bool(forKey: Keys.hasOnboarded)
        scheduleEnabled = defaults.bool(forKey: Keys.scheduleEnabled)
        activeWeekdays = WeekdaySet(rawValue: defaults.integer(forKey: Keys.activeWeekdays))
        activeStartMinutes = defaults.integer(forKey: Keys.activeStartMinutes)
        activeEndMinutes = defaults.integer(forKey: Keys.activeEndMinutes)
    }
}
