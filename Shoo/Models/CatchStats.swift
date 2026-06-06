import Foundation

/// A tiny, local-only tally of how many reminders fired per day, for a future stats view.
///
/// Counts only — no timestamps-of-day, no images — consistent with `docs/PRIVACY.md`.
/// Keyed by `"yyyy-MM-dd"` in the user-local calendar at record time.
struct CatchStats: Codable, Equatable {
    /// `"yyyy-MM-dd"` (user-local calendar) → number of fired alerts that day.
    var countsByDay: [String: Int]

    init(countsByDay: [String: Int] = [:]) {
        self.countsByDay = countsByDay
    }
}

/// Persists ``CatchStats`` as JSON in `UserDefaults` and exposes a small query API.
///
/// Increments today's bucket on each **fired** alert (escalation re-fires count once each;
/// arming frames never count). Prunes entries older than ~90 days on write to bound size.
/// The clock is injectable so it can share ``AlertManager``'s clock and stay testable.
@MainActor
final class CatchStatsStore {
    /// How many days of history we retain; older buckets are pruned on write.
    static let retentionDays = 90

    private let defaults: UserDefaults
    private let key: String
    private let clock: () -> Date

    /// `yyyy-MM-dd` in the user-local calendar — the bucket key format.
    private let dayFormatter: DateFormatter

    init(
        defaults: UserDefaults = .standard,
        key: String = "catchStats",
        clock: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.key = key
        self.clock = clock

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        formatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = formatter
    }

    // MARK: - Recording

    /// Increment the bucket for the given day (defaults to now).
    func recordCatch(at date: Date? = nil) {
        let day = dayKey(for: date ?? clock())
        var stats = load()
        stats.countsByDay[day, default: 0] += 1
        prune(&stats)
        save(stats)
    }

    // MARK: - Queries

    /// The number of fired alerts recorded on the given day.
    func count(on date: Date) -> Int {
        load().countsByDay[dayKey(for: date)] ?? 0
    }

    /// The last 7 days (oldest → newest), each as a `(day:, count:)` pair, including zeros.
    func last7Days() -> [(day: String, count: Int)] {
        let stats = load()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: clock())
        return (0..<7).reversed().compactMap { offset -> (day: String, count: Int)? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = dayKey(for: date)
            return (day: key, count: stats.countsByDay[key] ?? 0)
        }
    }

    // MARK: - Persistence

    private func load() -> CatchStats {
        guard
            let data = defaults.data(forKey: key),
            let stats = try? JSONDecoder().decode(CatchStats.self, from: data)
        else { return CatchStats() }
        return stats
    }

    private func save(_ stats: CatchStats) {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        defaults.set(data, forKey: key)
    }

    /// Drop buckets older than `retentionDays` from now, keeping the dictionary small.
    private func prune(_ stats: inout CatchStats) {
        let calendar = Calendar.current
        guard let cutoff = calendar.date(
            byAdding: .day, value: -Self.retentionDays, to: calendar.startOfDay(for: clock())
        ) else { return }
        stats.countsByDay = stats.countsByDay.filter { key, _ in
            guard let date = dayFormatter.date(from: key) else { return false }
            return date >= cutoff
        }
    }

    private func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
