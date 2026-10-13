import Foundation

/// Minimal HTTP/1.1 support for the loopback bridge used by the Safari agent
/// extension. Only what the extension sends is supported: a request line,
/// headers and an optional `Content-Length` body. Each connection serves one
/// request and is then closed.
struct SafariAgentHTTPRequest: Equatable {
    let method: String
    let path: String
    /// Header names are lowercased; repeated headers are joined with ", ".
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

enum SafariAgentHTTPParseResult: Equatable {
    case incomplete
    case complete(SafariAgentHTTPRequest)
    case invalid(status: Int, reason: String)
}

enum SafariAgentHTTPParser {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 8 * 1024 * 1024

    static func parse(_ input: Data) -> SafariAgentHTTPParseResult {
        let buffer = Data(input)
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeaderBytes
                ? .invalid(status: 431, reason: "Request headers too large")
                : .incomplete
        }
        guard headerEnd.lowerBound <= maxHeaderBytes else {
            return .invalid(status: 431, reason: "Request headers too large")
        }
        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400, reason: "Request headers are not UTF-8")
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            return .invalid(status: 400, reason: "Malformed request line")
        }
        let method = parts[0].uppercased()
        let target = String(parts[1])
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard path.hasPrefix("/") else {
            return .invalid(status: 400, reason: "Unsupported request target")
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(status: 400, reason: "Malformed header")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                return .invalid(status: 400, reason: "Malformed header")
            }
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        if headers["transfer-encoding"] != nil {
            return .invalid(status: 501, reason: "Chunked request bodies are not supported")
        }

        var contentLength = 0
        if let rawLength = headers["content-length"] {
            guard let length = Int(rawLength), length >= 0 else {
                return .invalid(status: 400, reason: "Invalid Content-Length")
            }
            contentLength = length
        }
        guard contentLength <= maxBodyBytes else {
            return .invalid(status: 413, reason: "Request body too large")
        }

        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= contentLength else {
            return .incomplete
        }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return .complete(SafariAgentHTTPRequest(method: method, path: path, headers: headers, body: body))
    }
}

enum SafariAgentHTTPResponse {
    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 412: return "Precondition Failed"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    static func head(status: Int, headers: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }

    /// CORS headers are only ever emitted for the extension's own origin; the
    /// authorizer rejects every other origin before a response is built.
    static func corsHeaders(origin: String?) -> [(String, String)] {
        guard let origin, SafariAgentAuthorizer.isExtensionOrigin(origin) else {
            return []
        }
        return [
            ("Access-Control-Allow-Origin", origin),
            ("Access-Control-Allow-Headers", "Authorization, Content-Type"),
            ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
            ("Vary", "Origin")
        ]
    }

    static func json(status: Int, object: Any, origin: String?) -> Data {
        let body = encodeJSON(object)
        var headers: [(String, String)] = [
            ("Content-Type", "application/json; charset=utf-8"),
            ("Content-Length", String(body.count)),
            ("Cache-Control", "no-store")
        ]
        headers += corsHeaders(origin: origin)
        return head(status: status, headers: headers) + body
    }

    static func error(status: Int, message: String, origin: String?) -> Data {
        json(status: status, object: ["ok": false, "error": message], origin: origin)
    }

    static func eventStreamHead(origin: String?) -> Data {
        var headers: [(String, String)] = [
            ("Content-Type", "text/event-stream; charset=utf-8"),
            ("Cache-Control", "no-store"),
            ("X-Accel-Buffering", "no")
        ]
        headers += corsHeaders(origin: origin)
        return head(status: 200, headers: headers)
    }

    static func event(_ object: [String: Any]) -> Data {
        Data("data: ".utf8) + encodeJSON(object) + Data("\n\n".utf8)
    }

    static func encodeJSON(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
