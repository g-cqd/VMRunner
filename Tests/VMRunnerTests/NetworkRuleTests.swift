import Foundation
import Testing

@testable import VMRunner

struct AddressRuleTests {
    @Test(arguments: [
        ("10.0.0.0/8", "10.255.255.255", true), ("10.0.0.0/8", "11.0.0.0", false), ("10.0.0.0/8", "9.255.255.255", false),
        ("0.0.0.0/0", "255.255.255.255", true), ("0.0.0.0/0", "::1", false), ("::/0", "2606:4700::1", true),
        ("::/0", "1.2.3.4", false), ("1.2.3.4/32", "1.2.3.4", true), ("1.2.3.4", "1.2.3.5", false), ("1.2.3.4", "1.2.3.4", true),
        ("::1/128", "::1", true), ("::1", "::2", false), ("2001:db8::/32", "2001:db8:ffff::1", true),
        ("2001:db8::/32", "2001:db9::", false), ("192.168.1.128/25", "192.168.1.255", true),
        ("192.168.1.128/25", "192.168.1.127", false), ("fe80::/10", "febf::1", true), ("fe80::/10", "fec0::1", false),
        ("1.2.3.4/31", "1.2.3.5", true), ("1.2.3.4/31", "1.2.3.6", false),
    ])
    func containsRespectsPrefixBoundaries(rule: String, candidate: String, expected: Bool) throws {
        #expect(try AddressRule(rule).contains(address(candidate)) == expected)
    }

    @Test(arguments: [
        ("10.1.2.3/8", "10.0.0.0/8"), ("192.168.1.130/25", "192.168.1.128/25"), ("1.2.3.4/0", "0.0.0.0/0"),
        ("ff::1:2/16", "ff::/16"), ("  10.0.0.1  ", "10.0.0.1"), ("::FFFF:A00:1", "10.0.0.1"), ("2001:DB8::1/128", "2001:db8::1"),
        ("::ffff:10.0.0.0/104", "10.0.0.0/8"), ("::ffff:0:0/96", "0.0.0.0/0"),
    ])
    func hostBitsAreClearedAndTheFormIsCanonical(input: String, canonical: String) throws {
        let rule = try AddressRule(input)
        #expect(rule.description == canonical)
        #expect(try AddressRule(rule.description) == rule)
    }

    @Test func mappedRulesBehaveLikeTheirIPv4Equivalent() throws {
        let rule = try AddressRule("::ffff:10.0.0.0/104")
        #expect(rule.contains(try address("10.9.9.9")))
        #expect(!rule.contains(try address("::ffff:10.9.9.9")), "mapped addresses are normalized by the evaluator, not the rule")
    }

    @Test func shorterThanMappedIPv6RulesStayIPv6() throws {
        let rule = try AddressRule("::ffff:0:0/80")
        #expect(rule.network == .v6(0))
        #expect(rule.prefixLength == 80)
    }

    @Test(arguments: [
        "", " ", "/", "/8", "10.0.0.0/", "10.0.0.0/33", "10.0.0.0/-1", "10.0.0.0/+8", "10.0.0.0/8/8", "10.0.0.0/ 8", "10.0.0.0/0x8",
        "10.0.0.0/8a", "::1/129", "::1/-1", "10.0.0/8", "10.0.0.0.0", "256.0.0.1", "01.2.3.4", "010.0.0.1", "127.1", "2130706433",
        "0x7f000001", "0177.0.0.1", "abc", "10.0.0.1 /8", "fe80::1%en0", "[::1]", "::1::", "1:2:3:4:5:6:7:8:9", "::ffff:010.0.0.1",
        "1.2.3.4\u{0}", "１２７.0.0.1", "10.0.0.0/٨",
    ])
    func malformedRulesAreRejected(input: String) {
        #expect(throws: NetworkPolicyError.self) { try AddressRule(input) }
    }

    @Test func errorsNameTheProblem() {
        #expect(throws: NetworkPolicyError.empty) { try AddressRule("  ") }
        #expect(throws: NetworkPolicyError.invalidPrefixLength("10.0.0.0/33")) { try AddressRule("10.0.0.0/33") }
        #expect(throws: NetworkPolicyError.invalidAddress("127.1")) { try AddressRule("127.1") }
        #expect(NetworkPolicyError.invalidAddress("127.1").errorDescription?.contains("127.1") == true)
    }
}

struct DomainRuleTests {
    @Test(arguments: [
        ("evil.com", "evil.com", true), ("evil.com", "www.evil.com", false), ("evil.com", "notevil.com", false),
        ("evil.com", "evil.com.au", false), ("*.evil.com", "evil.com", false), ("*.evil.com", "www.evil.com", true),
        ("*.evil.com", "a.b.evil.com", true), ("*.evil.com", "notevil.com", false), ("*.evil.com", "xevil.com", false),
        ("*.com", "evil.com", true), ("*.com", "com", false), ("a.b", "a.b", true), ("a-b_c.example", "a-b_c.example", true),
    ])
    func matchingUsesLabelBoundaries(rule: String, host: String, expected: Bool) throws {
        #expect(try DomainRule(rule).matches(host) == expected)
    }

    @Test(arguments: [
        ("Evil.COM", "evil.com"), ("evil.com.", "evil.com"), ("*.Evil.Com.", "*.evil.com"), ("  *.evil.com\n", "*.evil.com"),
        ("xn--bcher-kva.example", "xn--bcher-kva.example"),
    ])
    func rulesAreNormalized(input: String, canonical: String) throws {
        #expect(try DomainRule(input).description == canonical)
    }

    @Test(arguments: [
        "", " ", "*.", "*", "evil.*", "*.*.evil.com", "ev*l.com", "a..b", ".evil.com", "evil..com", "..", ".", "-evil.com",
        "evil-.com", "evil com", "evil.com/path", "http://evil.com", "evil.com:80", "user@evil.com", "bücher.de", "evil.com\u{0}",
        "%65vil.com", String(repeating: "a", count: 64) + ".com",
    ])
    func malformedNamesAreRejected(input: String) {
        #expect(throws: NetworkPolicyError.self) { try DomainRule(input) }
    }

    @Test(arguments: ["127.0.0.1", "127.1", "2130706433", "0x7f000001", "0177.0.0.1", "[::1]", "::1", "*.127.0.0.1", "1.2.3.4."])
    func addressSpellingsAreRejectedAsDomains(input: String) {
        #expect(throws: NetworkPolicyError.domainLooksLikeAddress(input)) { try DomainRule(input) }
    }

    @Test func wildcardAndExactRulesAreDistinctValues() throws {
        #expect(try DomainRule("evil.com") != DomainRule("*.evil.com"))
        #expect(try DomainRule("EVIL.com.") == DomainRule("evil.com"))
    }
}

struct URLRuleTests {
    @Test(arguments: [
        ("http://x.example/admin", "http://x.example/admin"), ("HTTP://X.Example:8080/Admin/", "http://x.example:8080/admin"),
        ("http://x.example", "http://x.example/"), ("http://x.example/", "http://x.example/"),
        ("http://*.x.example/a/b", "http://*.x.example/a/b"), ("http://[::1]:8080/a", "http://[::1]:8080/a"),
        ("http://10.0.0.1/a", "http://10.0.0.1/a"), ("http://x.example/a/../b", "http://x.example/b"),
        ("http://x.example/a%2Fb", "http://x.example/a/b"), ("http://x.example/%41dmin;v=1/", "http://x.example/admin"),
        ("http://x.example./a", "http://x.example/a"), ("  http://x.example/a  ", "http://x.example/a"),
        ("http://[::ffff:10.0.0.1]/a", "http://10.0.0.1/a"),
    ])
    func rulesParseToACanonicalForm(input: String, canonical: String) throws {
        let rule = try URLRule(input)
        #expect(rule.description == canonical)
        #expect(try URLRule(rule.description) == rule)
    }

    @Test(arguments: [
        "", "  ", "x.example/admin", "://x.example", "http://", "http:///a", "http://x.example:0/", "http://x.example:99999/",
        "http://x.example:/", "http://x.example:abc/", "http://x.example:80:80/", "http://[::1/", "http://[::1]x/", "http://127.1/",
        "http://2130706433/", "http://x .example/", "http://x.example/%00", "http://a..b/", "http://bücher.de/",
    ])
    func malformedRulesAreRejected(input: String) {
        #expect(throws: NetworkPolicyError.self) { try URLRule(input) }
    }

    @Test(arguments: [
        ("https://x.example/admin", "https"), ("ftp://x.example/", "ftp"), ("file:///etc/passwd", "file"),
        ("HTTPS://x.example", "https"), ("ws://x.example/", "ws"),
    ])
    func onlyHTTPCanCarryAPathRule(input: String, scheme: String) {
        #expect(throws: NetworkPolicyError.unsupportedScheme(scheme)) { try URLRule(input) }
    }

    @Test(arguments: [
        ("http://u:p@x.example/", "credentials"), ("http://x.example/a?b=1", "a query or fragment"),
        ("http://x.example/#top", "a query or fragment"), ("http://x.example?x", "a query or fragment"),
    ])
    func credentialsQueriesAndFragmentsAreRejected(input: String, component: String) {
        #expect(throws: NetworkPolicyError.unsupportedURLComponent(component)) { try URLRule(input) }
    }

    @Test func matchingChecksHostPortAndSegmentBoundaries() throws {
        let rule = try URLRule("http://x.example:8080/admin")
        let host = HostForm.name("x.example")
        #expect(rule.matches(host: host, port: 8080, pathSegments: ["admin"]))
        #expect(rule.matches(host: host, port: 8080, pathSegments: ["admin", "users", "1"]))
        #expect(!rule.matches(host: host, port: 8080, pathSegments: ["administrator"]))
        #expect(!rule.matches(host: host, port: 8080, pathSegments: []))
        #expect(!rule.matches(host: host, port: 80, pathSegments: ["admin"]))
        #expect(!rule.matches(host: .name("y.example"), port: 8080, pathSegments: ["admin"]))
        #expect(!rule.matches(host: .name("sub.x.example"), port: 8080, pathSegments: ["admin"]))
        let whole = try URLRule("http://x.example")
        #expect(whole.matches(host: host, port: 1234, pathSegments: ["anything"]))
    }

    @Test func addressRulesCompareAfterMappedNormalization() throws {
        let rule = try URLRule("http://10.0.0.1/a")
        #expect(try rule.matches(host: .address(address("::ffff:10.0.0.1")), port: 80, pathSegments: ["a"]))
        #expect(try !rule.matches(host: .address(address("10.0.0.2")), port: 80, pathSegments: ["a"]))
    }
}
