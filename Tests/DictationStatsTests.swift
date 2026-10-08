import Foundation

struct DictationStatsTests {
    static func run() {
        testSnapshotTotalsAndStreak()
        testStorePersistsAndAggregates()
        testFastPathDecision()
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private static func testSnapshotTotalsAndStreak() {
        let days: [String: DailyUsage] = [
            "2026-03-01": DailyUsage(dictations: 2, words: 100, speakingSeconds: 60, appCounts: ["Mail": 2]),
            "2026-03-02": DailyUsage(dictations: 1, words: 50, speakingSeconds: 30, appCounts: ["Notes": 1]),
            "2026-03-03": DailyUsage(dictations: 3, words: 150, speakingSeconds: 90, appCounts: ["Mail": 3]),
            "2026-02-20": DailyUsage(dictations: 1, words: 10, speakingSeconds: 5)
        ]
        let snapshot = DictationStatsCalculator.snapshot(from: days, now: date(2026, 3, 3), calendar: calendar)
        TestSupport.expectEqual(snapshot.totalDictations, 7)
        TestSupport.expectEqual(snapshot.totalWords, 310)
        TestSupport.expectEqual(snapshot.currentStreakDays, 3)
        TestSupport.expectEqual(snapshot.bestStreakDays, 3)
        TestSupport.expectEqual(snapshot.topApps.first?.name, "Mail")
        TestSupport.expectEqual(snapshot.recentDays.count, 14)
        TestSupport.expectEqual(snapshot.recentDays.last?.words, 150)

        // Streak survives until the first dictation of a new day.
        let nextMorning = DictationStatsCalculator.snapshot(from: days, now: date(2026, 3, 4), calendar: calendar)
        TestSupport.expectEqual(nextMorning.currentStreakDays, 3)
        let afterGap = DictationStatsCalculator.snapshot(from: days, now: date(2026, 3, 6), calendar: calendar)
        TestSupport.expectEqual(afterGap.currentStreakDays, 0)
        TestSupport.expectEqual(DictationStatsSnapshot().averageWordsPerMinute, 0)
    }

    private static func testStorePersistsAndAggregates() {
        let suite = "WisperTests.stats.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStatsStore(defaults: defaults, calendar: calendar)
        let now = date(2026, 5, 10)
        store.record(wordCount: 60, speakingSeconds: 30, appName: "Notes", at: now)
        store.record(wordCount: 0, speakingSeconds: 5, appName: "Notes", at: now)
        store.record(wordCount: 40, speakingSeconds: 30, appName: nil, at: now)
        let snapshot = store.snapshot(now: now)
        TestSupport.expectEqual(snapshot.totalDictations, 2)
        TestSupport.expectEqual(snapshot.totalWords, 100)
        TestSupport.expectEqual(snapshot.averageWordsPerMinute, 100)
        TestSupport.expectEqual(snapshot.topApps.count, 1)
        store.reset()
        TestSupport.expectEqual(store.snapshot(now: now).totalWords, 0)
    }

    private static func testFastPathDecision() {
        func skip(_ text: String, language: String = "", vocab: String = "", prompt: String = "") -> Bool {
            TranscriptFastPath.shouldSkipPostProcessing(
                transcript: text,
                outputLanguage: language,
                customVocabulary: vocab,
                customSystemPrompt: prompt
            )
        }
        TestSupport.expect(skip("Sounds good, thanks."), "short utterance should skip cleanup")
        TestSupport.expect(!skip("one two three four five six seven"), "long utterance keeps cleanup")
        TestSupport.expect(!skip("   "), "empty transcript is not a fast path")
        TestSupport.expect(!skip("Hello there", language: "French"), "translation needs the model")
        TestSupport.expect(!skip("Hello there", vocab: "Kubernetes"), "vocabulary needs the model")
        TestSupport.expect(!skip("Hello there", prompt: "Custom"), "custom prompt needs the model")
    }
}
