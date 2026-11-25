import Foundation
package import NetPolicy

/// Name-authoritative HTTP `CONNECT` proxy decision engine (V2 / N-V3): parses a guest `CONNECT host:port HTTP/1.1`
/// request line strictly, resolves `host` on the host side via `resolve`, evaluates **both** the requested name and all
/// resolved addresses through `NetworkPolicy.evaluate(host:port:resolvedAddresses:)`, and returns the exact pinned
/// `IPAddress` list to dial — preventing DNS rebinding, IP-literal bypasses, and shared-CDN host spoofing.
///
/// Designed to run inside the App-Sandboxed `VMHelper` over a vsock channel when a guest has no NIC (`networkMode = .none`
/// + proxy vsock) or in strict allow-listed agent mode.
package struct ConnectProxyAuthorizer: Sendable {
    package struct Target: Equatable, Sendable {
        package let host: String
        package let port: UInt16
    }

    package enum Outcome: Equatable, Sendable {
        /// Connection permitted; the caller **must** dial one of `pinnedAddresses` (never re-resolve `target.host`).
        case allow(target: Target, pinnedAddresses: [IPAddress])
        /// Connection refused with HTTP status code and reason.
        case deny(statusCode: Int, reason: String)
    }

    /// Maximum accepted CONNECT request header length (8 KiB).
    package static let maximumHeaderBytes = 8_192

    private let policy: NetworkPolicy
    private let resolve: @Sendable (String) async -> [IPAddress]
    private let exemptedFloorKinds: Set<ReservedRangeKind>

    package init(
        policy: NetworkPolicy,
        exemptedFloorKinds: Set<ReservedRangeKind> = [],
        resolve: @escaping @Sendable (String) async -> [IPAddress]
    ) {
        self.policy = policy
        self.exemptedFloorKinds = exemptedFloorKinds
        self.resolve = resolve
    }

    /// Parses a raw HTTP `CONNECT` request block (up to `\r\n\r\n`) into its `host:port` target.
    /// Rejects non-CONNECT methods, oversized headers, control characters, missing/invalid ports, and malformed IPv6 brackets.
    package static func parseRequestLine(_ raw: String) -> Target? {
        guard raw.utf8.count <= maximumHeaderBytes else { return nil }
        guard let firstLine = raw.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
            parts[0] == "CONNECT",
            parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
        else { return nil }
        let authority = String(parts[1])
        guard !authority.isEmpty,
            authority.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }),
            !authority.contains("/"), !authority.contains("@"), !authority.contains("\\")
        else { return nil }
        return splitAuthority(authority)
    }

    /// Evaluates a raw `CONNECT` request against `policy` using host-side resolution and returns pinned dial addresses.
    package func authorize(_ rawRequest: String) async -> Outcome {
        guard let target = Self.parseRequestLine(rawRequest) else {
            return .deny(statusCode: 400, reason: "malformed CONNECT request")
        }
        let resolved: [IPAddress]
        if let literal = IPAddress(strictLiteral: target.host) {
            resolved = [literal]
        } else {
            resolved = await resolve(target.host.lowercased())
        }
        let decision = policy.evaluate(
            host: target.host,
            port: target.port,
            resolvedAddresses: resolved,
            exempting: exemptedFloorKinds
        )
        switch decision {
        case .allow:
            guard !resolved.isEmpty else {
                return .deny(statusCode: 502, reason: "unresolved destination")
            }
            return .allow(target: target, pinnedAddresses: resolved)
        case .deny(let reason):
            return .deny(statusCode: 403, reason: "\(reason)")
        }
    }

    /// Standard HTTP response bytes to send back to the guest over vsock/TCP for `outcome`.
    package static func httpResponse(for outcome: Outcome) -> String {
        switch outcome {
        case .allow:
            return "HTTP/1.1 200 Connection Established\r\n\r\n"
        case .deny(let code, let reason):
            let title = code == 400 ? "Bad Request" : (code == 502 ? "Bad Gateway" : "Forbidden")
            let body = "\(reason)\n"
            return "HTTP/1.1 \(code) \(title)\r\n"
                + "Content-Type: text/plain; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n"
                + body
        }
    }

    private static func splitAuthority(_ authority: String) -> Target? {
        let host: String
        let portString: Substring
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let after = authority.index(after: close)
            guard after < authority.endIndex, authority[after] == ":" else { return nil }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            portString = authority[authority.index(after: after)...]
        } else {
            guard let colon = authority.lastIndex(of: ":"),
                authority.firstIndex(of: ":") == colon
            else { return nil }
            host = String(authority[..<colon])
            portString = authority[authority.index(after: colon)...]
        }
        guard !host.isEmpty,
            let port = UInt16(portString),
            port > 0
        else { return nil }
        return Target(host: host, port: port)
    }
}
