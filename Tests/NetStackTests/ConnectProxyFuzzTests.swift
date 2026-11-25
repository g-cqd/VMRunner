import Foundation
import NetPolicy
import Testing

@testable import NetStack

/// Seeded adversarial fuzzing of `ConnectProxyAuthorizer` (V2 / N-V2): random, truncated, oversized, and mutated
/// HTTP `CONNECT` frames must never trap, never allow unlisted hosts, and never allow reserved/metadata/private IPs.
struct ConnectProxyFuzzTests {
    @Test
    func mutatedConnectRequestsNeverCrashAndNeverBypassAllowList() async throws {
        var policy = NetworkPolicy()
        policy.mode = .allowListed
        policy.blockPrivateRanges = true
        try policy.add("api.github.com", to: .allowedDomains)
        try policy.add("443", to: .allowedPorts)

        let metadata = try #require(IPAddress(strictLiteral: "169.254.169.254"))
        let authorizer = ConnectProxyAuthorizer(policy: policy) { host in
            host == "api.github.com" ? [metadata] : []
        }

        var random = XorShift(state: 0xC0DE_2026_1125)
        let seeds = [
            "CONNECT api.github.com:443 HTTP/1.1\r\nHost: api.github.com:443\r\n\r\n",
            "CONNECT 169.254.169.254:80 HTTP/1.1\r\n\r\n",
            "CONNECT [::ffff:127.0.0.1]:443 HTTP/1.1\r\n\r\n",
            "CONNECT api.github.com@evil.example:443 HTTP/1.1\r\n\r\n",
            "GET http://api.github.com/ HTTP/1.1\r\n\r\n",
        ]

        for _ in 0..<2_000 {
            var bytes = Array(seeds[random.below(seeds.count)].utf8)
            if !bytes.isEmpty {
                let pos = random.below(bytes.count)
                bytes[pos] ^= UInt8(1 + random.below(254))
            }
            let raw = String(bytes: bytes, encoding: .utf8) ?? ""
            let outcome = await authorizer.authorize(raw)
            if case .allow = outcome {
                Issue.record("No mutated or metadata-resolving request may be allowed: \(raw)")
            }
        }
    }
}
