import AppKit
import XCTest
@testable import Shoo

/// Spies for the three alert channels so the fan-out logic is observable without AppKit
/// side-effects (no real panel, sound, or notification center).
@MainActor
private final class SpyOverlay: OverlayPresenting {
    var displayDuration: TimeInterval = 0
    var clickToDismiss = false
    var onDismiss: (() -> Void)?
    var onSnooze: (() -> Void)?
    private(set) var shown: [(level: EscalationLevel, snapshot: NSImage?)] = []
    private(set) var dismissCount = 0

    func show(level: EscalationLevel, snapshot: NSImage?) {
        shown.append((level, snapshot))
    }

    func dismiss() { dismissCount += 1 }
}

@MainActor
private final class SpySound: SoundPlaying {
    private(set) var played: [String] = []
    func play(named name: String) { played.append(name) }
}

@MainActor
private final class SpyNotifications: NotificationPosting {
    private(set) var postCount = 0
    func requestAuthorizationIfNeeded() async -> Bool { true }
    func refreshAuthorization() async {}
    func post() { postCount += 1 }
}

/// ``AlertPresenter`` fan-out: each channel fires iff its toggle is on (read live from
/// settings), `.persistent` escalation forces the sound nudge, and the overlay receives the
/// current display-duration / click-to-dismiss / snapshot on every present.
@MainActor
final class AlertPresenterTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AlertPresenterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // Test factory returning the SUT and its four spies.
    // swiftlint:disable:next large_tuple
    private func make() -> (AlertPresenter, AppSettings, SpyOverlay, SpySound, SpyNotifications) {
        let settings = AppSettings(defaults: defaults)
        let overlay = SpyOverlay()
        let sound = SpySound()
        let notifications = SpyNotifications()
        let presenter = AlertPresenter(
            settings: settings, overlay: overlay, sound: sound, notifications: notifications)
        return (presenter, settings, overlay, sound, notifications)
    }

    func testDefaultsFireOverlayOnly() {
        let (presenter, _, overlay, sound, notifications) = make()

        presenter.present(level: .first)

        // Registered defaults: overlay on, sound off, notification off.
        XCTAssertEqual(overlay.shown.count, 1)
        XCTAssertEqual(overlay.shown.first?.level, .first)
        XCTAssertTrue(sound.played.isEmpty)
        XCTAssertEqual(notifications.postCount, 0)
    }

    func testOverlayDisabledSuppressesOverlay() {
        let (presenter, settings, overlay, _, _) = make()
        settings.overlayEnabled = false

        presenter.present(level: .first)

        XCTAssertTrue(overlay.shown.isEmpty)
    }

    func testOverlayReceivesLiveTimingAndClickSettings() {
        let (presenter, settings, overlay, _, _) = make()
        settings.displayDurationSeconds = 7.5
        settings.clickToDismiss = true

        presenter.present(level: .first)

        XCTAssertEqual(overlay.displayDuration, 7.5, accuracy: 0.0001)
        XCTAssertTrue(overlay.clickToDismiss)

        // Settings are re-read on each present, not cached.
        settings.displayDurationSeconds = 3.0
        settings.clickToDismiss = false
        presenter.present(level: .first)

        XCTAssertEqual(overlay.displayDuration, 3.0, accuracy: 0.0001)
        XCTAssertFalse(overlay.clickToDismiss)
    }

    func testSoundPlaysWhenEnabled() {
        let (presenter, settings, _, sound, _) = make()
        settings.soundEnabled = true
        settings.soundName = "Pop"

        presenter.present(level: .first)

        XCTAssertEqual(sound.played, ["Pop"])
    }

    func testPersistentEscalationForcesSoundEvenWhenDisabled() {
        let (presenter, settings, _, sound, _) = make()
        settings.soundEnabled = false

        presenter.present(level: .persistent)

        XCTAssertEqual(sound.played.count, 1)
    }

    func testNotificationPostsOnlyWhenEnabled() {
        let (presenter, settings, _, _, notifications) = make()

        presenter.present(level: .first)
        XCTAssertEqual(notifications.postCount, 0)

        settings.notificationEnabled = true
        presenter.present(level: .first)
        XCTAssertEqual(notifications.postCount, 1)
    }

    func testSnapshotProviderResultReachesOverlay() {
        let (presenter, _, overlay, _, _) = make()
        let image = NSImage(size: NSSize(width: 1, height: 1))
        presenter.snapshotProvider = { image }

        presenter.present(level: .first)

        XCTAssertIdentical(overlay.shown.first?.snapshot, image)
    }

    func testDismissForwardsToOverlay() {
        let (presenter, _, overlay, _, _) = make()

        presenter.dismiss()

        XCTAssertEqual(overlay.dismissCount, 1)
    }

    func testBindOverlayWiresCallbacks() {
        let (presenter, _, overlay, _, _) = make()
        var dismissed = false
        var snoozed = false

        presenter.bindOverlay(onDismiss: { dismissed = true }, onSnooze: { snoozed = true })
        overlay.onDismiss?()
        overlay.onSnooze?()

        XCTAssertTrue(dismissed)
        XCTAssertTrue(snoozed)
    }
}
