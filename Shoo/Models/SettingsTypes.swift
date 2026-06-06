import Foundation

/// Pure value types backing ``AppSettings``. Deliberately free of AppKit/AVFoundation so
/// they stay trivially unit-testable (see `ActiveScheduleTests`).

/// How a fired reminder is surfaced. UI lives in plan 04's Settings; playback in plan 03.
///
/// Note: plan 03 models the alert channels as independent toggles
/// (`overlayEnabled`/`soundEnabled`/`notificationEnabled`) on ``AppSettings``. `AlertMode`
/// is a coarse, user-facing summary used by the menu/About copy; the underlying toggles
/// remain the source of truth for behavior.
enum AlertMode: String, CaseIterable, Identifiable {
    case overlay
    case overlayAndSound
    case silentBadge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overlay: return "Overlay"
        case .overlayAndSound: return "Overlay + Sound"
        case .silentBadge: return "Silent badge"
        }
    }
}

/// Which gesture types Shoo flags. Owned (semantically) by plan 01; stored/rendered here.
struct GestureMask: OptionSet {
    let rawValue: Int

    static let nailBiting   = GestureMask(rawValue: 1 << 0)
    static let nosePicking  = GestureMask(rawValue: 1 << 1)
    static let lipBiting    = GestureMask(rawValue: 1 << 2)
    static let hairPulling  = GestureMask(rawValue: 1 << 3)

    /// Every known gesture.
    static let all: GestureMask = [.nailBiting, .nosePicking, .lipBiting, .hairPulling]
}

/// A bitmask of weekdays (Sunday = bit 0 … Saturday = bit 6), matching `Calendar`'s
/// 1-based `weekday` component (Sunday == 1).
struct WeekdaySet: OptionSet {
    let rawValue: Int

    static let sunday    = WeekdaySet(rawValue: 1 << 0)
    static let monday    = WeekdaySet(rawValue: 1 << 1)
    static let tuesday   = WeekdaySet(rawValue: 1 << 2)
    static let wednesday = WeekdaySet(rawValue: 1 << 3)
    static let thursday  = WeekdaySet(rawValue: 1 << 4)
    static let friday    = WeekdaySet(rawValue: 1 << 5)
    static let saturday  = WeekdaySet(rawValue: 1 << 6)

    /// All seven days.
    static let all: WeekdaySet = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
    /// Monday…Friday.
    static let weekdays: WeekdaySet = [.monday, .tuesday, .wednesday, .thursday, .friday]

    /// Whether the set contains the given `Calendar` weekday component (1 = Sunday … 7 = Saturday).
    func contains(calendarWeekday weekday: Int) -> Bool {
        guard (1...7).contains(weekday) else { return false }
        return contains(WeekdaySet(rawValue: 1 << (weekday - 1)))
    }
}

/// A pure description of "active hours". The whole point of this type is its
/// ``isActive(at:calendar:)`` function — the unit-tested core of the scheduling feature.
struct ActiveSchedule: Equatable {
    var enabled: Bool
    var weekdays: WeekdaySet
    /// Minutes since local midnight (0…1439).
    var startMinutes: Int
    /// Minutes since local midnight (0…1439).
    var endMinutes: Int

    /// Whether watching is permitted at `date`.
    ///
    /// Uses minutes-since-midnight comparisons (never absolute-time arithmetic) so DST
    /// transitions and overnight windows behave correctly. Cases:
    /// - Disabled → always active.
    /// - Wrong weekday → inactive.
    /// - `start == end` → treated as "all day" (active the whole selected day).
    /// - `start < end` → active inside `[start, end)`.
    /// - `start > end` → overnight window: active in `[start, 1440) ∪ [0, end)`.
    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return true }

        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard
            let weekday = components.weekday,
            let hour = components.hour,
            let minute = components.minute
        else {
            return true  // fail-open: never block on a malformed calendar result
        }

        guard weekdays.contains(calendarWeekday: weekday) else { return false }

        let now = hour * 60 + minute
        if startMinutes == endMinutes {
            return true  // all-day window
        } else if startMinutes < endMinutes {
            return now >= startMinutes && now < endMinutes
        } else {
            // Overnight: e.g. 22:00 → 06:00.
            return now >= startMinutes || now < endMinutes
        }
    }
}
