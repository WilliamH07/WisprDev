import Foundation
import os
import os.log

private let localInferenceLog = OSLog(subsystem: "com.williamh07.wisper", category: "LocalInference")

public final class LocalInferenceService: @unchecked Sendable {
    public static let shared = LocalInferenceService()

    public static let defaultOllamaBaseURL = "http://127.0.0.1:11434/v1"
    public static let defaultLlamaServerBaseURL = "http://127.0.0.1:8080/v1"
    public static let default3BModel = "llama3.2:3b"

    private init() {}

    // MARK: - Server & CLI Path Resolvers

    /// Search directories for whisper-server binary
    public var whisperServerPath: String? {
        let candidates = [
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server",
            Bundle.main.path(forResource: "whisper-server", ofType: nil)
        ].compactMap { $0 }

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Search directories for whisper-cli binary
    public var whisperCliPath: String? {
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            Bundle.main.path(forResource: "whisper-cli", ofType: nil)
        ].compactMap { $0 }

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Storage key for user-selected local whisper model
    public static let selectedModelKey = "local_whisper_model_name"
    public static let defaultModelFilename = "ggml-large-v3-turbo.bin"
    public static let defaultDeveloperPrompt = "Vocabulaire technique et programmation : SQL, PostgreSQL, MySQL, SQLite, Docker, Kubernetes, Redis, API, FastAPI, Python, TypeScript, JavaScript, React, Next.js, Git, GitHub, PR, rate limiter, refactorer, endpoint, frontend, backend."

    public var selectedModelFilename: String {
        get {
            let saved = UserDefaults.standard.string(forKey: Self.selectedModelKey)
            if let saved, !saved.isEmpty {
                return saved
            }
            return Self.defaultModelFilename
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.selectedModelKey)
        }
    }

    /// Models storage directory: ~/Library/Application Support/WisprFlow/models
    public static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("WisprFlow/models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: modelsDir.path) {
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        }
        return modelsDir
    }

    /// Find available GGML Whisper models in priority order
    public var availableWhisperModels: [URL] {
        let dir = Self.modelsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "bin" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Active Whisper model URL based on selection or fallback
    public var preferredWhisperModelURL: URL? {
        let models = availableWhisperModels
        let selected = selectedModelFilename
        if let match = models.first(where: { $0.lastPathComponent == selected }) {
            return match
        }
        // Fallback: turbo first for high accuracy on dev/technical terms, then small, then base
        if let turbo = models.first(where: { $0.lastPathComponent.contains("large-v3-turbo") }) {
            return turbo
        }
        if let small = models.first(where: { $0.lastPathComponent.contains("small") }) {
            return small
        }
        if let base = models.first(where: { $0.lastPathComponent.contains("base") }) {
            return base
        }
        return models.first
    }

    public var isLocalWhisperAvailable: Bool {
        return (whisperServerPath != nil || whisperCliPath != nil) && preferredWhisperModelURL != nil
    }

    // MARK: - Whisper Server Daemon Management

    public static let whisperServerPort: Int = 8085
    public static let whisperServerBaseURL: String = "http://127.0.0.1:\(whisperServerPort)"

    private let serverProcessLock = OSAllocatedUnfairLock<Process?>(initialState: nil)
    private let serverModelPathLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Check if whisper-server is actively responding on port 8085
    public func checkServerHealth() async -> Bool {
        guard let url = URL(string: "\(Self.whisperServerBaseURL)/") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.4
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Ensures whisper-server is warm in memory on Apple Silicon Metal GPU
    @discardableResult
    public func ensureServerRunning() async -> Bool {
        guard let serverBinary = whisperServerPath else {
            os_log(.info, log: localInferenceLog, "whisper-server binary not found, using whisper-cli")
            return false
        }

        guard let modelURL = preferredWhisperModelURL else {
            os_log(.error, log: localInferenceLog, "No Whisper model available to start server")
            return false
        }

        let isHealthy = await checkServerHealth()
        if isHealthy {
            serverModelPathLock.withLock { $0 = modelURL.path }
            return true
        }

        let isRunning = serverProcessLock.withLock { proc in
            proc?.isRunning ?? false
        }
        if isRunning {
            return true
        }

        os_log(.info, log: localInferenceLog, "Starting resident whisper-server on port %d with model %{public}@", Self.whisperServerPort, modelURL.lastPathComponent)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverBinary)
        process.arguments = [
            "-m", modelURL.path,
            "--port", "\(Self.whisperServerPort)",
            "--host", "127.0.0.1",
            "-l", "auto",
            "-t", "8",
            "-bs", "1",
            "-bo", "1"
        ]

        let devNull = FileHandle.nullDevice
        process.standardOutput = devNull
        process.standardError = devNull

        do {
            try process.run()
            serverProcessLock.withLock { proc in
                proc = process
            }
            serverModelPathLock.withLock { path in
                path = modelURL.path
            }

            // Wait up to 2.5s for server startup
            for _ in 0..<25 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if await checkServerHealth() {
                    os_log(.info, log: localInferenceLog, "Resident whisper-server successfully started and healthy")
                    return true
                }
            }
            return false
        } catch {
            os_log(.error, log: localInferenceLog, "Failed to start whisper-server process: %{public}@", error.localizedDescription)
            return false
        }
    }

    /// Clean shutdown of whisper-server process
    public func stopServer() {
        serverProcessLock.withLock { proc in
            if let p = proc, p.isRunning {
                os_log(.info, log: localInferenceLog, "Terminating resident whisper-server process")
                p.terminate()
            }
            proc = nil
        }
        serverModelPathLock.withLock { path in
            path = nil
        }
    }

    /// Restarts whisper-server (e.g. after model switch)
    public func restartServer() async -> Bool {
        stopServer()
        try? await Task.sleep(nanoseconds: 200_000_000)
        return await ensureServerRunning()
    }

    // MARK: - Local LLM Detection

    /// Checks if Ollama is running and responding
    public func checkOllamaHealth(baseURL: String = defaultOllamaBaseURL) async -> Bool {
        guard let url = URL(string: baseURL)?.deletingLastPathComponent().appendingPathComponent("api/tags") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Local Whisper Transcription

    public enum LocalWhisperError: LocalizedError {
        case binaryNotFound
        case modelNotFound
        case executionFailed(Int32, String)
        case emptyOutput
        case serverError(String)

        public var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "whisper-cli et whisper-server introuvables dans /opt/homebrew/bin/"
            case .modelNotFound:
                return "Modèle Whisper introuvable dans ~/Library/Application Support/WisprFlow/models/"
            case .executionFailed(let code, let msg):
                return "Échec de whisper-cli (code \(code)): \(msg)"
            case .emptyOutput:
                return "Aucun texte détecté par Whisper local."
            case .serverError(let msg):
                return "Erreur du serveur Whisper résident: \(msg)"
            }
        }
    }

    /// Transcribes an audio file.
    /// Fast path: Uses resident in-memory Metal whisper-server (~150ms).
    /// Fallback path: Uses on-demand whisper-cli.
    public func transcribe(audioURL: URL, language: String? = nil, prompt: String? = nil) async throws -> String {
        let modelName = preferredWhisperModelURL?.lastPathComponent ?? "?"
        var serverIssue = whisperServerPath == nil ? "binaire whisper-server absent" : ""
        // Fast path: try resident whisper-server
        if whisperServerPath != nil {
            let isReady = await ensureServerRunning()
            if isReady {
                do {
                    let result = try await transcribeViaServer(audioURL: audioURL, language: language, prompt: prompt)
                    if !result.isEmpty {
                        lastEngineLock.withLock { $0 = "Whisper local · serveur résident · \(modelName)" }
                        return result
                    }
                    serverIssue = "réponse vide"
                } catch {
                    serverIssue = "erreur serveur"
                    os_log(.error, log: localInferenceLog, "whisper-server request failed, falling back to CLI: %{public}@", error.localizedDescription)
                }
            } else {
                serverIssue = "serveur non démarré"
            }
        }

        // Fallback: run CLI (reloads the model on every call, so it is slow)
        let result = try await transcribeViaCli(audioURL: audioURL, language: language, prompt: prompt)
        lastEngineLock.withLock { $0 = "Whisper local · CLI à froid · \(modelName) (\(serverIssue))" }
        return result
    }

    private let lastEngineLock = OSAllocatedUnfairLock<String>(initialState: "")

    /// Human-readable description of the last local transcription path (no user content).
    public var lastEngineDescription: String {
        lastEngineLock.withLock { $0 }
    }

    /// Fast resident inference via HTTP multipart to whisper-server (< 250ms)
    private func transcribeViaServer(audioURL: URL, language: String? = nil, prompt: String? = nil) async throws -> String {
        guard let url = URL(string: "\(Self.whisperServerBaseURL)/inference") else {
            throw LocalWhisperError.serverError("URL invalide")
        }

        let audioData = try Data(contentsOf: audioURL)
        let boundary = "Boundary-\(UUID().uuidString)"

        var body = Data()
        let prefix = "--\(boundary)\r\n"

        // file
        body.append(Data(prefix.utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n".utf8))

        // response_format
        body.append(Data(prefix.utf8))
        body.append(Data("Content-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n".utf8))

        // prompt
        let devPrompt = Self.defaultDeveloperPrompt
        let effectivePrompt = if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            "\(prompt), \(devPrompt)"
        } else {
            devPrompt
        }
        body.append(Data(prefix.utf8))
        body.append(Data("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\(effectivePrompt)\r\n".utf8))

        // language: explicitly send language or auto to prevent whisper-server from defaulting to English
        let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let effectiveLanguage = if let lang, !lang.isEmpty {
            lang
        } else {
            "auto"
        }
        body.append(Data(prefix.utf8))
        body.append(Data("Content-Disposition: form-data; name=\"language\"\r\n\r\n\(effectiveLanguage)\r\n".utf8))

        // close multipart
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10.0

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Status code non-200"
            throw LocalWhisperError.serverError(errorText)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw LocalWhisperError.emptyOutput
        }

        let cleaned = text
            .replacingOccurrences(of: "\\[_BEG_\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[BLANK_AUDIO\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        os_log(.info, log: localInferenceLog, "whisper-server transcribed %ld characters in-memory", cleaned.count)
        return cleaned
    }

    /// On-demand CLI transcription using whisper-cli on Apple Silicon Metal GPU
    public func transcribeViaCli(audioURL: URL, language: String? = nil, prompt: String? = nil) async throws -> String {
        guard let cliPath = whisperCliPath else {
            throw LocalWhisperError.binaryNotFound
        }
        guard let modelURL = preferredWhisperModelURL else {
            throw LocalWhisperError.modelNotFound
        }

        os_log(.info, log: localInferenceLog, "Running local whisper-cli on: %{public}@ with model: %{public}@", audioURL.lastPathComponent, modelURL.lastPathComponent)

        let devPrompt = Self.defaultDeveloperPrompt
        let effectivePrompt = if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            "\(prompt), \(devPrompt)"
        } else {
            devPrompt
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: cliPath)

                var arguments: [String] = [
                    "-m", modelURL.path,
                    "-f", audioURL.path,
                    "-nt", // no timestamps
                    "-np", // no progress / no prints
                    "-t", "8",
                    "-bs", "1",
                    "--prompt", effectivePrompt
                ]

                // Language handling: default to French/auto
                let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let lang, !lang.isEmpty, lang != "auto" {
                    arguments.append(contentsOf: ["-l", lang])
                } else {
                    arguments.append(contentsOf: ["-l", "auto"])
                }

                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let stdoutText = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if process.terminationStatus == 0 {
                        let cleaned = stdoutText
                            .replacingOccurrences(of: "\\[_BEG_\\]", with: "", options: .regularExpression)
                            .replacingOccurrences(of: "\\[BLANK_AUDIO\\]", with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        os_log(.info, log: localInferenceLog, "whisper-cli transcribed %ld characters successfully", cleaned.count)
                        continuation.resume(returning: cleaned)
                    } else {
                        os_log(.error, log: localInferenceLog, "whisper-cli failed with exit %d: %{public}@", process.terminationStatus, stderrText)
                        continuation.resume(throwing: LocalWhisperError.executionFailed(process.terminationStatus, stderrText))
                    }
                } catch {
                    os_log(.error, log: localInferenceLog, "Process execution error: %{public}@", error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
