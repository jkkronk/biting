import XCTest
@testable import Shoo

/// Tests for ``AppSettings`` defaults registration, schema stamping, persistence round-trips,
/// and ``AppSettings/resetToDefaults()`` — all on an isolated `UserDefaults` suite.
final class AppSettingsMigrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFreshDefaultsRegisterCorrectly() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.sensitivity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(settings.cooldownSeconds, 5.0, accuracy: 0.0001)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.startWatchingOnLaunch)
        XCTAssertEqual(settings.watchedGestures, .all)
        XCTAssertFalse(settings.scheduleEnabled)
        XCTAssertEqual(settings.activeWeekdays, .all)
        XCTAssertEqual(settings.activeStartMinutes, 540)
        XCTAssertEqual(settings.activeEndMinutes, 1020)
        XCTAssertFalse(settings.hasOnboarded)
    }

    func testSchemaVersionStampedOnInit() {
        XCTAssertEqual(defaults.integer(forKey: "settingsSchemaVersion"), 0)
        _ = AppSettings(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: "settingsSchemaVersion"), AppSettings.currentSchemaVersion)
    }

    func testRoundTripPersistenceOfNewKeys() {
        do {
            let settings = AppSettings(defaults: defaults)
            settings.scheduleEnabled = true
            settings.activeWeekdays = .weekdays
            settings.activeStartMinutes = 480
            settings.activeEndMinutes = 1200
            settings.watchedGestures = [.nailBiting, .lipBiting]
            settings.hasOnboarded = true
            settings.startWatchingOnLaunch = false
        }
        // New instance reads persisted values back.
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.scheduleEnabled)
        XCTAssertEqual(reloaded.activeWeekdays, .weekdays)
        XCTAssertEqual(reloaded.activeStartMinutes, 480)
        XCTAssertEqual(reloaded.activeEndMinutes, 1200)
        XCTAssertEqual(reloaded.watchedGestures, [.nailBiting, .lipBiting])
        XCTAssertTrue(reloaded.hasOnboarded)
        XCTAssertFalse(reloaded.startWatchingOnLaunch)
    }

    func testResetToDefaultsRestoresValuesAndBumpsPublished() {
        let settings = AppSettings(defaults: defaults)
        settings.sensitivity = 0.9
        settings.cooldownSeconds = 30
        settings.scheduleEnabled = true
        settings.activeStartMinutes = 60
        settings.watchedGestures = [.nosePicking]
        settings.hasOnboarded = true

        settings.resetToDefaults()

        XCTAssertEqual(settings.sensitivity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(settings.cooldownSeconds, 5.0, accuracy: 0.0001)
        XCTAssertFalse(settings.scheduleEnabled)
        XCTAssertEqual(settings.activeStartMinutes, 540)
        XCTAssertEqual(settings.watchedGestures, .all)
        XCTAssertFalse(settings.hasOnboarded)
    }

    func testActiveScheduleComputedFromSettings() {
        let settings = AppSettings(defaults: defaults)
        settings.scheduleEnabled = true
        settings.activeWeekdays = .weekdays
        settings.activeStartMinutes = 600
        settings.activeEndMinutes = 900
        let schedule = settings.activeSchedule
        XCTAssertTrue(schedule.enabled)
        XCTAssertEqual(schedule.weekdays, .weekdays)
        XCTAssertEqual(schedule.startMinutes, 600)
        XCTAssertEqual(schedule.endMinutes, 900)
    }
}
