import Foundation

struct LatencyTests {
    static func run() {
        testTimeoutReturnsNilWithoutCancellingTask()
        testValueReturnedBeforeTimeout()
        testTimingsSummary()
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
}
