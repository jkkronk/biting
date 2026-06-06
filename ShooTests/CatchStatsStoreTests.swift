import XCTest
@testable import Shoo

/// Verifies the per-day catch counter: increment, cross-midnight bucketing, 7-day ordering,
/// pruning, and `UserDefaults` JSON round-tripping — all with an injected clock.
@MainActor
final class CatchStatsStoreTests: XCTestCase {
    private var now = Date(timeIntervalSinceReferenceDate: 0)
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        now = Date(timeIntervalSinceReferenceDate: 0)
        suiteName = "CatchStatsStoreTests-\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> CatchStatsStore {
        CatchStatsStore(defaults: defaults, key: "catchStats", clock: { [unowned self] in self.now })
    }

    func testRecordCatchIncrementsToday() {
        let store = makeStore()
        XCTAssertEqual(store.count(on: now), 0)
        store.recordCatch()
        store.recordCatch()
        XCTAssertEqual(store.count(on: now), 2)
    }

    func testCrossMidnightCreatesNewBucket() {
        let store = makeStore()
        store.recordCatch()
        let day1 = now
        now = now.addingTimeInterval(24 * 60 * 60)  // next day
        store.recordCatch()
        XCTAssertEqual(store.count(on: day1), 1)
        XCTAssertEqual(store.count(on: now), 1)
    }

    func testLast7DaysOrderingOldestToNewest() {
        let store = makeStore()
        store.recordCatch()  // today
        now = now.addingTimeInterval(24 * 60 * 60)
        store.recordCatch()
        store.recordCatch()  // tomorrow: 2

        let week = store.last7Days()
        XCTAssertEqual(week.count, 7)
        // Last entry is "today" (the latest clock value) with 2 catches.
        XCTAssertEqual(week.last?.count, 2)
        // The day before has 1.
        XCTAssertEqual(week[week.count - 2].count, 1)
        // Earlier days are zero.
        XCTAssertEqual(week.first?.count, 0)
    }

    func testPrunesEntriesOlderThanRetention() {
        let store = makeStore()
        store.recordCatch()  // old entry
        let oldDay = now
        // Advance well past the retention window, then record again (triggers prune on write).
        now = now.addingTimeInterval(TimeInterval(CatchStatsStore.retentionDays + 5) * 24 * 60 * 60)
        store.recordCatch()
        XCTAssertEqual(store.count(on: oldDay), 0, "entries older than retention should be pruned")
        XCTAssertEqual(store.count(on: now), 1)
    }

    func testRoundTripsThroughUserDefaults() {
        let store = makeStore()
        store.recordCatch()
        store.recordCatch()

        // A fresh store reading the same defaults sees the persisted data.
        let reopened = makeStore()
        XCTAssertEqual(reopened.count(on: now), 2)
    }
}
