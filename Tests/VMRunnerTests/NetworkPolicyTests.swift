import Foundation
import Testing

@testable import VMRunner

func address(_ text: String) throws -> IPAddress {
    try #require(IPAddress(strictLiteral: text), "test address \(text) must parse")
}

func addresses(_ texts: String...) throws -> [IPAddress] {
    try texts.map(address)
}

private let publicV4 = "93.184.216.34"

struct HostBypassTests {
    let policy = NetworkPolicy()

    /// Spellings of 127.0.0.1 that resolvers accept; none may be treated as an opaque name.
    @Test(arguments: [
        "2130706433", "0x7f000001", "0X7F000001", "0177.0.0.1", "127.1", "127.0.1", "0x7f.0.0.1", "017700000001",
        "0x7f.1", "127.0.0.0x1", "127.00.00.01", "127.0.0.01",
    ])
    func nonCanonicalLoopbackSpellingsAreDenied(host: String) throws {
        #expect(policy.evaluate(host: host, port: 80, resolvedAddresses: []) == .deny(.nonCanonicalAddress))
        // Even if a caller passes a public "resolution" for it, the spelling alone is a denial.
        let decision = policy.evaluate(host: host, port: 80, resolvedAddresses: try addresses(publicV4))
        #expect(decision == .deny(.nonCanonicalAddress))
    }

    @Test(arguments: ["010.0.0.1", "1.2.3", "256.1.1.1", "1.2.3.4.5", "99999999999", "0x", "1.2.3.04", "08.0.0.1"])
    func ambiguousOrOutOfRangeNumericHostsAreDenied(host: String) {
        #expect(policy.evaluate(host: host, port: 80, resolvedAddresses: []) == .deny(.nonCanonicalAddress))
    }

    @Test(arguments: [
        ("127.0.0.1", ReservedRangeKind.loopback), ("127.0.0.1.", .loopback), ("[::1]", .loopback), ("::1", .loopback),
        ("[fe80::1%en0]", .linkLocal), ("[fe80::1%25en0]", .linkLocal), ("0.0.0.0", .unspecified),
        ("::", .unspecified), ("169.254.169.254", .cloudMetadata), ("[::ffff:127.0.0.1]", .loopback),
    ])
    func canonicalLiteralsAreJudgedAsAddresses(host: String, kind: ReservedRangeKind) {
        guard case .deny(.reservedRange(let found, _)) = policy.evaluate(host: host, port: 80, resolvedAddresses: []) else {
            Issue.record("\(host) was not denied as a reserved address")
            return
        }
        #expect(found == kind)
    }

    @Test(arguments: [
        "", " ", ".", "..", "a..b", ".a.com", "-a.com", "a-.com", "exa mple.com", "ex%61mple.com", "%31%32%37.0.0.1",
        "ｅvil.com", "evil。com", "bücher.de", "evil.com:80", "a/b", "a@b", "a\\b", "[1.2.3.4]", "[evil.com]", "[::1", "::1]",
        "evil.com\u{0}", "evil.com\n", "[::g]", "1:2:3:4:5:6:7:8:9", ":::", "::ffff:010.0.0.1", "::ffff:1.2.3",
        String(repeating: "a", count: 64) + ".com",
    ])
    func malformedHostsAreDenied(host: String) {
        #expect(policy.evaluate(host: host, port: 80, resolvedAddresses: []) == .deny(.malformedHost))
    }

    @Test func overlongNamesAreDenied() {
        let label = String(repeating: "a", count: 63)
        let host = [label, label, label, label].joined(separator: ".")  // 255 characters
        #expect(policy.evaluate(host: host, port: 80, resolvedAddresses: []) == .deny(.malformedHost))
    }

    @Test func caseAndTrailingDotDoNotChangeANamesIdentity() throws {
        var blocking = NetworkPolicy()
        blocking.blockedDomains = [try DomainRule("evil.com")]
        let resolved = try addresses(publicV4)
        for host in ["evil.com", "EVIL.com", "Evil.Com.", "evil.com."] {
            #expect(
                blocking.evaluate(host: host, port: 443, resolvedAddresses: resolved) == .deny(.blockedDomain(try DomainRule("evil.com"))))
        }
    }
}

struct AddressJudgementTests {
    let policy = NetworkPolicy()

    @Test(arguments: [
        ("10.0.0.0", ReservedRangeKind.privateNetwork), ("10.255.255.255", .privateNetwork), ("172.16.0.0", .privateNetwork),
        ("172.31.255.255", .privateNetwork), ("192.168.0.1", .privateNetwork), ("192.168.255.255", .privateNetwork),
        ("192.168.64.1", .hostGateway), ("192.168.64.255", .hostGateway), ("127.255.255.255", .loopback),
        ("169.254.0.1", .linkLocal), ("169.254.169.254", .cloudMetadata), ("100.64.0.0", .carrierGradeNAT),
        ("100.127.255.255", .carrierGradeNAT), ("224.0.0.1", .multicast), ("239.255.255.255", .multicast),
        ("0.0.0.1", .unspecified), ("0.255.255.255", .unspecified), ("255.255.255.255", .reserved), ("240.0.0.1", .reserved),
        ("fe80::1", .linkLocal), ("febf::1", .linkLocal), ("fec0::1", .siteLocal), ("fc00::1", .uniqueLocal),
        ("fdff::1", .uniqueLocal), ("ff02::1", .multicast), ("::1", .loopback), ("::", .unspecified),
    ])
    func reservedRangesAreDenied(text: String, kind: ReservedRangeKind) throws {
        let decision = policy.evaluate(host: "svc.example", port: 443, resolvedAddresses: try addresses(text))
        #expect(decision == .deny(.reservedRange(kind, address: try address(text))))
    }

    @Test(arguments: [
        publicV4, "1.1.1.1", "11.0.0.0", "9.255.255.255", "172.15.255.255", "172.32.0.0", "192.167.255.255", "192.169.0.0",
        "169.253.255.255", "169.255.0.0", "100.63.255.255", "100.128.0.0", "223.255.255.255", "126.255.255.255", "128.0.0.0",
        "2606:4700:4700::1111", "2001:4860:4860::8888", "fbff::1", "fe7f::1",
    ])
    func publicAddressesPassJustOutsideEveryBoundary(text: String) throws {
        #expect(policy.evaluate(host: "svc.example", port: 443, resolvedAddresses: try addresses(text)) == .allow)
    }

    /// Encodings that smuggle a private IPv4 address inside IPv6.
    @Test(arguments: [
        "::ffff:10.0.0.1", "::ffff:a00:1", "0:0:0:0:0:ffff:10.0.0.1", "::FFFF:0A00:0001", "64:ff9b::a00:1", "64:ff9b::10.0.0.1",
        "2002:a00:1::1", "::10.0.0.1", "::a00:1", "::ffff:192.168.64.1", "::ffff:169.254.169.254",
    ])
    func embeddedPrivateIPv4IsStillPrivate(text: String) throws {
        let decision = policy.evaluate(host: "svc.example", port: 443, resolvedAddresses: try addresses(text))
        guard case .deny(.reservedRange) = decision else {
            Issue.record("\(text) was not denied: \(decision)")
            return
        }
        // And as a literal host, bracketed or not.
        for host in ["[\(text)]", text] {
            let literal = policy.evaluate(host: host, port: 443, resolvedAddresses: [])
            guard case .deny(.reservedRange) = literal else {
                Issue.record("\(host) was not denied as a literal: \(literal)")
                return
            }
        }
    }

    @Test func mappedPublicIPv4StaysPublic() throws {
        let mapped = try addresses("::ffff:93.184.216.34", "2002:5db8:d822::1")
        #expect(policy.evaluate(host: "svc.example", port: 443, resolvedAddresses: mapped) == .allow)
    }

    @Test func mappedFormsMatchCustomIPv4BlocksAndAreNormalized() throws {
        var blocking = NetworkPolicy()
        blocking.blockedAddresses = [try AddressRule("93.184.216.0/24")]
        for text in ["::ffff:93.184.216.34", "64:ff9b::5db8:d822", "2002:5db8:d822::7"] {
            let ip = try address(text)
            guard case .deny(.blockedAddress) = blocking.evaluate(host: "svc.example", port: 443, resolvedAddresses: [ip]) else {
                Issue.record("\(text) escaped a v4 block")
                continue
            }
        }
        #expect(try address("::ffff:1.2.3.4").normalized == address("1.2.3.4"))
        #expect(try address("2001:db8::1").normalized == address("2001:db8::1"))
    }

    @Test func turningOffPrivateBlockingAllowsPrivateTargets() throws {
        var open = NetworkPolicy()
        open.blockPrivateRanges = false
        #expect(open.evaluate(host: "10.0.0.1", port: 80, resolvedAddresses: []) == .allow)
        #expect(open.evaluate(host: "svc.example", port: 80, resolvedAddresses: try addresses("::1", "169.254.169.254")) == .allow)
    }

    /// DNS rebinding: the name is fine, one of the addresses behind it is not. Every address must pass.
    @Test(arguments: [
        ["93.184.216.34", "10.0.0.5"], ["10.0.0.5", "93.184.216.34"], ["93.184.216.34", "::ffff:127.0.0.1"],
        ["2606:4700:4700::1111", "fe80::1"], ["93.184.216.34", "1.1.1.1", "192.168.64.1"], ["93.184.216.34", "169.254.169.254"],
    ])
    func oneBadResolvedAddressDeniesTheName(texts: [String]) throws {
        let resolved = try texts.map(address)
        guard case .deny(.reservedRange) = policy.evaluate(host: "good.example", port: 443, resolvedAddresses: resolved) else {
            Issue.record("rebinding set \(texts) was allowed")
            return
        }
    }

    @Test func aNameWithoutResolvedAddressesIsDenied() {
        #expect(policy.evaluate(host: "good.example", port: 443, resolvedAddresses: []) == .deny(.unresolved))
        #expect(policy.evaluate(host: publicV4, port: 443, resolvedAddresses: []) == .allow)
    }

    @Test func customAddressBlocksApplyToResolvedAndLiteralAddresses() throws {
        var blocking = NetworkPolicy()
        blocking.blockedAddresses = try ["93.184.216.0/24", "2606:4700::/32", "1.1.1.1"].map(AddressRule.init)
        let rule = try AddressRule("93.184.216.0/24")
        let target = try address(publicV4)
        #expect(
            blocking.evaluate(host: "svc.example", port: 80, resolvedAddresses: [target]) == .deny(.blockedAddress(rule, address: target)))
        #expect(blocking.evaluate(host: publicV4, port: 80, resolvedAddresses: []) == .deny(.blockedAddress(rule, address: target)))
        #expect(!blocking.evaluate(host: "svc.example", port: 80, resolvedAddresses: try addresses("2606:4700:4700::1111")).isAllowed)
        #expect(!blocking.evaluate(host: "1.1.1.1", port: 80, resolvedAddresses: []).isAllowed)
        #expect(blocking.evaluate(host: "svc.example", port: 80, resolvedAddresses: try addresses("1.0.0.1")) == .allow)
    }

    @Test func blockedPortsDenyBeforeAnythingElse() throws {
        var blocking = NetworkPolicy()
        blocking.blockedPorts = [25, 22]
        let resolved = try addresses(publicV4)
        #expect(blocking.evaluate(host: "svc.example", port: 25, resolvedAddresses: resolved) == .deny(.blockedPort(25)))
        #expect(blocking.evaluate(host: "10.0.0.1", port: 22, resolvedAddresses: []) == .deny(.blockedPort(22)))
        #expect(blocking.evaluate(host: "svc.example", port: 443, resolvedAddresses: resolved) == .allow)
    }
}
