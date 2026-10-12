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
