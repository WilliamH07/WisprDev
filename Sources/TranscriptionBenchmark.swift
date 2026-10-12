import Foundation

/// One engine to time: an OpenAI-compatible transcription endpoint plus model.
struct BenchmarkCandidate: Identifiable, Equatable {
    let label: String
    let model: String
    let baseURL: String
    let apiKey: String
    var id: String { "\(baseURL)|\(model)" }
}

struct BenchmarkResult: Identifiable, Equatable {
    let candidate: BenchmarkCandidate
    /// First request: includes DNS/TLS and any provider cold start.
    var coldSeconds: TimeInterval?
    /// Median of the following requests: what you feel once the connection is warm.
    var warmSeconds: TimeInterval?
    var errorMessage: String?
    var id: String { candidate.id }
}

/// Times each configured engine on a synthetic clip so the fastest one can be
/// chosen from facts. Only synthetic audio is sent; nothing the user said.
@MainActor
final class TranscriptionBenchmarkRunner: ObservableObject {
    @Published private(set) var results: [BenchmarkResult] = []
    @Published private(set) var isRunning = false

    private let runsPerEngine = 4

    func run(candidates: [BenchmarkCandidate]) async {
        guard !isRunning, !candidates.isEmpty else { return }
        isRunning = true
        results = candidates.map { BenchmarkResult(candidate: $0) }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisper-bench-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        do {
            try SyntheticSpeechWAV.make().write(to: fileURL, options: .atomic)
        } catch {
            results = candidates.map { BenchmarkResult(candidate: $0, errorMessage: "Fichier de test impossible à créer") }
            isRunning = false
            return
        }

        for (index, candidate) in candidates.enumerated() {
            var durations: [TimeInterval] = []
            var failure: String?
            do {
                let service = try TranscriptionService(
                    apiKey: candidate.apiKey,
                    baseURL: candidate.baseURL,
                    transcriptionModel: candidate.model,
                    language: nil,
                    prompt: nil
                )
                for _ in 0..<runsPerEngine {
                    let start = CFAbsoluteTimeGetCurrent()
                    _ = try await service.transcribe(fileURL: fileURL)
                    durations.append(CFAbsoluteTimeGetCurrent() - start)
                }
            } catch {
                failure = error.localizedDescription
            }
            results[index] = BenchmarkResult(
                candidate: candidate,
                coldSeconds: durations.first,
                warmSeconds: BenchmarkMath.median(Array(durations.dropFirst())),
                errorMessage: failure
            )
        }
        isRunning = false
    }
}

// MARK: - Cleanup (rewrite) model benchmark

struct CleanupCandidate: Identifiable, Equatable {
    enum Provider: Equatable { case openRouter, groqCloud }
    let label: String
    let model: String
    let baseURL: String
    let apiKey: String
    let provider: Provider
    var id: String { "\(baseURL)|\(model)" }
}

struct CleanupBenchmarkResult: Identifiable, Equatable {
    let candidate: CleanupCandidate
    var samples: [TimeInterval] = []
    var errorMessage: String?
    var id: String { candidate.id }

    var median: TimeInterval? { BenchmarkMath.median(samples) }
    var worst: TimeInterval? { samples.max() }
    /// A model that is fast on average but occasionally very slow is the failure mode to avoid.
    var isErratic: Bool {
        guard let median, let worst, median > 0 else { return false }
        return worst > max(median * 3, 2.0)
    }
}

/// Times the AI cleanup step on a fixed synthetic sentence, several times per model,
/// so both the typical latency and the worst case (the variance) are visible.
@MainActor
final class CleanupBenchmarkRunner: ObservableObject {
    @Published private(set) var results: [CleanupBenchmarkResult] = []
    @Published private(set) var isRunning = false

    private let runsPerModel = 6
    private static let syntheticSentence =
        "euh donc en fait je voulais dire que le déploiement est prévu demain matin et que on doit vérifier la config avant"

    func run(candidates: [CleanupCandidate]) async {
        guard !isRunning, !candidates.isEmpty else { return }
        isRunning = true
        results = candidates.map { CleanupBenchmarkResult(candidate: $0) }
        for (index, candidate) in candidates.enumerated() {
            do {
                for _ in 0..<runsPerModel {
                    let start = CFAbsoluteTimeGetCurrent()
                    try await Self.request(candidate)
                    results[index].samples.append(CFAbsoluteTimeGetCurrent() - start)
                }
            } catch {
                results[index].errorMessage = error.localizedDescription
            }
        }
        isRunning = false
    }

    private static func request(_ candidate: CleanupCandidate) async throws {
        guard let url = URL(string: candidate.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/chat/completions") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(candidate.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let config = ModelConfiguration.config(for: candidate.model)
        var payload: [String: Any] = [
            "model": candidate.model,
            "temperature": 0.0,
            "messages": [
                ["role": "system", "content": PostProcessingService.openRouterDictationSystemPrompt],
                ["role": "user", "content": "Transcription vocale brute à formater :\n\(syntheticSentence)"]
            ]
        ]
        if let maxTokens = config.maxCompletionTokens {
            payload["max_completion_tokens"] = maxTokens
        }
        switch candidate.provider {
        case .openRouter:
            payload["provider"] = ["sort": "latency"]
            payload["reasoning"] = ["effort": config.reasoningEffort ?? "none", "exclude": true]
        case .groqCloud:
            if let effort = config.reasoningEffort { payload["reasoning_effort"] = effort }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await LLMAPITransport.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "CleanupBenchmark", code: code, userInfo: [
                NSLocalizedDescriptionKey: "Réponse HTTP \(code)"
            ])
        }
    }
}
