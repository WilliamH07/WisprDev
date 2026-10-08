import Foundation

/// Aggregated, content-free usage counters for one calendar day.
/// Only counts and application display names are stored; never transcripts.
struct DailyUsage: Codable, Equatable {
    var dictations: Int = 0
    var words: Int = 0
    var speakingSeconds: Double = 0
    var appCounts: [String: Int] = [:]
}

struct DictationStatsSnapshot: Equatable {
    struct DayPoint: Equatable {
        let date: Date
        let words: Int
    }

    struct AppUsage: Equatable {
        let name: String
        let dictations: Int
    }

    var totalDictations = 0
    var totalWords = 0
    var totalSpeakingSeconds: Double = 0
    var currentStreakDays = 0
    var bestStreakDays = 0
    var recentDays: [DayPoint] = []
    var topApps: [AppUsage] = []

    /// Average spoken words per minute across all recorded speaking time.
    var averageWordsPerMinute: Int {
        guard totalSpeakingSeconds >= 1 else { return 0 }
        return Int((Double(totalWords) / (totalSpeakingSeconds / 60)).rounded())
    }

    /// Minutes saved versus typing at `typingWordsPerMinute`.
    func minutesSaved(typingWordsPerMinute: Double = 40) -> Int {
        let typingMinutes = Double(totalWords) / typingWordsPerMinute
        return max(0, Int((typingMinutes - totalSpeakingSeconds / 60).rounded()))
    }
}

enum DictationStatsCalculator {
    static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func snapshot(
        from days: [String: DailyUsage],
        now: Date,
        calendar: Calendar,
        recentDayCount: Int = 14,
        topAppLimit: Int = 5
    ) -> DictationStatsSnapshot {
        var snapshot = DictationStatsSnapshot()
        var appTotals: [String: Int] = [:]
        for usage in days.values {
            snapshot.totalDictations += usage.dictations
            snapshot.totalWords += usage.words
            snapshot.totalSpeakingSeconds += usage.speakingSeconds
            for (app, count) in usage.appCounts {
                appTotals[app, default: 0] += count
            }
        }

        let today = calendar.startOfDay(for: now)
        snapshot.recentDays = (0..<max(recentDayCount, 1)).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let words = days[dayKey(for: day, calendar: calendar)]?.words ?? 0
            return DictationStatsSnapshot.DayPoint(date: day, words: words)
        }

        snapshot.topApps = appTotals
            .sorted { lhs, rhs in lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key }
            .prefix(topAppLimit)
            .map { DictationStatsSnapshot.AppUsage(name: $0.key, dictations: $0.value) }

        // Current streak: consecutive active days ending today (or yesterday,
        // so the streak is not lost before the first dictation of the day).
        let activeKeys = Set(days.filter { $0.value.dictations > 0 }.keys)
        var cursor = today
        if !activeKeys.contains(dayKey(for: cursor, calendar: calendar)),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        var streak = 0
        while activeKeys.contains(dayKey(for: cursor, calendar: calendar)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        snapshot.currentStreakDays = streak

        let sortedKeys = activeKeys.sorted()
        var best = 0
        var run = 0
        var previousDate: Date?
        for key in sortedKeys {
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            else { continue }
            if let previousDate,
               let next = calendar.date(byAdding: .day, value: 1, to: previousDate),
               calendar.isDate(next, inSameDayAs: date) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previousDate = date
        }
        snapshot.bestStreakDays = best
        return snapshot
    }
}

/// Persists cumulative, content-free usage counters locally (UserDefaults).
/// Unlike pipeline history this is not capped, so lifetime stats stay accurate.
final class UsageStatsStore {
    static let shared = UsageStatsStore()
    private static let storageKey = "usage_stats_daily_v1"
    private static let retentionDays = 400

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    func record(wordCount: Int, speakingSeconds: Double, appName: String?, at date: Date = Date()) {
        guard wordCount > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        var days = loadLocked()
        let key = DictationStatsCalculator.dayKey(for: date, calendar: calendar)
        var usage = days[key] ?? DailyUsage()
        usage.dictations += 1
        usage.words += wordCount
        usage.speakingSeconds += max(0, speakingSeconds)
        let trimmedApp = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedApp.isEmpty {
            usage.appCounts[trimmedApp, default: 0] += 1
        }
        days[key] = usage
        pruneLocked(&days, now: date)
        saveLocked(days)
    }

    func snapshot(now: Date = Date(), recentDayCount: Int = 14) -> DictationStatsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DictationStatsCalculator.snapshot(
            from: loadLocked(),
            now: now,
            calendar: calendar,
            recentDayCount: recentDayCount
        )
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func loadLocked() -> [String: DailyUsage] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: DailyUsage].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveLocked(_ days: [String: DailyUsage]) {
        if let data = try? JSONEncoder().encode(days) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func pruneLocked(_ days: inout [String: DailyUsage], now: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: now) else { return }
        let cutoffKey = DictationStatsCalculator.dayKey(for: cutoff, calendar: calendar)
        days = days.filter { $0.key >= cutoffKey }
    }
}
