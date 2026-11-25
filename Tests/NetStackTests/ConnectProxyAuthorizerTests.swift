import Foundation
import NetPolicy
import Testing

@testable import NetStack

/// Name-authoritative CONNECT proxy authorizer (V2 / N-V3): enforces allow-listed domain names, blocks DNS rebinding to
/// loopback/metadata/RFC-1918, and refuses malformed or non-CONNECT request lines.
struct ConnectProxyAuthorizerTests {
    @Test
    func allowsAllowListedDomainAndReturnsPinnedResolvedAddresses() async throws {
        var policy = NetworkPolicy()
        policy.mode = .allowListed
        policy.blockPrivateRanges = true
        try policy.add("api.github.com", to: .allowedDomains)
        try policy.add("443", to: .allowedPorts)

        let publicIP = try #require(IPAddress(strictLiteral: "140.82.121.6"))
        let authorizer = ConnectProxyAuthorizer(policy: policy) { host in
            host == "api.github.com" ? [publicIP] : []
        }

        let outcome = await authorizer.authorize("CONNECT api.github.com:443 HTTP/1.1\r\nHost: api.github.com:443\r\n\r\n")
        #expect(outcome == .allow(target: .init(host: "api.github.com", port: 443), pinnedAddresses: [publicIP]))
        #expect(ConnectProxyAuthorizer.httpResponse(for: outcome).hasPrefix("HTTP/1.1 200 Connection Established"))
    }

    @Test
    func refusesDNSRebindingToMetadataOrPrivateRangesAndRawIPBypass() async throws {
        var policy = NetworkPolicy()
        policy.mode = .allowListed
        policy.blockPrivateRanges = true
        try policy.add("api.github.com", to: .allowedDomains)

        let metadata = try #require(IPAddress(strictLiteral: "169.254.169.254"))
        let rfc1918 = try #require(IPAddress(strictLiteral: "10.0.0.5"))
        let publicIP = try #require(IPAddress(strictLiteral: "140.82.121.6"))

        let rebinding = ConnectProxyAuthorizer(policy: policy) { _ in [publicIP, metadata] }
        let metaOutcome = await rebinding.authorize("CONNECT api.github.com:443 HTTP/1.1\r\n\r\n")
        if case .deny(let code, _) = metaOutcome { #expect(code == 403) } else { Issue.record("metadata IP must be denied") }

        let privateRebind = ConnectProxyAuthorizer(policy: policy) { _ in [rfc1918] }
        let privOutcome = await privateRebind.authorize("CONNECT api.github.com:443 HTTP/1.1\r\n\r\n")
        if case .deny(let code, _) = privOutcome { #expect(code == 403) } else { Issue.record("RFC 1918 IP must be denied") }

        // Raw IP literal to an unlisted IP or disallowed port must be refused.
        let normal = ConnectProxyAuthorizer(policy: policy) { _ in [publicIP] }
        let rawIP = await normal.authorize("CONNECT 140.82.121.6:443 HTTP/1.1\r\n\r\n")
        if case .deny(let code, _) = rawIP { #expect(code == 403) } else { Issue.record("unlisted raw IP must be denied") }

        let badMethod = await normal.authorize("GET http://api.github.com/ HTTP/1.1\r\n\r\n")
        if case .deny(let code, _) = badMethod { #expect(code == 400) } else { Issue.record("non-CONNECT must return 400") }

        let userInfo = await normal.authorize("CONNECT api.github.com@evil.example:443 HTTP/1.1\r\n\r\n")
        if case .deny(let code, _) = userInfo { #expect(code == 400) } else { Issue.record("userinfo in authority must return 400") }
    }
}
