import AppKit

public enum WisperHapticFeedback: Sendable {
    /// Subtle tick when recording or speech begins (.alignment)
    case startRecording
    /// Crisp tactile tick when recording finishes (.levelChange)
    case stopRecording
    /// Satisfying click when transcription or rewrite is pasted or copied (.generic)
    case success
    /// Subtle alert tick on error or cancellation (.alignment)
    case error
    /// Discrete level-change click (e.g. toggling AI Assistant mode) (.levelChange)
    case toggle
}

public protocol HapticPerformerProtocol: AnyObject, Sendable {
    func performFeedback(_ pattern: NSHapticFeedbackManager.FeedbackPattern)
}

public final class DefaultHapticPerformer: HapticPerformerProtocol {
    public init() {}

    public func performFeedback(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

public final class HapticFeedbackService: @unchecked Sendable {
    public static let shared = HapticFeedbackService()

    private let performer: HapticPerformerProtocol

    public init(performer: HapticPerformerProtocol = DefaultHapticPerformer()) {
        self.performer = performer
    }

    public var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "haptic_feedback_enabled") as? Bool ?? true
    }

    public func trigger(_ feedback: WisperHapticFeedback) {
        guard isEnabled else { return }

        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch feedback {
        case .startRecording:
            pattern = .alignment
        case .stopRecording:
            pattern = .levelChange
        case .success:
            pattern = .generic
        case .error:
            pattern = .alignment
        case .toggle:
            pattern = .levelChange
        }

        DispatchQueue.main.async { [weak self] in
            self?.performer.performFeedback(pattern)
        }
    }
}
