import AppKit
import Foundation

final class MockHapticPerformer: @unchecked Sendable, HapticPerformerProtocol {
    private let lock = NSLock()
    private var _performedPatterns: [NSHapticFeedbackManager.FeedbackPattern] = []

    var performedPatterns: [NSHapticFeedbackManager.FeedbackPattern] {
        lock.lock()
        defer { lock.unlock() }
        return _performedPatterns
    }

    func performFeedback(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        lock.lock()
        defer { lock.unlock() }
        _performedPatterns.append(pattern)
    }
}

enum HapticFeedbackServiceTests {
    static func run() {
        testHapticPatternsDispatched()
        testHapticDisabledSetting()
    }

    private static func testHapticPatternsDispatched() {
        let mock = MockHapticPerformer()
        let service = HapticFeedbackService(performer: mock)

        UserDefaults.standard.set(true, forKey: "haptic_feedback_enabled")

        service.trigger(.startRecording)
        service.trigger(.stopRecording)
        service.trigger(.success)
        service.trigger(.error)
        service.trigger(.toggle)

        // Wait for main thread dispatch
        let exp = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        _ = exp

        TestSupport.expectEqual(mock.performedPatterns.count, 5)
        TestSupport.expectEqual(mock.performedPatterns[0], .alignment)
        TestSupport.expectEqual(mock.performedPatterns[1], .levelChange)
        TestSupport.expectEqual(mock.performedPatterns[2], .generic)
        TestSupport.expectEqual(mock.performedPatterns[3], .alignment)
        TestSupport.expectEqual(mock.performedPatterns[4], .levelChange)
    }

    private static func testHapticDisabledSetting() {
        let mock = MockHapticPerformer()
        let service = HapticFeedbackService(performer: mock)

        UserDefaults.standard.set(false, forKey: "haptic_feedback_enabled")

        service.trigger(.startRecording)
        service.trigger(.success)

        let exp = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        _ = exp

        TestSupport.expectEqual(mock.performedPatterns.count, 0)

        // Clean up preference
        UserDefaults.standard.set(true, forKey: "haptic_feedback_enabled")
    }
}
