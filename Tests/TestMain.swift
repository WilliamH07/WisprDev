import Foundation

@main
struct WisperTests {
    static func main() {
        AppContextServiceTests.run()
        ModelConfigurationTests.run()
        ShortcutCoreTests.run()
        SemanticVersionTests.run()
        LLMCooldownManagerTests.run()
        TranscriptionErrorPresentationCoreTests.run()
        TranscriptTextCoreTests.run()
        AudioSilenceFilterTests.run()
        AIAssistantAndRewriteTests.run()
        HapticFeedbackServiceTests.run()
        SemanticMemoryTests.run()
        DictationStatsTests.run()
        print("WisperTests passed")
    }
}
