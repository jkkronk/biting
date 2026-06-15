import XCTest
@testable import Shoo

/// Pure tests for ``ActiveSchedule/isActive(at:calendar:)`` — the scheduling core.
final class ActiveScheduleTests: XCTestCase {
    /// A fixed-offset (no-DST) calendar so weekday/hour/minute extraction is deterministic.
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Build a UTC date at the given weekday-anchored day with hour/minute.
    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        return calendar.date(from: comps)!
    }

    func testDisabledIsAlwaysActive() {
        let schedule = ActiveSchedule(enabled: false, weekdays: [], startMinutes: 0, endMinutes: 0)
        XCTAssertTrue(schedule.isActive(at: date(year: 2026, month: 6, day: 3, hour: 3, minute: 0), calendar: calendar))
    }

    func testNormalWindowInside() {
        // 2026-06-03 is a Wednesday. 09:00–17:00.
        let schedule = ActiveSchedule(enabled: true, weekdays: .all, startMinutes: 540, endMinutes: 1020)
        XCTAssertTrue(schedule.isActive(
            at: date(year: 2026, month: 6, day: 3, hour: 12, minute: 0), calendar: calendar))
    }

    func testNormalWindowOutside() {
        let schedule = ActiveSchedule(enabled: true, weekdays: .all, startMinutes: 540, endMinutes: 1020)
        XCTAssertFalse(schedule.isActive(
            at: date(year: 2026, month: 6, day: 3, hour: 8, minute: 0), calendar: calendar))
        XCTAssertFalse(schedule.isActive(
            at: date(year: 2026, month: 6, day: 3, hour: 17, minute: 0), calendar: calendar))
    }

    func testBoundaryMinutes() {
        let schedule = ActiveSchedule(enabled: true, weekdays: .all, startMinutes: 540, endMinutes: 1020)
        // Start is inclusive, end is exclusive.
        XCTAssertTrue(schedule.isActive(
            at: date(year: 2026, month: 6, day: 3, hour: 9, minute: 0), calendar: calendar))
        XCTAssertFalse(schedule.isActive(
            at: date(year: 2026, month: 6, day: 3, hour: 17, minute: 0), calendar: calendar))
    }

    func testOvernightWrap() {
        // 22:00 → 06:00.
        let schedule = ActiveSchedule(enabled: true, weekdays: .all, startMinutes: 1320, endMinutes: 360)
        XCTAssertTrue(schedule.isActive(
            at: date(year: 2026, month: 6, day: 3, hour: 23, minute: 0), calendar: calendar))
        XCTAssertTrue(schedule.isActive(
            at: date(year: 2026, month: 6, day: 3, hour: 2, minute: 0), calendar: calendar))
        XCTAssertFalse(schedule.isActive(
            at: date(year: 2026, month: 6, day: 3, hour: 12, minute: 0), calendar: calendar))
    }

    func testAllDayWhenStartEqualsEnd() {
        let schedule = ActiveSchedule(enabled: true, weekdays: .all, startMinutes: 0, endMinutes: 0)
        XCTAssertTrue(schedule.isActive(
            at: date(year: 2026, month: 6, day: 3, hour: 0, minute: 0), calendar: calendar))
        XCTAssertTrue(schedule.isActive(
            at: date(year: 2026, month: 6, day: 3, hour: 23, minute: 59), calendar: calendar))
    }

    func testWeekdayExclusion() {
        // Only weekdays (Mon–Fri); 2026-06-06 is a Saturday, 2026-06-03 a Wednesday.
        let schedule = ActiveSchedule(enabled: true, weekdays: .weekdays, startMinutes: 0, endMinutes: 0)
        XCTAssertTrue(schedule.isActive(
            at: date(year: 2026, month: 6, day: 3, hour: 12, minute: 0), calendar: calendar))
        XCTAssertFalse(schedule.isActive(
            at: date(year: 2026, month: 6, day: 6, hour: 12, minute: 0), calendar: calendar))
    }

    func testWeekdaySetContainsCalendarWeekday() {
        // Calendar: Sunday == 1 … Saturday == 7.
        XCTAssertTrue(WeekdaySet.sunday.contains(calendarWeekday: 1))
        XCTAssertTrue(WeekdaySet.saturday.contains(calendarWeekday: 7))
        XCTAssertFalse(WeekdaySet.weekdays.contains(calendarWeekday: 1))  // Sunday excluded
        XCTAssertTrue(WeekdaySet.weekdays.contains(calendarWeekday: 2))   // Monday included
        XCTAssertFalse(WeekdaySet.all.contains(calendarWeekday: 0))       // out of range
        XCTAssertFalse(WeekdaySet.all.contains(calendarWeekday: 8))       // out of range
    }

    func testDSTSpringForwardDay() {
        // 2026-03-08, US "spring forward" day. Use a DST-observing zone and confirm the
        // minutes-since-midnight comparison still classifies a mid-day time as in-window.
        var dstCal = Calendar(identifier: .gregorian)
        dstCal.timeZone = TimeZone(identifier: "America/New_York")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 8; comps.hour = 14; comps.minute = 0
        let afternoon = dstCal.date(from: comps)!
        let schedule = ActiveSchedule(enabled: true, weekdays: .all, startMinutes: 540, endMinutes: 1020)
        XCTAssertTrue(schedule.isActive(at: afternoon, calendar: dstCal))
    }
}
