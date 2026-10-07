import Foundation

enum AppContextServiceTests {
    static func run() {
        testDesktopFallbackPreferencePersistence()
        testDesktopFallbackCaptureBoundary()
        testQwenRawOutputIsSummarized()
        testQwenReasoningOutputIsStripped()
        testNonStrippingModelPreservesExistingBehavior()
        testDeprecatedGroqModelsAreNotPredefined()
        testQwenCleanupDisablesReasoning()
    }

    private static func testDesktopFallbackPreferencePersistence() {
        let suiteName = "FreeFlowTests.DesktopFallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TestSupport.expect(DesktopScreenshotFallbackPreference.load(from: defaults), "Missing preference must preserve enabled fallback")
        TestSupport.expect(defaults.object(forKey: DesktopScreenshotFallbackPreference.storageKey) == nil, "Reading a default must not write it")

        for enabled in [false, true, false] {
            DesktopScreenshotFallbackPreference.save(enabled, to: defaults)
            let reloadedDefaults = UserDefaults(suiteName: suiteName)!
            TestSupport.expectEqual(DesktopScreenshotFallbackPreference.load(from: reloadedDefaults), enabled)
        }
        defaults.removeObject(forKey: DesktopScreenshotFallbackPreference.storageKey)
        TestSupport.expect(DesktopScreenshotFallbackPreference.load(from: defaults), "Removing preference must restore enabled default")
    }

    private static func testDesktopFallbackCaptureBoundary() {
        var captureCalls = 0
        let syntheticCapture = { () -> (dataURL: String?, mimeType: String?, error: String?) in
            captureCalls += 1
            return ("synthetic-image", "image/jpeg", nil)
        }

        let disabled = AppContextService(apiKey: "", desktopScreenshotFallbackEnabled: false)
        let skipped = disabled.captureDesktopFallback(using: syntheticCapture)
        TestSupport.expectEqual(captureCalls, 0)
        TestSupport.expect(skipped.dataURL == nil && skipped.mimeType == nil, "Disabled fallback must not return an image")
        TestSupport.expect(skipped.error?.contains("disabled") == true, "Skipped fallback should explain why no image was captured")

        for service in [AppContextService(apiKey: ""), AppContextService(apiKey: "", desktopScreenshotFallbackEnabled: true)] {
            let result = service.captureDesktopFallback(using: syntheticCapture)
            TestSupport.expectEqual(result.dataURL, "synthetic-image")
            TestSupport.expectEqual(result.mimeType, "image/jpeg")
            TestSupport.expect(result.error == nil, "Successful fallback must preserve its result")
        }
        TestSupport.expectEqual(captureCalls, 2)

        let failed = AppContextService(apiKey: "").captureDesktopFallback {
            (nil, nil, "Synthetic capture failure")
        }
        TestSupport.expect(failed.dataURL == nil && failed.mimeType == nil, "Failed fallback must remain image-free")
        TestSupport.expectEqual(failed.error, "Synthetic capture failure")
    }

    private static func testQwenRawOutputIsSummarized() {
        let output = """
        The user is replying to an email about the product launch. They likely intend to confirm the next steps. This third sentence should be dropped.
        """

        let summary = AppContextService.activitySummary(from: output, model: "qwen/qwen3.6-27b")

        TestSupport.expectEqual(
            summary,
            "The user is replying to an email about the product launch. They likely intend to confirm the next steps."
        )
    }

    private static func testQwenReasoningOutputIsStripped() {
        let output = """
        <think>
        Hidden chain of thought should never appear in context.
        It contains misleading details.
        </think>
        The user is editing a project note in FreeFlow. They likely intend to tighten the release wording.
        """

        let summary = AppContextService.activitySummary(from: output, model: "qwen/qwen3.6-27b")

        TestSupport.expectEqual(
            summary,
            "The user is editing a project note in FreeFlow. They likely intend to tighten the release wording."
        )
        TestSupport.expect(summary?.contains("Hidden chain of thought") == false, "Qwen reasoning leaked into summary")
    }

    private static func testNonStrippingModelPreservesExistingBehavior() {
        let output = "<think>Visible for non-stripping models.</think> The user is writing a status update."

        let summary = AppContextService.activitySummary(
            from: output,
            model: "meta-llama/llama-4-scout-17b-16e-instruct"
        )

        TestSupport.expectEqual(summary, output)
    }

    private static func testDeprecatedGroqModelsAreNotPredefined() {
        let deprecatedModels = [
            "qwen/qwen3-32b",
            "meta-llama/llama-4-scout-17b-16e-instruct",
            "llama-3.1-8b-instant",
            "llama-3.3-70b-versatile"
        ]

        for model in deprecatedModels {
            TestSupport.expect(!ModelConfiguration.llmModels.contains(model), "Deprecated model remains in picker: \(model)")
        }
        TestSupport.expect(ModelConfiguration.llmModels.contains("qwen/qwen3.6-27b"), "New fallback is missing from picker")
    }

    private static func testQwenCleanupDisablesReasoning() {
        let config = ModelConfiguration.config(for: "qwen/qwen3.6-27b")

        TestSupport.expect(config.reasoningEffort == "none", "Qwen cleanup should disable reasoning")
        TestSupport.expect(config.includeReasoning == false, "Qwen cleanup should exclude reasoning output")
    }
}
