import Foundation
import Testing

@testable import VMRunner

struct NetworkAllowListTests {
    private func allowListed(domains: [String] = [], addresses: [String] = []) throws -> NetworkPolicy {
        var policy = NetworkPolicy()
        policy.mode = .allowListed
        policy.allowedDomains = try domains.map(DomainRule.init)
        policy.allowedAddresses = try addresses.map(AddressRule.init)
        return policy
    }

    @Test func anEmptyAllowListAllowsNothing() throws {
        let policy = try allowListed()
        #expect(
            policy.evaluate(host: "good.example", port: 443, resolvedAddresses: try addresses("93.184.216.34")) == .deny(.notAllowListed))
        #expect(policy.evaluate(host: "93.184.216.34", port: 443, resolvedAddresses: []) == .deny(.notAllowListed))
    }

    @Test func allowedDomainsPassWhenEveryAddressIsPublic() throws {
        let policy = try allowListed(domains: ["good.example", "*.cdn.example"])
        let resolved = try addresses("93.184.216.34", "2606:4700:4700::1111")
        #expect(policy.evaluate(host: "GOOD.example.", port: 443, resolvedAddresses: resolved) == .allow)
        #expect(policy.evaluate(host: "a.b.cdn.example", port: 443, resolvedAddresses: resolved) == .allow)
        #expect(policy.evaluate(host: "www.good.example", port: 443, resolvedAddresses: resolved) == .deny(.notAllowListed))
        #expect(policy.evaluate(host: "cdn.example", port: 443, resolvedAddresses: resolved) == .deny(.notAllowListed))
        #expect(policy.evaluate(host: "notcdn.example", port: 443, resolvedAddresses: resolved) == .deny(.notAllowListed))
        #expect(policy.evaluate(host: "good.example.evil.com", port: 443, resolvedAddresses: resolved) == .deny(.notAllowListed))
    }

    @Test func anAllowedNameIsStillDeniedWhenAnyResolvedAddressIsPrivate() throws {
        let policy = try allowListed(domains: ["good.example"])
        let rebound = try addresses("93.184.216.34", "10.0.0.5")
        guard case .deny(.reservedRange(.privateNetwork, _)) = policy.evaluate(host: "good.example", port: 443, resolvedAddresses: rebound)
        else {
            Issue.record("allow-listed name with a private address was allowed")
            return
        }
    }

    @Test func allowedAddressesAdmitLiteralsAndNamesThatResolveInsideThem() throws {
        let policy = try allowListed(addresses: ["93.184.216.0/24", "2606:4700::/32"])
        #expect(policy.evaluate(host: "93.184.216.34", port: 80, resolvedAddresses: []) == .allow)
        #expect(policy.evaluate(host: "svc.example", port: 80, resolvedAddresses: try addresses("93.184.216.7", "2606:4700::1")) == .allow)
        #expect(
            policy.evaluate(host: "svc.example", port: 80, resolvedAddresses: try addresses("93.184.216.7", "1.1.1.1"))
                == .deny(.notAllowListed))
        #expect(policy.evaluate(host: "[::ffff:93.184.216.34]", port: 80, resolvedAddresses: []) == .allow)
    }

    @Test func blocksAlwaysBeatAllows() throws {
        var policy = try allowListed(domains: ["good.example", "*.good.example"], addresses: ["192.168.64.1", "93.184.216.0/24"])
        policy.blockedDomains = [try DomainRule("bad.good.example")]
        policy.blockedPorts = [25]
        policy.blockedAddresses = [try AddressRule("93.184.216.99")]
        let resolved = try addresses("93.184.216.34")
        #expect(!policy.evaluate(host: "bad.good.example", port: 443, resolvedAddresses: resolved).isAllowed)
        #expect(!policy.evaluate(host: "good.example", port: 25, resolvedAddresses: resolved).isAllowed)
        #expect(!policy.evaluate(host: "good.example", port: 443, resolvedAddresses: try addresses("93.184.216.99")).isAllowed)
        // The NAT gateway is on the allow-list, but the private-range block wins until it is turned off deliberately.
        #expect(!policy.evaluate(host: "192.168.64.1", port: 80, resolvedAddresses: []).isAllowed)
        policy.blockPrivateRanges = false
        #expect(policy.evaluate(host: "192.168.64.1", port: 80, resolvedAddresses: []) == .allow)
    }

    @Test func denyListModeIgnoresAllowLists() throws {
        var policy = NetworkPolicy()
        policy.allowedDomains = [try DomainRule("only.example")]
        #expect(policy.evaluate(host: "other.example", port: 443, resolvedAddresses: try addresses("93.184.216.34")) == .allow)
    }

    @Test func blockedDomainRulesFollowTheDocumentedApexAndLabelRules() throws {
        var policy = NetworkPolicy()
        policy.blockedDomains = [try DomainRule("evil.com"), try DomainRule("*.tracker.net")]
        let resolved = try addresses("93.184.216.34")
        let blocked = ["evil.com", "EVIL.COM.", "a.tracker.net", "a.b.c.tracker.net", "A.Tracker.NET."]
        let allowed = ["www.evil.com", "notevil.com", "evil.com.au", "tracker.net", "xtracker.net", "tracker.net.example"]
        for host in blocked {
            #expect(!policy.evaluate(host: host, port: 443, resolvedAddresses: resolved).isAllowed, "\(host) should be blocked")
        }
        for host in allowed {
            #expect(policy.evaluate(host: host, port: 443, resolvedAddresses: resolved).isAllowed, "\(host) should be allowed")
        }
    }
}

struct NetworkPolicyCodableTests {
    @Test func defaultsAreSafe() {
        let policy = NetworkPolicy()
        #expect(policy.blockPrivateRanges)
        #expect(policy.mode == .denyListed)
        #expect(policy.vpn == .ignore)
        #expect(policy.blockedAddresses.isEmpty && policy.blockedDomains.isEmpty && policy.blockedURLPrefixes.isEmpty)
    }

    @Test func roundTripsEveryField() throws {
        var policy = NetworkPolicy()
        policy.blockPrivateRanges = false
        policy.blockedAddresses = try ["10.0.0.0/8", "fd00::/8", "1.2.3.4", "::ffff:5.6.7.0/120"].map(AddressRule.init)
        policy.blockedDomains = try ["evil.com", "*.tracker.net"].map(DomainRule.init)
        policy.blockedURLPrefixes = try ["http://x.example/admin", "http://[::1]:8080/a%20b", "http://*.y.example:81/"].map(URLRule.init)
        policy.blockedPorts = [25, 445]
        policy.mode = .allowListed
        policy.allowedDomains = [try DomainRule("good.example")]
        policy.allowedAddresses = [try AddressRule("93.184.216.0/24")]
        policy.vpn = .required
        let data = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(NetworkPolicy.self, from: data) == policy)
    }

    @Test func rulesEncodeAsReadableStrings() throws {
        var policy = NetworkPolicy()
        policy.blockedAddresses = [try AddressRule("10.1.2.3/8")]
        policy.blockedDomains = [try DomainRule("*.Evil.com.")]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let json = try #require(String(data: try encoder.encode(policy), encoding: .utf8))
        #expect(json.contains("\"10.0.0.0/8\""))
        #expect(json.contains("\"*.evil.com\""))
    }

    @Test func missingKeysTakeDefaults() throws {
        let decoded = try JSONDecoder().decode(NetworkPolicy.self, from: Data("{\"blockedPorts\":[22]}".utf8))
        var expected = NetworkPolicy()
        expected.blockedPorts = [22]
        #expect(decoded == expected)
        #expect(try JSONDecoder().decode(NetworkPolicy.self, from: Data("{}".utf8)) == NetworkPolicy())
    }

    @Test(arguments: [
        "{\"blockedAddresses\":[\"10.0.0.0/33\"]}", "{\"blockedAddresses\":[\"2130706433\"]}", "{\"blockedDomains\":[\"a..b\"]}",
        "{\"blockedDomains\":[\"127.1\"]}", "{\"blockedURLPrefixes\":[\"https://x.example/a\"]}", "{\"mode\":\"allowEverything\"}",
        "{\"vpn\":\"sometimes\"}", "{\"blockedPorts\":[70000]}", "{\"blockedAddresses\":[7]}",
    ])
    func invalidPersistedRulesFailToDecodeRatherThanBeingDropped(json: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(NetworkPolicy.self, from: Data(json.utf8)) }
    }

    @Test func ipAddressesRoundTripThroughCanonicalText() throws {
        for text in ["0.0.0.0", "255.255.255.255", "::", "::1", "2001:db8::1", "fe80::1:2", "1:2:3:4:5:6:7:8", "2001:0:0:1::1"] {
            let ip = try address(text)
            #expect(try JSONDecoder().decode([IPAddress].self, from: JSONEncoder().encode([ip])) == [ip])
            #expect(try address(ip.description) == ip)
        }
        #expect(try address("2001:DB8:0:0:0:0:0:1").description == "2001:db8::1")
        #expect(try address("1:0:0:2:0:0:0:3").description == "1:0:0:2::3")
    }
}
