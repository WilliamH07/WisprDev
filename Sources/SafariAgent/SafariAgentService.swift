import AppKit
import Foundation
import os.log

private let agentLog = OSLog(subsystem: "com.williamh07.wisper", category: "SafariAgent")

/// Wisper side of the Safari agent: a loopback server the Safari extension
/// talks to, the PDF libraries, and the bridge to the existing OpenRouter
/// streaming. Off by default; nothing listens until the user enables it.
@MainActor
final class SafariAgentService: ObservableObject {
    static let shared = SafariAgentService()

    enum ServerState: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    private enum Keys {
        static let enabled = "safari_agent_enabled"
        static let port = "safari_agent_port"
        static let pageBudget = "safari_agent_page_budget_tokens"
        static let libraryBudget = "safari_agent_library_budget_tokens"
        static let tokenAccount = "safari_agent_pairing_token"
    }

    static let pageBudgetRange = 2000...24000
    static let libraryBudgetRange = 1000...16000

    @Published private(set) var serverState: ServerState = .stopped
    @Published private(set) var token: String

    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                start()
                libraries.warmAll()
            } else {
                stop()
            }
        }
    }

    @Published var port: UInt16 {
        didSet {
            guard oldValue != port else { return }
            UserDefaults.standard.set(Int(port), forKey: Keys.port)
            if isEnabled {
                start()
            }
        }
    }

    @Published var pageBudgetTokens: Int {
        didSet { UserDefaults.standard.set(pageBudgetTokens, forKey: Keys.pageBudget) }
    }

    @Published var libraryBudgetTokens: Int {
        didSet { UserDefaults.standard.set(libraryBudgetTokens, forKey: Keys.libraryBudget) }
    }

    let libraries: ReferenceLibraryManager

    private lazy var server = SafariAgentServer { [weak self] request, responder in
        Task { @MainActor in
            self?.handle(request, responder: responder)
        }
    }

    private var apiKeyProvider: () -> String = { "" }
    private var defaultModelProvider: () -> String = { AIAssistantModel.gpt4oMini.rawValue }
    private var lastPrewarm = Date.distantPast

    // In-memory caches only; page text is never written to disk.
    private var preparedPages: [UInt64: SafariAgentPreparedPage] = [:]
    private var preparedOrder: [UInt64] = []
    private var frozenPages: [String: SafariAgentFrozenPage] = [:]
    private var frozenOrder: [String] = []

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Keys.enabled)
        let storedPort = defaults.integer(forKey: Keys.port)
        port = (1024...65535).contains(storedPort) ? UInt16(storedPort) : SafariAgentPairing.defaultPort
        let storedPage = defaults.integer(forKey: Keys.pageBudget)
        pageBudgetTokens = Self.pageBudgetRange.contains(storedPage) ? storedPage : SafariAgentContextBudget().pageTokens
        let storedLibrary = defaults.integer(forKey: Keys.libraryBudget)
        libraryBudgetTokens = Self.libraryBudgetRange.contains(storedLibrary) ? storedLibrary : SafariAgentContextBudget().libraryTokens

        if let stored = AppSettingsStorage.load(account: Keys.tokenAccount), SafariAgentPairing.isValidToken(stored) {
            token = stored
        } else {
            let generated = SafariAgentPairing.generateToken()
            AppSettingsStorage.save(generated, account: Keys.tokenAccount)
            token = generated
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let catalogURL = appSupport
            .appendingPathComponent(AppName.displayName, isDirectory: true)
            .appendingPathComponent("safari-agent-libraries.json")
        libraries = ReferenceLibraryManager(catalogURL: catalogURL)
    }

    var pairingCode: String {
        SafariAgentPairing.pairingCode(port: port, token: token)
    }

    func configure(apiKeyProvider: @escaping () -> String, defaultModelProvider: @escaping () -> String) {
        self.apiKeyProvider = apiKeyProvider
        self.defaultModelProvider = defaultModelProvider
        if isEnabled {
            start()
            libraries.warmAll()
        }
    }

    /// Invalidates the code pasted in the extension; it must be paired again.
    func regenerateToken() {
        let generated = SafariAgentPairing.generateToken()
        AppSettingsStorage.save(generated, account: Keys.tokenAccount)
        token = generated
    }

    // MARK: Server lifecycle

    private func start() {
        serverState = .starting
        let port = self.port
        server.start(port: port) { [weak self] event in
            Task { @MainActor in
                guard let self, self.isEnabled, self.port == port else { return }
                switch event {
                case .ready:
                    self.serverState = .running(port: port)
                case .failed(let message):
                    self.serverState = .failed(message)
                }
            }
        }
    }

    private func stop() {
        server.stop()
        serverState = .stopped
        preparedPages.removeAll()
        preparedOrder.removeAll()
        frozenPages.removeAll()
        frozenOrder.removeAll()
    }

    // MARK: Routing

    private func handle(_ request: SafariAgentHTTPRequest, responder: SafariAgentResponder) {
        guard isEnabled else {
            responder.respondError(status: 503, message: "L'agent Safari est désactivé dans Wisper.")
            return
        }
        switch SafariAgentAuthorizer.decide(request: request, expectedToken: token, port: port) {
        case .reject(let status, let reason):
            responder.respondError(status: status, message: reason)
            return
        case .preflight:
            responder.send(SafariAgentHTTPResponse.head(status: 204, headers: SafariAgentHTTPResponse.corsHeaders(origin: responder.origin)))
            responder.finish()
            return
        case .allow:
            break
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/status"):
            responder.respond(status: 200, json: statusPayload())
        case ("POST", "/v1/warmup"):
            warmup(request.body)
            responder.respond(status: 200, json: statusPayload())
        case ("POST", "/v1/chat"):
            chat(request.body, responder: responder)
        default:
            responder.respondError(status: 404, message: "Route inconnue")
        }
    }

    private func statusPayload() -> [String: Any] {
        [
            "ok": true,
            "app": AppName.displayName,
            "hasAPIKey": !apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "defaultModel": defaultModelProvider(),
            "models": AIAssistantModel.allCases.map { ["id": $0.rawValue, "name": $0.shortName] },
            "libraries": libraries.statusPayload()
        ]
    }

    /// Sent by the extension as soon as the panel opens, while the user is
    /// still typing: reopens the TLS connection to OpenRouter, starts library
    /// indexing and pre-chunks the page so the question only pays for ranking.
    private func warmup(_ body: Data) {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        if Date().timeIntervalSince(lastPrewarm) > 15 {
            LLMAPITransport.prewarm(baseURLs: ["https://openrouter.ai/api/v1"])
            lastPrewarm = Date()
        }
        if let libraryID = (object["libraryId"] as? String).flatMap(UUID.init(uuidString:)) {
            libraries.warm(libraryID)
        }
        if let page = SafariAgentPage(json: object["page"]) {
            Task { _ = await self.preparedPage(for: page) }
        }
    }

    private func chat(_ body: Data, responder: SafariAgentResponder) {
        let chatRequest: SafariAgentChatRequest
        do {
            chatRequest = try SafariAgentChatRequest.decode(body)
        } catch {
            responder.respondError(status: 400, message: "Requête invalide")
            return
        }

        let apiKey = apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            responder.respondError(status: 412, message: "Clé API OpenRouter manquante : ajoutez-la dans Wisper → Réglages → Intelligence IA.")
            return
        }

        let defaultModel = defaultModelProvider()
        let knownModels = Set(AIAssistantModel.allCases.map(\.rawValue)).union([defaultModel])
        let model = knownModels.contains(chatRequest.model) ? chatRequest.model : defaultModel
        let budget = SafariAgentContextBudget(pageTokens: pageBudgetTokens, libraryTokens: libraryBudgetTokens)
        let started = Date()

        Task { @MainActor in
            var prepared: SafariAgentPreparedPage?
            if let page = chatRequest.page {
                prepared = await self.preparedPage(for: page)
            }
            var library: ReferenceLibrarySnapshot?
            if let libraryID = chatRequest.libraryID {
                library = await self.libraries.snapshot(for: libraryID)
            }
            guard !responder.isClosed else { return }

            let frozen = self.frozenPages[chatRequest.conversationID]
            let pageForPrompt = prepared
            let libraryForPrompt = library
            let built = await Task.detached(priority: .userInitiated) {
                SafariAgentPromptBuilder.build(
                    request: chatRequest,
                    page: pageForPrompt,
                    frozenPage: frozen,
                    library: libraryForPrompt,
                    budget: budget
                )
            }.value
            if let frozenPage = built.frozenPage {
                self.remember(frozenPage, for: chatRequest.conversationID)
            }

            let preparationMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
            os_log(
                .info,
                log: agentLog,
                "Safari agent prompt ready in %d ms (page %d tokens, library %d tokens)",
                preparationMilliseconds,
                built.stats.pageTokens,
                built.stats.libraryTokens
            )

            responder.startEventStream()
            var meta = built.stats.json
            meta["type"] = "meta"
            meta["model"] = model
            meta["preparationMs"] = preparationMilliseconds
            responder.sendEvent(meta)

            let messages = built.messages(cacheControl: model.hasPrefix("anthropic/"))
            let stream = AIAssistantService.shared.streamChatCompletion(
                model: model,
                apiKey: apiKey,
                // Ask OpenRouter for the provider with the lowest latency.
                extraPayload: ["provider": ["sort": "latency"]]
            ) { messages }

            let streamTask = Task.detached(priority: .userInitiated) {
                do {
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        responder.sendEvent(["type": "delta", "text": chunk])
                    }
                    responder.sendEvent(["type": "done"])
                } catch {
                    if !Task.isCancelled {
                        responder.sendEvent(["type": "error", "message": error.localizedDescription])
                    }
                }
                responder.finish()
            }
            responder.onClose {
                streamTask.cancel()
            }
        }
    }

    // MARK: Caches

    private func preparedPage(for page: SafariAgentPage) async -> SafariAgentPreparedPage {
        let hash = page.contentHash
        if let cached = preparedPages[hash] {
            return cached
        }
        let prepared = await Task.detached(priority: .userInitiated) {
            SafariAgentPreparedPage(page: page)
        }.value
        preparedPages[hash] = prepared
        preparedOrder.removeAll { $0 == hash }
        preparedOrder.append(hash)
        while preparedOrder.count > 8 {
            preparedPages[preparedOrder.removeFirst()] = nil
        }
        return prepared
    }

    private func remember(_ frozen: SafariAgentFrozenPage, for conversationID: String) {
        frozenPages[conversationID] = frozen
        frozenOrder.removeAll { $0 == conversationID }
        frozenOrder.append(conversationID)
        while frozenOrder.count > 30 {
            frozenPages[frozenOrder.removeFirst()] = nil
        }
    }
}
