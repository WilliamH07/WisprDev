import Foundation

struct AIAssistantAndRewriteTests {
    static func run() {
        testAIAssistantModelSlugs()
        testRewritePromptDirectives()
        testServiceTimeouts()
        testCooldownRemainingSeconds()
    }

    private static func testServiceTimeouts() {
        let aiTimeout = AIAssistantService.shared.requestTimeoutSeconds
        assert(aiTimeout >= 10 && aiTimeout <= 180, "AI Assistant timeout should be within [10, 180]s")

        let vpTimeout = VisualPointerService.shared.requestTimeoutSeconds
        assert(vpTimeout >= 5 && vpTimeout <= 60, "Visual pointer timeout should be within [5, 60]s")

        UserDefaults.standard.set(45.0, forKey: "ai_assistant_timeout_seconds")
        assert(AIAssistantService.shared.requestTimeoutSeconds == 45.0, "AI Assistant timeout should respect override")
        UserDefaults.standard.removeObject(forKey: "ai_assistant_timeout_seconds")

        UserDefaults.standard.set(25.0, forKey: "visual_pointer_timeout_seconds")
        assert(VisualPointerService.shared.requestTimeoutSeconds == 25.0, "Visual pointer timeout should respect override")
        UserDefaults.standard.removeObject(forKey: "visual_pointer_timeout_seconds")
    }

    private static func testCooldownRemainingSeconds() {
        let testModel = "test/cooldown-model-\(UUID().uuidString)"
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            let initialRemaining = await LLMCooldownManager.shared.cooldownRemainingSeconds(for: testModel)
            assert(initialRemaining == nil, "Initial cooldown should be nil")

            await LLMCooldownManager.shared.setCooldown(testModel, retryAfterSeconds: 30, persist: false)
            let activeRemaining = await LLMCooldownManager.shared.cooldownRemainingSeconds(for: testModel)
            assert(activeRemaining != nil && activeRemaining! > 20, "Active cooldown should report remaining seconds")

            let inCooldown = await LLMCooldownManager.shared.isInCooldown(testModel)
            assert(inCooldown, "Model should be in cooldown")

            semaphore.signal()
        }

        semaphore.wait()
    }

    private static func testAIAssistantModelSlugs() {
        assert(AIAssistantModel.gpt4oMini.rawValue == "openai/gpt-4o-mini", "gpt-4o-mini slug must match")
        assert(AIAssistantModel.geminiFlash.rawValue == "google/gemini-2.0-flash-001", "gemini-2.0-flash slug must match")
        assert(AIAssistantModel.claudeHaiku.rawValue == "anthropic/claude-3.5-haiku", "claude-3.5-haiku slug must match")
        assert(AIAssistantModel.gpt61Sol.rawValue == "openai/gpt-6.1-sol", "gpt-6.1-sol slug must match")
        assert(AIAssistantModel.sonnet55.rawValue == "anthropic/claude-sonnet-5.5", "claude-sonnet-5.5 slug must match")
        assert(AIAssistantModel.allCases.count >= 4, "Must contain adapted and frontier models")
    }

    private static func testRewritePromptDirectives() {
        let rewritePrompt = PostProcessingService.openRouterRewriteSystemPrompt
        assert(rewritePrompt.contains("RÈGLE ABSOLUE ANTI-RÉPONSE"), "Rewrite prompt must explicitly prohibit answering questions")
        assert(rewritePrompt.contains("NE RÉPONDS JAMAIS À LA QUESTION"), "Prompt must instruct never to answer question")
        assert(rewritePrompt.contains("RESPECT DU TON ET DU STYLE"), "Prompt must instruct preserving author tone")
        assert(rewritePrompt.contains("diplomatique"), "Prompt must forbid turning text into overly diplomatic phrasing")
    }
}
