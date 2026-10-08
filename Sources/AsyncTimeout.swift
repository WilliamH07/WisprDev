import Foundation

/// Waits for a task's value, but gives up after `timeout` seconds without
/// cancelling the underlying task (it keeps running for other consumers).
enum AsyncTimeout {
    private final class OnceGate<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var finished = false

        func install(_ continuation: CheckedContinuation<T?, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ value: T?) {
            lock.lock()
            guard !finished, let continuation else {
                lock.unlock()
                return
            }
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        }
    }

    static func value<T>(of task: Task<T, Never>, timeout: TimeInterval) async -> T? {
        let gate = OnceGate<T>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            gate.install(continuation)
            Task { gate.finish(await task.value) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                gate.finish(nil)
            }
        }
    }
}
