import Foundation
import Testing

@testable import VMRunner

struct PortRuleTests {
    @Test(arguments: [("22", 22...22), ("8000-8100", 8000...8100), (" 443 ", 443...443), ("1-65535", 1...65535)])
    func parsesSinglePortsAndRanges(text: String, expected: ClosedRange<UInt16>) throws {
        #expect(try PortRule(text).range == expected)
    }

    @Test(arguments: ["", "0", "65536", "-1", "80-", "-80", "90-80", "8000-8100-8200", "http", "80 81", "٨٠", "８０", "1e3", "+80"])
    func rejectsAnythingThatIsNotAPortOrOrderedRange(text: String) {
        #expect(throws: NetworkPolicyError.self) { try PortRule(text) }
    }

    @Test func descriptionIsCanonicalAndRoundTrips() throws {
        #expect(try PortRule("0080").description == "80")
        #expect(try PortRule("8000-8100").description == "8000-8100")
        #expect(try PortRule("5-5").description == "5")
        let encoded = try JSONEncoder().encode([try PortRule("22"), try PortRule("8000-8100")])
        #expect(try JSONDecoder().decode([PortRule].self, from: encoded) == [22, try PortRule("8000-8100")])
    }

    @Test func aBareJSONNumberStillDecodesAsOneLegacyPort() throws {
        let rules = try JSONDecoder().decode([PortRule].self, from: Data("[22, \"8000-8100\"]".utf8))
        #expect(rules == [22, try PortRule("8000-8100")])
    }

    @Test func containsIncludesBothEnds() throws {
        let rule = try PortRule("8000-8100")
        #expect(rule.contains(8000) && rule.contains(8100) && rule.contains(8050))
        #expect(!rule.contains(7999) && !rule.contains(8101))
    }
}

struct ConnectionRuleParsingTests {
    @Test(arguments: [
        ("example.com:443", "example.com:443"),
        ("*.example.com:80,8000-8100", "*.example.com:80,8000-8100"),
        ("example.com", "example.com"),
        ("10.0.0.0/8:22", "10.0.0.0/8:22"),
        ("10.1.2.3/8:22", "10.0.0.0/8:22"),
        ("[2001:db8::/32]:443", "[2001:db8::/32]:443"),
        ("[2001:db8::1]", "[2001:db8::1]"),
        ("2001:db8::1", "[2001:db8::1]"),
        ("  EXAMPLE.com.:443 ", "example.com:443"),
    ])
    func parsesAndCanonicalizes(text: String, canonical: String) throws {
        #expect(try ConnectionRule(text).description == canonical)
    }

    @Test(arguments: [
        "", ":443", "example.com:", "example.com:0", "example.com:99999", "example.com:80,", "example.com:,80", "[2001:db8::", "[::1]443",
        "[::1]:", "127.1:80", "2130706433:80", "999.1.1.1:80", "evil..com:80", "a b.com:80", "example.com:80:81",
    ])
    func rejectsMalformedRules(text: String) {
        #expect(throws: NetworkPolicyError.self) { try ConnectionRule(text) }
    }

    @Test func noPortsMeansEveryPort() throws {
        let rule = try ConnectionRule("example.com")
        #expect(rule.ports.isEmpty)
        #expect(rule.appliesToPort(1) && rule.appliesToPort(65535))
    }

    @Test func roundTripsThroughJSON() throws {
        let rules = [try ConnectionRule("*.github.com:443"), try ConnectionRule("[fd00::/8]:22,80")]
        let decoded = try JSONDecoder().decode([ConnectionRule].self, from: JSONEncoder().encode(rules))
        #expect(decoded == rules)
    }

    @Test func aBadPersistedRuleFailsToLoadInsteadOfBeingDropped() {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([ConnectionRule].self, from: Data("[\"example.com:0\"]".utf8)) }
    }
}

struct PortListPolicyTests {
    private let publicAddress = "93.184.216.34"

    private func policy(blockedPorts: [String] = [], allowedPorts: [String] = []) throws -> NetworkPolicy {
        var policy = NetworkPolicy()
        policy.blockedPorts = try blockedPorts.map(PortRule.init)
        policy.allowedPorts = try allowedPorts.map(PortRule.init)
        return policy
    }

    @Test func aDenyListBlocksSinglePortsAndRanges() throws {
        let policy = try policy(blockedPorts: ["22", "8000-8100"])
        let resolved = try addresses(publicAddress)
        #expect(policy.evaluate(host: "example.com", port: 22, resolvedAddresses: resolved) == .deny(.blockedPort(22)))
        #expect(policy.evaluate(host: "example.com", port: 8080, resolvedAddresses: resolved) == .deny(.blockedPort(8080)))
        #expect(policy.evaluate(host: "example.com", port: 443, resolvedAddresses: resolved) == .allow)
        #expect(policy.evaluate(host: "example.com", port: 8101, resolvedAddresses: resolved) == .allow)
    }

    @Test func anAllowListOfPortsOnlyAppliesInAllowListMode() throws {
        var policy = try policy(allowedPorts: ["443"])
        let resolved = try addresses(publicAddress)
        #expect(policy.evaluate(host: "example.com", port: 25, resolvedAddresses: resolved) == .allow, "deny-list mode ignores allow lists")

        policy.mode = .allowListed
        policy.allowedDomains = [try DomainRule("example.com")]
        #expect(policy.evaluate(host: "example.com", port: 443, resolvedAddresses: resolved) == .allow)
        #expect(policy.evaluate(host: "example.com", port: 25, resolvedAddresses: resolved) == .deny(.portNotAllowListed(25)))
    }

    @Test func noAllowedPortsMeansAnyPortOnAnAllowedDestination() throws {
        var policy = try policy()
        policy.mode = .allowListed
        policy.allowedDomains = [try DomainRule("example.com")]
        #expect(policy.evaluate(host: "example.com", port: 6379, resolvedAddresses: try addresses(publicAddress)) == .allow)
    }

    @Test func aBlockedPortBeatsAnAllowedPort() throws {
        var policy = try policy(blockedPorts: ["443"], allowedPorts: ["443"])
        policy.mode = .allowListed
        policy.allowedDomains = [try DomainRule("example.com")]
        #expect(
            policy.evaluate(host: "example.com", port: 443, resolvedAddresses: try addresses(publicAddress)) == .deny(.blockedPort(443)))
    }

    @Test func aDestinationThatIsNotAllowedFailsBeforeThePortIsConsidered() throws {
        var policy = try policy(allowedPorts: ["443"])
        policy.mode = .allowListed
        #expect(
            policy.evaluate(host: "other.example", port: 443, resolvedAddresses: try addresses(publicAddress)) == .deny(.notAllowListed))
    }
}

struct ConnectionPolicyTests {
    private let publicAddress = "93.184.216.34"

    private func policy(
        mode: NetworkPolicy.Mode = .denyListed, blocked: [String] = [], allowed: [String] = []
    ) throws -> NetworkPolicy {
        var policy = NetworkPolicy()
        policy.mode = mode
        policy.blockedConnections = try blocked.map(ConnectionRule.init)
        policy.allowedConnections = try allowed.map(ConnectionRule.init)
        return policy
    }

    @Test func aBlockedConnectionBlocksOnlyThatHostOnThosePorts() throws {
        let policy = try policy(blocked: ["example.com:22"])
        let resolved = try addresses(publicAddress)
        guard case .deny(.blockedConnection(let rule)) = policy.evaluate(host: "example.com", port: 22, resolvedAddresses: resolved) else {
            Issue.record("ssh to the blocked host was allowed")
            return
        }
        #expect(rule.description == "example.com:22")
        #expect(policy.evaluate(host: "example.com", port: 443, resolvedAddresses: resolved) == .allow)
        #expect(policy.evaluate(host: "other.example", port: 22, resolvedAddresses: resolved) == .allow)
        #expect(
            policy.evaluate(host: "www.example.com", port: 22, resolvedAddresses: resolved) == .allow, "an exact rule has no subdomains")
    }

    @Test func aBlockedAddressConnectionMatchesAnyResolvedAddressInTheBlock() throws {
        let policy = try policy(blocked: ["93.184.216.0/24:25"])
        let mixed = try addresses("203.0.113.9", publicAddress)
        #expect(policy.evaluate(host: "mail.example", port: 25, resolvedAddresses: mixed) != .allow)
        #expect(policy.evaluate(host: "mail.example", port: 587, resolvedAddresses: mixed) == .allow)
        #expect(policy.evaluate(host: publicAddress, port: 25, resolvedAddresses: []) != .allow, "a literal IP is judged by itself")
    }

    @Test func mappedIPv6FormsAreCaughtByAnAddressConnectionRule() throws {
        let policy = try policy(blocked: ["93.184.216.34:443"])
        #expect(policy.evaluate(host: "x.example", port: 443, resolvedAddresses: try addresses("::ffff:93.184.216.34")) != .allow)
    }

    @Test func anAllowedConnectionAllowsExactlyThatHostAndPort() throws {
        let policy = try policy(mode: .allowListed, allowed: ["*.github.com:443"])
        let resolved = try addresses(publicAddress)
        #expect(policy.evaluate(host: "api.github.com", port: 443, resolvedAddresses: resolved) == .allow)
        #expect(policy.evaluate(host: "api.github.com", port: 80, resolvedAddresses: resolved) == .deny(.notAllowListed))
        #expect(
            policy.evaluate(host: "github.com", port: 443, resolvedAddresses: resolved) == .deny(.notAllowListed),
            "suffix rules exclude the apex")
        #expect(policy.evaluate(host: "evilgithub.com", port: 443, resolvedAddresses: resolved) == .deny(.notAllowListed))
        #expect(policy.evaluate(host: "github.com.evil.com", port: 443, resolvedAddresses: resolved) == .deny(.notAllowListed))
    }

    @Test func anAllowedAddressConnectionNeedsEveryResolvedAddressInside() throws {
        let policy = try policy(mode: .allowListed, allowed: ["93.184.216.0/24:443"])
        #expect(policy.evaluate(host: "x.example", port: 443, resolvedAddresses: try addresses(publicAddress)) == .allow)
        #expect(policy.evaluate(host: "x.example", port: 443, resolvedAddresses: try addresses(publicAddress, "203.0.113.9")) != .allow)
        #expect(policy.evaluate(host: "x.example", port: 80, resolvedAddresses: try addresses(publicAddress)) != .allow)
    }

    @Test func aBlockBeatsAnAllowedConnection() throws {
        let policy = try policy(mode: .allowListed, blocked: ["api.github.com:443"], allowed: ["*.github.com:443"])
        let resolved = try addresses(publicAddress)
        #expect(policy.evaluate(host: "api.github.com", port: 443, resolvedAddresses: resolved) != .allow)
        #expect(policy.evaluate(host: "uploads.github.com", port: 443, resolvedAddresses: resolved) == .allow)
    }

    @Test func anAllowedConnectionNeverOverridesPrivateRanges() throws {
        let policy = try policy(mode: .allowListed, allowed: ["192.168.64.1:443", "internal.example:443"])
        #expect(policy.evaluate(host: "192.168.64.1", port: 443, resolvedAddresses: []) != .allow, "the NAT gateway stays blocked")
        #expect(policy.evaluate(host: "internal.example", port: 443, resolvedAddresses: try addresses("10.1.2.3")) != .allow)
    }

    @Test func connectionRulesDoNotMakeAnAllowListOutOfADenyListPolicy() throws {
        let policy = try policy(mode: .denyListed, allowed: ["good.example:443"])
        #expect(policy.evaluate(host: "other.example", port: 80, resolvedAddresses: try addresses(publicAddress)) == .allow)
    }

    @Test func allowedConnectionsCombineWithAllowedDomainsAndPorts() throws {
        var policy = try policy(mode: .allowListed, allowed: ["api.example:8443"])
        policy.allowedDomains = [try DomainRule("docs.example")]
        policy.allowedPorts = [443]
        let resolved = try addresses(publicAddress)
        #expect(policy.evaluate(host: "docs.example", port: 443, resolvedAddresses: resolved) == .allow)
        #expect(policy.evaluate(host: "docs.example", port: 8443, resolvedAddresses: resolved) == .deny(.portNotAllowListed(8443)))
        #expect(policy.evaluate(host: "api.example", port: 8443, resolvedAddresses: resolved) == .allow, "the connection rule stands alone")
        #expect(policy.evaluate(host: "api.example", port: 443, resolvedAddresses: resolved) == .deny(.notAllowListed))
    }
}

struct URLAllowListTests {
    private func policy(allowedPrefixes: [String], blockedPrefixes: [String] = []) throws -> NetworkPolicy {
        var policy = NetworkPolicy()
        policy.mode = .allowListed
        policy.allowedDomains = [try DomainRule("example.com")]
        policy.allowedURLPrefixes = try allowedPrefixes.map(URLRule.init)
        policy.blockedURLPrefixes = try blockedPrefixes.map(URLRule.init)
        return policy
    }

    private func decision(_ policy: NetworkPolicy, _ url: String) throws -> NetworkPolicy.URLEvaluation {
        let parsed = try #require(URL(string: url))
        return policy.evaluate(url: parsed, resolvedAddresses: try addresses("93.184.216.34"))
    }

    @Test func httpUrlsMustMatchAnAllowedPrefix() throws {
        let policy = try policy(allowedPrefixes: ["http://example.com/api"])
        #expect(try decision(policy, "http://example.com/api/v1/users").decision == .allow)
        #expect(try decision(policy, "http://example.com/admin").decision == .deny(.urlNotAllowListed))
        #expect(
            try decision(policy, "http://example.com/apis").decision == .deny(.urlNotAllowListed), "segment boundaries, not string prefixes"
        )
        #expect(
            try decision(policy, "http://example.com/api/../admin").decision == .deny(.urlNotAllowListed), "dot segments are resolved first"
        )
        #expect(try decision(policy, "http://example.com/%61pi/x").decision == .allow, "escapes are decoded before matching")
    }

    @Test func httpsIsJudgedOnHostAndPortOnlyBecauseThePathIsInvisible() throws {
        let policy = try policy(allowedPrefixes: ["http://example.com/api"])
        let result = try decision(policy, "https://example.com/admin")
        #expect(result.decision == .allow)
        #expect(!result.pathRulesApplied)
    }

    @Test func aBlockedPrefixBeatsAnAllowedPrefix() throws {
        let policy = try policy(allowedPrefixes: ["http://example.com/api"], blockedPrefixes: ["http://example.com/api/internal"])
        #expect(try decision(policy, "http://example.com/api/public").decision == .allow)
        guard case .deny(.blockedURL) = try decision(policy, "http://example.com/api/internal/keys").decision else {
            Issue.record("a blocked prefix inside an allowed one was allowed")
            return
        }
    }

    @Test func noAllowedPrefixesMeansAnyPathOnAnAllowedHost() throws {
        let policy = try policy(allowedPrefixes: [])
        #expect(try decision(policy, "http://example.com/anything").decision == .allow)
    }

    @Test func allowedPrefixesDoNotAffectDenyListMode() throws {
        var policy = try policy(allowedPrefixes: ["http://example.com/api"])
        policy.mode = .denyListed
        #expect(try decision(policy, "http://example.com/admin").decision == .allow)
    }
}

struct NetworkListCodableTests {
    @Test func theNewListsRoundTripAndOlderPoliciesStillDecode() throws {
        var policy = NetworkPolicy()
        policy.mode = .allowListed
        policy.allowedPorts = [443, try PortRule("8000-8100")]
        policy.blockedPorts = [22]
        policy.allowedConnections = [try ConnectionRule("*.github.com:443")]
        policy.blockedConnections = [try ConnectionRule("10.0.0.0/8:22")]
        policy.allowedURLPrefixes = [try URLRule("http://example.com/api")]

        #expect(try JSONDecoder().decode(NetworkPolicy.self, from: JSONEncoder().encode(policy)) == policy)

        let legacy = try JSONDecoder().decode(NetworkPolicy.self, from: Data(#"{"mode":"allowListed","blockedPorts":[22,23]}"#.utf8))
        #expect(legacy.blockedPorts == [22, 23])
        #expect(legacy.allowedPorts.isEmpty && legacy.allowedConnections.isEmpty && legacy.allowedURLPrefixes.isEmpty)
    }
}
