import AppKit
import Foundation
import os.log

private let aiLog = OSLog(subsystem: "com.williamh07.wisper", category: "AIAssistant")

enum AIAssistantModel: String, CaseIterable, Identifiable {
    case gpt4oMini = "openai/gpt-4o-mini"
    case geminiFlash = "google/gemini-2.0-flash-001"
    case claudeHaiku = "anthropic/claude-3.5-haiku"
    case sonnet55 = "anthropic/claude-sonnet-5.5"
    case gpt61Sol = "openai/gpt-6.1-sol"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt4oMini: return "GPT-4o Mini (Rapide & Léger)"
        case .geminiFlash: return "Gemini 2.0 Flash (Ultra-rapide)"
        case .claudeHaiku: return "Claude 3.5 Haiku (Anthropic)"
        case .sonnet55: return "Claude Sonnet 5.5 (Avancé)"
        case .gpt61Sol: return "GPT-6.1 Sol (Frontier)"
        }
    }

    var shortName: String {
        switch self {
        case .gpt4oMini: return "4o Mini"
        case .geminiFlash: return "Gemini Flash"
        case .claudeHaiku: return "Haiku"
        case .sonnet55: return "Sonnet 5.5"
        case .gpt61Sol: return "6.1 Sol"
        }
    }
}

final class AIAssistantService {
    static let shared = AIAssistantService()

    /// Configurable request timeout (in seconds) for OpenRouter completions.
    var requestTimeoutSeconds: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "ai_assistant_timeout_seconds")
        guard override.isFinite, override > 0 else { return 60 }
        return min(max(override, 10), 180)
    }

    private init() {}

    // MARK: - Interactive Screen Capture (Cmd+Shift+4 style)

    /// Launches native macOS interactive selection screencapture (`screencapture -i`).
    /// Returns the cropped `NSImage` selected by the user, or `nil` if cancelled (Esc).
    static func captureInteractiveScreenArea() async -> NSImage? {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("wisper-crop-\(UUID().uuidString).png")

        let rawData: Data? = await Task.detached(priority: .userInitiated) { () -> Data? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i: interactive screen selection
            // -r: do not add screen shadow or borders
            process.arguments = ["-i", "-r", tempURL.path]

            do {
                try process.run()
                process.waitUntilExit()

                guard process.terminationStatus == 0,
                      FileManager.default.fileExists(atPath: tempURL.path),
                      let data = try? Data(contentsOf: tempURL) else {
                    try? FileManager.default.removeItem(at: tempURL)
                    return nil
                }

                try? FileManager.default.removeItem(at: tempURL)
                return data
            } catch {
                os_log(.error, log: aiLog, "Screen capture failed: %{public}@", error.localizedDescription)
                try? FileManager.default.removeItem(at: tempURL)
                return nil
            }
        }.value

        guard let rawData else { return nil }
        return NSImage(data: rawData)
    }

    // MARK: - System Prompt Building

    func buildSystemPrompt(for prompt: String, memories: [SemanticSearchResult]? = nil) -> String {
        var systemPrompt = """
        Tu es l'assistant IA intégré de Wisper sur macOS.
        Tu réponds aux questions de l'utilisateur de manière précise, concise, claire et utile.
        Si une image ou capture d'écran est fournie, analyse-la soigneusement pour répondre avec précision à la demande de l'utilisateur.
        Formate tes réponses en Markdown élégant (listes, gras, blocs de code avec coloration syntaxique si pertinent).
        """

        let searchResults: [SemanticSearchResult]
        if let memories {
            searchResults = memories
        } else if SemanticMemoryService.shared.isEnabled {
            searchResults = SemanticMemoryService.shared.search(query: prompt, limit: 4)
        } else {
            searchResults = []
        }

        if !searchResults.isEmpty {
            systemPrompt += "\n\n[MÉMOIRE SÉMANTIQUE LOCALE (« MON DEUXIÈME CERVEAU »)]\n"
            systemPrompt += "Voici les éléments mémorisés localement sur le Mac de l'utilisateur (presse-papier, dictées, réécritures, commandes de terminal) les plus pertinents par rapport à sa demande :\n"
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .short
            dateFormatter.timeStyle = .short
            for (index, res) in searchResults.enumerated() {
                let dateStr = dateFormatter.string(from: res.item.timestamp)
                let appStr = res.item.sourceAppName.isEmpty ? "Système" : res.item.sourceAppName
                systemPrompt += "- Souvenir #\(index + 1) [Catégorie: \(res.item.category.rawValue), Source: \(appStr), Date: \(dateStr)] :\n```\n\(res.item.text)\n```\n"
            }
            systemPrompt += """

            Consignes impératives pour l'utilisation de la mémoire :
            1. Si l'utilisateur demande une commande (ex: Docker, NAS, SSH, Git, scripts, terminal), un code, un lien ou une information qui figure dans ces souvenirs ci-dessus : réponds DIRECTEMENT en lui citant la commande ou l'information exacte.
            2. N'affirme JAMAIS que tu ne trouves pas la commande dans les souvenirs si des commandes correspondantes figurent dans la liste ci-dessus.
            3. Si plusieurs commandes correspondent, mets en avant la plus pertinente (ex: la commande pour lancer/démarrer le conteneur ou service) et mentionne brièvement les alternatives si utile.
            """
        }

        return systemPrompt
    }

    // MARK: - OpenRouter Real-time Streaming Chat

    func streamQuery(
        prompt: String,
        image: NSImage? = nil,
        model: String,
        apiKey: String,
        memories: [SemanticSearchResult]? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedKey.isEmpty else {
                        continuation.finish(throwing: NSError(
                            domain: "AIAssistantService",
                            code: 401,
                            userInfo: [NSLocalizedDescriptionKey: "Clé API OpenRouter requise. Ajoutez-la dans les Réglages."]
                        ))
                        return
                    }

                    if await LLMCooldownManager.shared.isInCooldown(model) {
                        let remaining = await LLMCooldownManager.shared.cooldownRemainingSeconds(for: model)
                        let waitNotice = remaining.map { " Réessayez dans \(Int(ceil($0)))s." } ?? ""
                        continuation.finish(throwing: NSError(
                            domain: "OpenRouter",
                            code: 429,
                            userInfo: [NSLocalizedDescriptionKey: "Le modèle « \(model) » est temporairement limité par son quota (429).\(waitNotice) Veuillez patienter ou sélectionner un autre modèle."]
                        ))
                        return
                    }

                    guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
                        continuation.finish(throwing: URLError(.badURL))
                        return
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("https://github.com/WilliamH07/Wisper", forHTTPHeaderField: "HTTP-Referer")
                    request.setValue("Wisper", forHTTPHeaderField: "X-Title")
                    request.timeoutInterval = self.requestTimeoutSeconds * 1.5

                    let systemPrompt = self.buildSystemPrompt(for: prompt, memories: memories)

                    var userContent: [[String: Any]] = [
                        [
                            "type": "text",
                            "text": prompt
                        ]
                    ]

                    if let image, let dataURL = self.makeBase64DataURL(from: image) {
                        userContent.append([
                            "type": "image_url",
                            "image_url": ["url": dataURL]
                        ])
                    }

                    let messages: [[String: Any]] = [
                        ["role": "system", "content": systemPrompt],
                        ["role": "user", "content": userContent]
                    ]

                    let payload: [String: Any] = [
                        "model": model,
                        "messages": messages,
                        "temperature": 0.3,
                        "stream": true
                    ]

                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await LLMAPITransport.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: URLError(.badServerResponse))
                        return
                    }

                    guard httpResponse.statusCode == 200 else {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                            if errorBody.count > 500 { break }
                        }
                        if errorBody.isEmpty {
                            errorBody = "Erreur HTTP \(httpResponse.statusCode)"
                        }
                        if httpResponse.statusCode == 429 {
                            let cooldown = LLMCooldownManager.rateLimitCooldown(from: httpResponse)
                            await LLMCooldownManager.shared.setCooldown(model, retryAfterSeconds: cooldown.seconds, persist: cooldown.isDaily)
                            os_log(.info, log: aiLog, "AIAssistant model %{public}@ hit 429 rate limit. Cooldown: %.1fs (daily: %{public}@)", model, cooldown.seconds, String(describing: cooldown.isDaily))
                        }
                        os_log(.error, log: aiLog, "OpenRouter streaming error HTTP %d: %{public}@", httpResponse.statusCode, errorBody)
                        continuation.finish(throwing: NSError(
                            domain: "OpenRouter",
                            code: httpResponse.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "Erreur OpenRouter (\(httpResponse.statusCode)) : \(errorBody)"]
                        ))
                        return
                    }

                    for try await rawLine in bytes.lines {
                        if Task.isCancelled { break }
                        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !line.isEmpty else { continue }
                        if line.hasPrefix(":") { continue }
                        guard line.hasPrefix("data:") else { continue }

                        let jsonString = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                        if jsonString == "[DONE]" {
                            break
                        }

                        guard let data = jsonString.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let firstChoice = choices.first,
                              let delta = firstChoice["delta"] as? [String: Any] else {
                            continue
                        }

                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - OpenRouter Non-streaming Chat Fallback

    func sendQuery(
        prompt: String,
        image: NSImage? = nil,
        model: String,
        apiKey: String,
        memories: [SemanticSearchResult]? = nil
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw NSError(
                domain: "AIAssistantService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Clé API OpenRouter requise. Ajoutez-la dans les Réglages."]
            )
        }

        if await LLMCooldownManager.shared.isInCooldown(model) {
            let remaining = await LLMCooldownManager.shared.cooldownRemainingSeconds(for: model)
            let waitNotice = remaining.map { " Réessayez dans \(Int(ceil($0)))s." } ?? ""
            throw NSError(
                domain: "OpenRouter",
                code: 429,
                userInfo: [NSLocalizedDescriptionKey: "Le modèle « \(model) » est temporairement limité par son quota (429).\(waitNotice) Veuillez patienter ou sélectionner un autre modèle."]
            )
        }

        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/WilliamH07/Wisper", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Wisper", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = requestTimeoutSeconds

        let systemPrompt = buildSystemPrompt(for: prompt, memories: memories)

        var userContent: [[String: Any]] = [
            [
                "type": "text",
                "text": prompt
            ]
        ]

        if let image, let dataURL = makeBase64DataURL(from: image) {
            userContent.append([
                "type": "image_url",
                "image_url": ["url": dataURL]
            ])
        }

        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userContent]
        ]

        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.3
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await LLMAPITransport.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Erreur HTTP \(httpResponse.statusCode)"
            if httpResponse.statusCode == 429 {
                let cooldown = LLMCooldownManager.rateLimitCooldown(from: httpResponse)
                await LLMCooldownManager.shared.setCooldown(model, retryAfterSeconds: cooldown.seconds, persist: cooldown.isDaily)
                os_log(.info, log: aiLog, "AIAssistant model %{public}@ hit 429 rate limit. Cooldown: %.1fs (daily: %{public}@)", model, cooldown.seconds, String(describing: cooldown.isDaily))
            }
            os_log(.error, log: aiLog, "OpenRouter error HTTP %d: %{public}@", httpResponse.statusCode, errorBody)
            throw NSError(
                domain: "OpenRouter",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Erreur OpenRouter (\(httpResponse.statusCode)) : \(errorBody)"]
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(
                domain: "AIAssistantService",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Réponse du modèle invalide ou vide."]
            )
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Image Conversion Helper

    private func makeBase64DataURL(from image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }

        // Limit size to max 1920 dimension to avoid gigantic payloads
        let maxDimension: CGFloat = 1920
        var targetSize = image.size
        if targetSize.width > maxDimension || targetSize.height > maxDimension {
            let ratio = min(maxDimension / targetSize.width, maxDimension / targetSize.height)
            targetSize = CGSize(width: targetSize.width * ratio, height: targetSize.height * ratio)
        }

        let resizedBitmap: NSBitmapImageRep
        if targetSize != image.size {
            let resized = NSImage(size: targetSize)
            resized.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: targetSize))
            resized.unlockFocus()
            guard let resizedTiff = resized.tiffRepresentation,
                  let newBitmap = NSBitmapImageRep(data: resizedTiff) else {
                return nil
            }
            resizedBitmap = newBitmap
        } else {
            resizedBitmap = bitmap
        }

        guard let jpegData = resizedBitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return nil
        }

        let base64 = jpegData.base64EncodedString()
        return "data:image/jpeg;base64,\(base64)"
    }
}
