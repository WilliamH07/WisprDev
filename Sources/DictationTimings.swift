import Foundation

/// Per-stage latency of one dictation, in seconds. Contains durations only;
/// never any transcript, audio, or application content.
struct DictationTimings: Equatable {
    var audioFinalize: TimeInterval = 0
    var transcription: TimeInterval = 0
    var contextWait: TimeInterval = 0
    var postProcessing: TimeInterval = 0
    var skippedPostProcessing = false

    /// Time between releasing the shortcut and the text being ready to paste.
    var total: TimeInterval {
        audioFinalize + transcription + contextWait + postProcessing
    }

    static func format(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.1f s", seconds)
    }

    var summary: String {
        "Total \(Self.format(total)) · transcription \(Self.format(transcription))"
            + (skippedPostProcessing ? " · nettoyage ignoré" : " · nettoyage \(Self.format(postProcessing))")
    }
}
