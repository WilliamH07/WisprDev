import Foundation

struct LatencyTests {
    static func run() {
        testTimeoutReturnsNilWithoutCancellingTask()
        testValueReturnedBeforeTimeout()
        testTimingsSummary()
        testCleanupGate()
    }

    private static func blocking<T>(_ work: @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        Task {
            result = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }

    private static func testTimeoutReturnsNilWithoutCancellingTask() {
        let slow = Task<Int, Never> {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return 7
        }
        let early: Int? = blocking { await AsyncTimeout.value(of: slow, timeout: 0.05) }
        TestSupport.expect(early == nil, "slow task should time out")
        let late: Int = blocking { await slow.value }
        TestSupport.expectEqual(late, 7)
    }

    private static func testValueReturnedBeforeTimeout() {
        let fast = Task<String, Never> { "ok" }
        let value: String? = blocking { await AsyncTimeout.value(of: fast, timeout: 2) }
        TestSupport.expectEqual(value, "ok")
    }

    private static func testTimingsSummary() {
        var timings = DictationTimings()
        timings.transcription = 0.42
        timings.postProcessing = 1.5
        TestSupport.expectApproximatelyEqual(timings.total, 1.92)
        TestSupport.expectEqual(DictationTimings.format(0.42), "420 ms")
        TestSupport.expectEqual(DictationTimings.format(1.5), "1.5 s")
        timings.skippedPostProcessing = true
        TestSupport.expect(timings.summary.contains("nettoyage ignoré"), "summary should flag skipped cleanup")
    }

    private static func testCleanupGate() {
        let gate = CleanupLatencyGate(overrunsBeforePause: 2, pauseSeconds: 180)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        TestSupport.expect(!gate.shouldSkipCleanup(now: t0), "fresh gate allows cleanup")
        gate.recordOverrun(now: t0)
        TestSupport.expect(!gate.shouldSkipCleanup(now: t0), "one overrun does not pause")
        gate.recordOverrun(now: t0)
        TestSupport.expect(gate.shouldSkipCleanup(now: t0.addingTimeInterval(60)), "two overruns pause cleanup")
        TestSupport.expect(!gate.shouldSkipCleanup(now: t0.addingTimeInterval(181)), "pause ends and allows a probe")
        gate.recordOverrun(now: t0.addingTimeInterval(182))
        TestSupport.expect(gate.shouldSkipCleanup(now: t0.addingTimeInterval(183)), "a failed probe pauses again")
        gate.recordSuccess()
        TestSupport.expect(!gate.shouldSkipCleanup(now: t0.addingTimeInterval(184)), "success resets the gate")

        UserDefaults.standard.removeObject(forKey: CleanupLatencyGate.budgetStorageKey)
        TestSupport.expectApproximatelyEqual(CleanupLatencyGate.configuredBudgetSeconds, CleanupLatencyGate.defaultBudgetSeconds)
        UserDefaults.standard.set(99.0, forKey: CleanupLatencyGate.budgetStorageKey)
        TestSupport.expectApproximatelyEqual(CleanupLatencyGate.configuredBudgetSeconds, CleanupLatencyGate.budgetRange.upperBound)
        UserDefaults.standard.removeObject(forKey: CleanupLatencyGate.budgetStorageKey)
    }
}
