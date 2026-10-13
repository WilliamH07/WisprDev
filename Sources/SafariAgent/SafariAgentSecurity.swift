import Foundation

/// Pairing between Wisper and the Safari extension. The user copies a code
/// from Wisper's settings into the extension once; the code carries the
/// loopback port and a random bearer token required on every request.
enum SafariAgentPairing {
    static let codePrefix = "wisper-agent"
    static let defaultPort: UInt16 = 47821

    static func generateToken<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for _ in 0..<32 {
            bytes.append(UInt8.random(in: .min ... .max, using: &generator))
        }
        return base64URL(Data(bytes))
    }

    /// `SystemRandomNumberGenerator` is cryptographically secure on Apple platforms.
    static func generateToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return generateToken(using: &generator)
    }

    static func pairingCode(port: UInt16, token: String) -> String {
        "\(codePrefix):\(port):\(token)"
    }

    static func parsePairingCode(_ code: String) -> (port: UInt16, token: String)? {
        let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 3,
              parts[0] == Substring(codePrefix),
              let port = UInt16(parts[1]),
              port >= 1024,
              isValidToken(String(parts[2])) else {
            return nil
        }
        return (port, String(parts[2]))
    }

    static func isValidToken(_ token: String) -> Bool {
        (32...128).contains(token.count) && token.unicodeScalars.allSatisfy { scalar in
            (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)) || scalar == "-" || scalar == "_"
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum SafariAgentRequestDecision: Equatable {
    case allow
    case preflight
    case reject(status: Int, reason: String)
}

/// Decides whether a loopback request may reach the agent. Web pages can send
/// requests to 127.0.0.1 too, so every request must carry the pairing token,
/// browser requests must come from a Safari extension origin, and the Host
/// header must name the loopback interface (defeats DNS rebinding).
enum SafariAgentAuthorizer {
    static func decide(
        request: SafariAgentHTTPRequest,
        expectedToken: String,
        port: UInt16
    ) -> SafariAgentRequestDecision {
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.header("host")?.lowercased(), allowedHosts.contains(host) else {
            return .reject(status: 403, reason: "Unexpected Host header")
        }

        let origin = request.header("origin")
        if let origin, !isExtensionOrigin(origin) {
            return .reject(status: 403, reason: "Origin not allowed")
        }

        if request.method == "OPTIONS" {
            return origin == nil ? .reject(status: 403, reason: "Origin required") : .preflight
        }

        guard !expectedToken.isEmpty,
              let authorization = request.header("authorization"),
              authorization.hasPrefix("Bearer ") else {
            return .reject(status: 401, reason: "Missing pairing token")
        }
        let provided = String(authorization.dropFirst("Bearer ".count))
        guard constantTimeEquals(provided, expectedToken) else {
            return .reject(status: 401, reason: "Invalid pairing token")
        }
        return .allow
    }

    static func isExtensionOrigin(_ origin: String) -> Bool {
        let lowered = origin.lowercased()
        return lowered.hasPrefix("safari-web-extension://") && lowered.count > "safari-web-extension://".count
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}
