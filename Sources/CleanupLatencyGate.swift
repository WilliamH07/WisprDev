import Foundation

/// Bounds the cost of the optional LLM cleanup step.
///
/// Cleanup is a nicety, the dictation is already usable without it, so it gets a
/// hard time budget. If the provider keeps blowing the budget, cleanup is skipped
/// for a while so every dictation stays fast and consistent, then probed again.
final class CleanupLatencyGate: @unchecked Sendable {
    static let shared = CleanupLatencyGate()

    static let budgetStorageKey = "cleanup_budget_seconds"
    static let defaultBudgetSeconds: TimeInterval = 2.0
    static let budgetRange: ClosedRange<Double> = 1.0...10.0

    /// Time allowed for cleanup after the transcript is ready.
    static var configuredBudgetSeconds: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: budgetStorageKey)
        guard stored > 0 else { return defaultBudgetSeconds }
        return min(max(stored, budgetRange.lowerBound), budgetRange.upperBound)
    }

    private let overrunsBeforePause: Int
    private let pauseSeconds: TimeInterval
    private let lock = NSLock()
    private var consecutiveOverruns = 0
    private var pausedUntil: Date?

    init(overrunsBeforePause: Int = 2, pauseSeconds: TimeInterval = 180) {
        self.overrunsBeforePause = overrunsBeforePause
        self.pauseSeconds = pauseSeconds
    }

    /// True while cleanup is paused because the provider has been too slow.
    func shouldSkipCleanup(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let pausedUntil else { return false }
        if now >= pausedUntil {
            // Pause over: allow one probe request; one more overrun pauses again.
            self.pausedUntil = nil
            consecutiveOverruns = max(overrunsBeforePause - 1, 0)
            return false
        }
        return true
    }

    func recordOverrun(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        consecutiveOverruns += 1
        if consecutiveOverruns >= overrunsBeforePause {
            pausedUntil = now.addingTimeInterval(pauseSeconds)
        }
    }

    func recordSuccess() {
        lock.lock()
        defer { lock.unlock() }
        consecutiveOverruns = 0
        pausedUntil = nil
    }
}
