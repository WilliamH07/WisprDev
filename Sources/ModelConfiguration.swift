import Foundation

public struct ModelConfig {
    public let maxCompletionTokens: Int?
    public let reasoningEffort: String?
    public let includeReasoning: Bool?
    public let shouldStripThinkTags: Bool
}

public struct ModelConfiguration {
    public static let llmModels = [
        "llama3.2:3b",
        "qwen2.5:3b",
        "openai/gpt-oss-20b",
        "openai/gpt-oss-120b",
        "openai/gpt-oss-safeguard-20b",
        "qwen/qwen3.6-27b",
        "groq/compound",
        "groq/compound-mini"
    ]

    // MARK: - Vision-capable models

    /// Models that accept image input. The context model must support vision for screenshot analysis to work.
    public static let visionModels = [
        "qwen/qwen3.6-27b"
    ]

    public static let transcriptionModels = [
        "whisper-local",
        "whisper-large-v3",
        "whisper-large-v3-turbo",
        TranscriptionRouting.fishAudioModel
    ]

    public static func config(for model: String) -> ModelConfig {
        var cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        // Normalize providerless aliases
        if cleanModel == "qwen3-32b" { cleanModel = "qwen/qwen3-32b" }
        else if cleanModel == "qwen3.6-27b" { cleanModel = "qwen/qwen3.6-27b" }
        else if cleanModel == "gpt-oss-20b" { cleanModel = "openai/gpt-oss-20b" }
        else if cleanModel == "gpt-oss-120b" { cleanModel = "openai/gpt-oss-120b" }
        else if cleanModel == "gpt-oss-safeguard-20b" { cleanModel = "openai/gpt-oss-safeguard-20b" }
        
        if cleanModel == "openai/gpt-oss-20b" {
            return ModelConfig(
                maxCompletionTokens: 4096,
                reasoningEffort: "low",
                includeReasoning: false,
                shouldStripThinkTags: false
            )
        } else if cleanModel.contains("nemotron") {
            return ModelConfig(
                maxCompletionTokens: 512,
                reasoningEffort: "none",
                includeReasoning: false,
                shouldStripThinkTags: true
            )
        } else if cleanModel == "openai/gpt-oss-120b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "openai/gpt-oss-safeguard-20b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "qwen/qwen3-32b" {
            // Model that requires sanitization of thought tags
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: true
            )
        } else if cleanModel == "qwen/qwen3.6-27b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: "none",
                includeReasoning: false,
                shouldStripThinkTags: true
            )
        } else if cleanModel == "llama-3.1-8b-instant" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "llama-3.3-70b-versatile" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "meta-llama/llama-4-scout-17b-16e-instruct" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "meta-llama/llama-prompt-guard-2-22m" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "meta-llama/llama-prompt-guard-2-86m" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "allam-2-7b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "canopylabs/orpheus-arabic-saudi" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "canopylabs/orpheus-v1-english" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "groq/compound" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "groq/compound-mini" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "whisper-large-v3" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "whisper-large-v3-turbo" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel.contains("nemotron") || cleanModel.contains("deepseek") || cleanModel.contains("r1") {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: true
            )
        }
        
        // Generic fallback for any model not explicitly listed above
        return ModelConfig(
            maxCompletionTokens: nil,
            reasoningEffort: nil,
            includeReasoning: nil,
            shouldStripThinkTags: false
        )
    }
    
    /// Utility method to remove <think>...</think> tags and everything inside them.
    /// This also handles unclosed tags gracefully (e.g. if the model runs out of tokens).
    public static func stripThinkTags(_ text: String) -> String {
        var cleaned = text
        
        // First, replace fully closed tags: <think>...</think>
        // We use a group with + to catch multiple consecutive think blocks.
        let closedRegexPattern = "^(?:\\s*<think>[\\s\\S]*?</think>)+"
        if let regex = try? NSRegularExpression(pattern: closedRegexPattern, options: []) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        // Next, if there is an unclosed <think> tag remaining (meaning it started thinking but got truncated),
        // we strip from the opening <think> tag to the very end of the string.
        let openRegexPattern = "^\\s*<think>[\\s\\S]*$"
        if let regex = try? NSRegularExpression(pattern: openRegexPattern, options: []) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Routing for transcription models that are hosted on OpenRouter rather than on
/// the user's default OpenAI-compatible provider.
public enum TranscriptionRouting {
    public static let openRouterBaseURL = "https://openrouter.ai/api/v1"
    /// Fish Audio speech-to-text, served through OpenRouter's /audio/transcriptions.
    public static let fishAudioModel = "fish-audio/transcribe-1"

    public static func isOpenRouterModel(_ model: String) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("fish-audio/")
    }

    /// An explicit transcription URL always wins. Otherwise an OpenRouter-hosted
    /// model goes to OpenRouter, and everything else uses the default base URL.
    public static func baseURL(model: String, explicitURL: String, defaultURL: String) -> String {
        let explicit = explicitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        return isOpenRouterModel(model) ? openRouterBaseURL : defaultURL
    }

    /// Key priority: explicit transcription key, then the OpenRouter key for
    /// OpenRouter-hosted models, then the default API key.
    public static func apiKey(model: String, explicitKey: String, openRouterKey: String, defaultKey: String) -> String {
        let explicit = explicitKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        let router = openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if isOpenRouterModel(model), !router.isEmpty { return router }
        return defaultKey
    }
}
