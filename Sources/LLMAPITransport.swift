import Foundation

enum LLMAPITransport {
    private static func makeEphemeralSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // URLSession's resource timeout is session-scoped, while each caller
        // already puts its configured timeout on the URLRequest. Keep both
        // session timers aligned with that request instead of applying one
        // global timeout to every provider and operation.
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    private static func timeout(for request: URLRequest) -> TimeInterval {
        let requestTimeout = request.timeoutInterval
        guard requestTimeout.isFinite, requestTimeout > 0 else {
            return 60
        }
        return requestTimeout
    }

    /// One long-lived session so HTTP keep-alive and TLS session reuse apply.
    /// A cold DNS + TCP + TLS handshake costs 100-400 ms per request, and the
    /// dictation pipeline makes two sequential calls (transcribe, then clean up).
    /// The per-request timeout still comes from `URLRequest.timeoutInterval`.
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    /// A reused connection can be closed by the server while idle. That surfaces
    /// as "network connection lost"; retry once on a brand-new session.
    private static func isStaleConnectionError(_ error: Error) -> Bool {
        (error as? URLError)?.code == .networkConnectionLost
    }

    static func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        do {
            return try await sharedSession.data(for: request)
        } catch where isStaleConnectionError(error) {
            let session = makeEphemeralSession(timeout: timeout(for: request))
            defer { session.finishTasksAndInvalidate() }
            return try await session.data(for: request)
        }
    }

    static func upload(
        for request: URLRequest,
        from bodyData: Data
    ) async throws -> (Data, URLResponse) {
        do {
            return try await sharedSession.upload(for: request, from: bodyData)
        } catch where isStaleConnectionError(error) {
            let session = makeEphemeralSession(timeout: timeout(for: request))
            defer { session.finishTasksAndInvalidate() }
            return try await session.upload(for: request, from: bodyData)
        }
    }

    /// Opens (and keeps alive) the TLS connection to each HTTPS provider host
    /// while the user is still speaking, so the first real request skips the
    /// handshake. Sends an unauthenticated HEAD to the host root: no audio, text,
    /// key, or other user content is transmitted. Local hosts are skipped.
    static func prewarm(baseURLs: [String]) {
        var seenHosts = Set<String>()
        for raw in baseURLs {
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme?.lowercased() == "https",
                  let host = url.host,
                  seenHosts.insert(host).inserted,
                  let root = URL(string: "https://\(host)/") else { continue }
            var request = URLRequest(url: root)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            sharedSession.dataTask(with: request).resume()
        }
    }

    private static let streamingSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    static func bytes(
        for request: URLRequest
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        return try await streamingSession.bytes(for: request)
    }
}
