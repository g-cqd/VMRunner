import Foundation
import Testing

@testable import VMRunner

struct NetworkURLTests {
    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text), "test URL \(text) must parse")
    }

    private func policy(blockingDomains domains: [String] = [], urls: [String] = []) throws -> NetworkPolicy {
        var policy = NetworkPolicy()
        policy.blockedDomains = try domains.map(DomainRule.init)
        policy.blockedURLPrefixes = try urls.map(URLRule.init)
        return policy
    }

    private func evaluate(_ policy: NetworkPolicy, _ text: String, resolved: String = "93.184.216.34") throws -> NetworkPolicy.URLEvaluation
    {
        policy.evaluate(url: try url(text), resolvedAddresses: try addresses(resolved))
    }

    // MARK: Authority tricks

    @Test func credentialsCannotHideTheRealHost() throws {
        let blockEvil = try policy(blockingDomains: ["evil.com"])
        #expect(try evaluate(blockEvil, "http://good.com@evil.com/").decision == .deny(.blockedDomain(DomainRule("evil.com"))))
        #expect(try evaluate(blockEvil, "http://good.com:pw@EVIL.com:80/x").decision == .deny(.blockedDomain(DomainRule("evil.com"))))
        #expect(try evaluate(blockEvil, "http://a@b@evil.com/").decision == .deny(.blockedDomain(DomainRule("evil.com"))))
        // The host is what is connected to, not the decoy before the @.
        let blockGood = try policy(blockingDomains: ["good.com"])
        #expect(try evaluate(blockGood, "http://good.com@evil.com/").decision == .allow)
        // Fragment and query cannot move the host either.
        #expect(try !evaluate(blockEvil, "http://evil.com#@good.com/").decision.isAllowed)
        #expect(try !evaluate(blockEvil, "http://evil.com?@good.com/").decision.isAllowed)
    }

    @Test(arguments: ["http://evil.com\\@good.com/", "http://good.com%5C@evil.com/", "http://a\\b@evil.com/"])
    func backslashInCredentialsIsDeniedAsParserConfusion(text: String) throws {
        let verdict = try evaluate(NetworkPolicy(), text)
        #expect(verdict.decision == .deny(.malformedURL))
    }

    @Test(arguments: ["HTTP://EVIL.COM:80/", "http://Evil.Com./", "HtTp://evil.com:0080/"])
    func schemeHostAndPortAreCaseAndFormInsensitive(text: String) throws {
        let verdict = try evaluate(try policy(blockingDomains: ["evil.com"]), text)
        #expect(verdict.decision == .deny(.blockedDomain(try DomainRule("evil.com"))))
    }

    @Test(arguments: [
        "http://127.1/", "http://2130706433/", "http://0x7f.0.0.1/", "http://0177.0.0.1/", "http://017700000001:8080/x",
    ])
    func numericHostSpellingsInURLsAreDenied(text: String) throws {
        #expect(try evaluate(NetworkPolicy(), text).decision == .deny(.nonCanonicalAddress))
    }

    @Test(arguments: ["http://%31%32%37.0.0.1/", "http://127.0.0.%31/", "http://ev%69l.com/"])
    func percentEncodedHostsAreDenied(text: String) throws {
        let decision = try evaluate(NetworkPolicy(), text).decision
        #expect(!decision.isAllowed)
    }

    @Test(arguments: [
        ("http://[::1]/", ReservedRangeKind.loopback), ("http://[::ffff:127.0.0.1]:8080/", .loopback),
        ("http://[::ffff:7f00:1]/", .loopback), ("http://[fe80::1%25en0]/", .linkLocal), ("https://[fd00::1]/", .uniqueLocal),
        ("http://10.1.2.3/", .privateNetwork), ("https://169.254.169.254/latest/meta-data", .cloudMetadata),
        ("http://192.168.64.1:9000/", .hostGateway), ("http://[::ffff:a00:1]/", .privateNetwork),
    ])
    func literalHostsAreJudgedByAddress(text: String, kind: ReservedRangeKind) throws {
        guard case .deny(.reservedRange(let found, _)) = try evaluate(NetworkPolicy(), text, resolved: publicAddress).decision else {
            Issue.record("\(text) was not denied as reserved")
            return
        }
        #expect(found == kind)
    }

    private var publicAddress: String { "93.184.216.34" }

    @Test(arguments: ["http:evil.com", "http:///x", "http://:80/", "mailto:a@b.example"])
    func urlsWithoutAnAuthorityAreDenied(text: String) throws {
        #expect(!(try evaluate(NetworkPolicy(), text).decision.isAllowed))
    }

    @Test(arguments: [
        ("ftp://x.example/", "ftp"), ("file:///etc/passwd", "file"), ("javascript:alert(1)", "javascript"), ("ws://x.example/", "ws"),
    ])
    func onlyHTTPAndHTTPSAreEvaluated(text: String, scheme: String) throws {
        let verdict = try evaluate(NetworkPolicy(), text)
        #expect(verdict.decision == .deny(.unsupportedScheme(scheme)))
        #expect(!verdict.pathRulesApplied)
    }

    @Test(arguments: ["http://x.example:0/", "http://x.example:65536/", "http://x.example:99999/", "https://x.example:70000/"])
    func invalidPortsAreDenied(text: String) throws {
        #expect(try evaluate(NetworkPolicy(), text).decision == .deny(.malformedURL))
    }

    @Test func defaultPortsFeedPortRules() throws {
        var blocking = NetworkPolicy()
        blocking.blockedPorts = [80, 443]
        #expect(try evaluate(blocking, "http://x.example/").decision == .deny(.blockedPort(80)))
        #expect(try evaluate(blocking, "https://x.example/").decision == .deny(.blockedPort(443)))
        #expect(try evaluate(blocking, "http://x.example:8080/").decision == .allow)
    }

    @Test func resolvedAddressesAreCheckedForURLs() throws {
        let verdict = try evaluate(NetworkPolicy(), "https://good.example/", resolved: "93.184.216.34")
        #expect(verdict.decision == .allow)
        let rebound = NetworkPolicy().evaluate(
            url: try url("https://good.example/"), resolvedAddresses: try addresses("93.184.216.34", "10.0.0.9"))
        guard case .deny(.reservedRange(.privateNetwork, _)) = rebound.decision else {
            Issue.record("rebinding via URL was allowed")
            return
        }
    }

    // MARK: Path normalization

    /// Every one of these reaches `/admin` on the server and must hit the `/admin` rule.
    @Test(arguments: [
        "http://x.example/admin", "http://x.example/ADMIN", "http://x.example/Admin/", "http://x.example/admin/users",
        "http://x.example//admin",
        "http://x.example/./admin", "http://x.example/ad%6Din", "http://x.example/ad%6din", "http://x.example/%61%64%6D%69%6E",
        "http://x.example/%2561dmin", "http://x.example/%252561dmin", "http://x.example/x/../admin", "http://x.example/x/%2e%2e/admin",
        "http://x.example/x/%2E%2e/admin", "http://x.example/x/.%2e/admin", "http://x.example/../../admin",
        "http://x.example/a/b/../../admin",
        "http://x.example/x%2F..%2Fadmin", "http://x.example/x%5C..%5Cadmin", "http://x.example/x\\..\\admin",
        "http://x.example/public/..%2f..%2fadmin",
        "http://x.example/admin;jsessionid=1", "http://x.example/admin;/users", "http://x.example/admin.", "http://x.example/admin%20",
        "http://x.example/admin?x=1", "http://x.example/admin#frag", "http://x.example/ADMIN/../Admin/", "http://x.example:80/admin",
        "HTTP://X.EXAMPLE/admin", "http://x.example./admin", "http://user@x.example/admin",
    ])
    func pathSpellingsOfAdminAreBlocked(text: String) throws {
        let rule = try URLRule("http://x.example/admin")
        let verdict = try evaluate(try policy(urls: ["http://x.example/admin"]), text)
        #expect(verdict.decision == .deny(.blockedURL(rule)), "\(text)")
        #expect(verdict.pathRulesApplied)
    }

    @Test(arguments: [
        "http://x.example/", "http://x.example/administrator", "http://x.example/admin.php", "http://x.example/x/admin2",
        "http://x.example/public/admin/../other", "http://x.example/a%2Fadmin", "http://y.example/admin", "http://sub.x.example/admin",
        "http://x.example.evil.com/admin", "http://x.example:8080/admin/../ok",
    ])
    func otherPathsAreNotBlocked(text: String) throws {
        let verdict = try evaluate(try policy(urls: ["http://x.example/admin"]), text)
        // The last case only differs by port from the rule, which pins no port: the path resolves to /ok, so it is allowed.
        #expect(verdict.decision == .allow, "\(text)")
    }

    @Test(arguments: ["http://x.example/admin%00", "http://x.example/admin%00.png", "http://x.example/a%0Ab", "http://x.example/a%7Fb"])
    func controlCharactersInThePathAreDenied(text: String) throws {
        #expect(try evaluate(try policy(urls: ["http://x.example/admin"]), text).decision == .deny(.malformedURL))
    }

    @Test func neverStabilizingEncodingIsDenied() throws {
        // Nine layers of encoding never reach a fixed point within the decoding budget.
        let deeplyEncoded = "http://x.example/%" + String(repeating: "25", count: 9) + "41"
        #expect(try evaluate(NetworkPolicy(), deeplyEncoded).decision == .deny(.malformedURL))
    }

    @Test func portedRulesOnlyMatchThatPort() throws {
        let blocking = try policy(urls: ["http://x.example:8080/admin", "http://y.example:80/"])
        #expect(try !evaluate(blocking, "http://x.example:8080/admin").decision.isAllowed)
        #expect(try evaluate(blocking, "http://x.example/admin").decision == .allow)
        #expect(try evaluate(blocking, "http://x.example:9090/admin").decision == .allow)
        #expect(try !evaluate(blocking, "http://y.example/anything").decision.isAllowed)
        #expect(try evaluate(blocking, "http://y.example:81/anything").decision == .allow)
    }

    @Test func wildcardAndAddressURLRules() throws {
        let blocking = try policy(urls: ["http://*.cdn.example/private", "http://[::1]/", "http://93.184.216.34/secret"])
        #expect(try !evaluate(blocking, "http://a.cdn.example/PRIVATE/x").decision.isAllowed)
        #expect(try evaluate(blocking, "http://cdn.example/private").decision == .allow)
        #expect(
            try evaluate(blocking, "http://93.184.216.34/secret/x").decision
                == .deny(.blockedURL(try URLRule("http://93.184.216.34/secret"))))
        #expect(try evaluate(blocking, "http://93.184.216.34/public").decision == .allow)
        #expect(
            try evaluate(blocking, "http://[::ffff:93.184.216.34]/secret").decision
                == .deny(.blockedURL(try URLRule("http://93.184.216.34/secret"))))
    }

    // MARK: HTTPS

    @Test func httpsIsJudgedOnHostPortAndAddressesOnly() throws {
        let blocking = try policy(blockingDomains: ["evil.com"], urls: ["http://x.example/admin"])
        let secretPath = try evaluate(blocking, "https://x.example/admin")
        #expect(secretPath.decision == .allow)
        #expect(!secretPath.pathRulesApplied, "path rules cannot be enforced through a CONNECT tunnel and the verdict says so")
        let blockedHost = try evaluate(blocking, "https://evil.com/anything")
        #expect(blockedHost.decision == .deny(.blockedDomain(try DomainRule("evil.com"))))
        #expect(!blockedHost.pathRulesApplied)
        let http = try evaluate(blocking, "http://x.example/ok")
        #expect(http.decision == .allow)
        #expect(http.pathRulesApplied)
    }
}
