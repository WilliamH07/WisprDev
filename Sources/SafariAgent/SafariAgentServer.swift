import Foundation
import Network
import os.log

private let serverLog = OSLog(subsystem: "com.williamh07.wisper", category: "SafariAgentServer")

/// Writes the response for one request. Every connection carries a single
/// request; the connection closes once the response is finished.
final class SafariAgentResponder: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var isFinished = false
    private var closeHandlers: [() -> Void] = []

    let origin: String?

    init(connection: NWConnection, origin: String?) {
        self.connection = connection
        self.origin = origin
    }

    /// Called once when the client goes away or the response finishes, so a
    /// streaming model request can be cancelled as soon as Safari stops reading.
    func onClose(_ handler: @escaping () -> Void) {
        lock.lock()
        if isFinished {
            lock.unlock()
            handler()
            return
        }
        closeHandlers.append(handler)
        lock.unlock()
    }

    func send(_ data: Data) {
        lock.lock()
        let finished = isFinished
        lock.unlock()
        guard !finished else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.finish()
            }
        })
    }

    func respond(status: Int, json: Any) {
        send(SafariAgentHTTPResponse.json(status: status, object: json, origin: origin))
        finish()
    }

    func respondError(status: Int, message: String) {
        send(SafariAgentHTTPResponse.error(status: status, message: message, origin: origin))
        finish()
    }

    func startEventStream() {
        send(SafariAgentHTTPResponse.eventStreamHead(origin: origin))
    }

    func sendEvent(_ object: [String: Any]) {
        send(SafariAgentHTTPResponse.event(object))
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let handlers = closeHandlers
        closeHandlers = []
        lock.unlock()

        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
        handlers.forEach { $0() }
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }
}

/// Loopback-only HTTP listener for the Safari agent extension. It binds to
/// 127.0.0.1 and additionally drops any connection whose remote end is not a
/// loopback address.
final class SafariAgentServer {
    typealias Handler = (SafariAgentHTTPRequest, SafariAgentResponder) -> Void

    enum Event {
        case ready
        case failed(String)
    }

    private let queue = DispatchQueue(label: "com.williamh07.wisper.safari-agent-server")
    private var listener: NWListener?
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start(port: UInt16, onEvent: @escaping (Event) -> Void) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onEvent(.failed("Port invalide"))
            return
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            onEvent(.failed(error.localizedDescription))
            return
        }

        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                onEvent(.ready)
            case .failed(let error):
                os_log(.error, log: serverLog, "Safari agent listener failed: %{public}@", error.localizedDescription)
                onEvent(.failed(error.localizedDescription))
                listener?.cancel()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.isLoopback
        case .ipv6(let address):
            return address.isLoopback
        default:
            return false
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            switch SafariAgentHTTPParser.parse(buffer) {
            case .complete(let request):
                let responder = SafariAgentResponder(connection: connection, origin: request.header("origin"))
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .failed, .cancelled:
                        responder.finish()
                    default:
                        break
                    }
                }
                self.handler(request, responder)
            case .invalid(let status, let reason):
                SafariAgentResponder(connection: connection, origin: nil).respondError(status: status, message: reason)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }
}
