import Foundation
import Testing

@testable import VMRunner

private let publicAddress = "93.184.216.34"

private func start(_ policy: NetworkPolicy = NetworkPolicy(), configure: (inout UserNetConfig) -> Void = { _ in }) -> CoreRig {
    let rig = CoreRig(policy: policy, configure: configure)
    rig.learnGuest()
    return rig
}

private func ask(_ rig: CoreRig, _ name: String, type: Int = 1) {
    rig.send(Wire.guestUDP(to: (Wire.gateway, 53), from: 41_000, Wire.dnsQuery(id: 0x2222, name: name, type: type)))
}

private struct Reply {
    let code: Int
    let answers: [(type: Int, dataLength: Int)]
    let payload: [UInt8]
}

private func takeReply(_ rig: CoreRig) -> Reply? {
    let frames = rig.host.takeFrames()
    guard let frame = frames.first(where: { $0.proto == IPProtocol.udp && $0.sourcePort == 53 }),
        let reader = DNSResponseReader(frame.payload)
    else { return nil }
    return Reply(code: Int(frame.payload[3] & 0x0F), answers: reader.answers, payload: frame.payload)
}

/// Asks the proxy and, when it hands the question to the resolver, answers it with `result`.
@discardableResult
private func resolve(_ rig: CoreRig, _ name: String, type: Int = 1, _ result: DNSLookupResult) -> Reply? {
    let before = rig.host.resolutions.count
    ask(rig, name, type: type)
    if rig.host.resolutions.count > before {
        rig.core.nameResolved(token: rig.host.resolutions[before].token, result: result)
    }
    return takeReply(rig)
}

private func a(_ owner: String, _ address: String, ttl: UInt32 = 60) -> DNSRecord {
    DNSRecord(name: owner, type: DNSCode.typeA, ttl: ttl, data: Wire.be32(ipv4(address)))
}

private func cname(_ owner: String, _ target: String) -> DNSRecord {
    DNSRecord(name: owner, type: DNSCode.typeCNAME, ttl: 60, data: DNSWire.encodeName(target) ?? [])
}

private func ptr(_ owner: String, _ data: [UInt8]) -> DNSRecord {
    DNSRecord(name: owner, type: DNSCode.typePTR, ttl: 60, data: data)
}

private func result(_ records: [DNSRecord]) -> DNSLookupResult { DNSLookupResult(responseCode: DNSCode.noError, records: records) }

private func remembered(_ rig: CoreRig, _ address: String) -> [String] {
    rig.core.gate.names.names(for: ipv4(address), now: rig.core.ctx.now)
}

private func denials(_ rig: CoreRig, _ reason: NetworkPolicy.Reason) -> Int {
    rig.events { $0 == .denied(.policy(reason)) }.count
}

struct UserNetDNSQuestionPolicyTests {
    @Test func allowListModeResolvesOnlyNamesAnAllowRuleNames() throws {
        var policy = NetworkPolicy()
        policy.mode = .allowListed
        policy.allowedDomains = [try DomainRule("*.allowed.test")]
        policy.allowedConnections = [try ConnectionRule("conn.test:443")]
        let rig = start(policy)
        ask(rig, "other.test")
        #expect(try #require(takeReply(rig)).code == 3, "an unlisted name gets the configured block response")
        #expect(rig.host.resolutions.isEmpty, "and never reaches the resolver")
        #expect(denials(rig, .notAllowListed) == 1)
        ask(rig, "www.allowed.test")
        ask(rig, "conn.test")
        #expect(rig.host.resolutions.map(\.name) == ["www.allowed.test", "conn.test"])
    }

    @Test func allowListModeUsesTheConfiguredBlockCode() {
        var policy = NetworkPolicy()
        policy.mode = .allowListed
        let rig = start(policy) { $0.dnsBlockResponse = .refused }
        ask(rig, "other.test")
        #expect(takeReply(rig)?.code == 5 && rig.host.resolutions.isEmpty)
    }

    @Test func blockListModeStillResolvesOrdinaryNames() {
        let rig = start()
        ask(rig, "anything.test")
        #expect(rig.host.resolutions.map(\.name) == ["anything.test"])
    }

    @Test func onlyTheTypesAGuestNeedsAreForwarded() throws {
        let rig = start()
        for type in [16, 15, 33, 65, 255, 2, 6] {
            ask(rig, "host.test", type: type)
            #expect(try #require(takeReply(rig)).code == 4, "type \(type) is not implemented")
        }
        #expect(rig.host.resolutions.isEmpty)
        ask(rig, "host.test", type: 1)
        ask(rig, "host.test", type: 5)
        ask(rig, "4.3.2.1.in-addr.arpa", type: 12)
        #expect(rig.host.resolutions.map(\.type) == [1, 5, 12])
        ask(rig, "host.test", type: 28)
        let aaaa = try #require(takeReply(rig))
        #expect(aaaa.code == 0 && aaaa.answers.isEmpty && rig.host.resolutions.count == 3)
    }

    @Test(arguments: ["printer.local", "local", "x.arpa", "arpa", "home.arpa", "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.ip6.arpa"])
    func localAndArpaNamesAreRefused(name: String) throws {
        let rig = start()
        for type in [1, 12] {
            ask(rig, name, type: type)
            #expect(try #require(takeReply(rig)).code == 3)
        }
        #expect(rig.host.resolutions.isEmpty)
        #expect(denials(rig, .reservedName) == 1, "the second, identical refusal is counted, not published again")
        #expect(rig.core.stats.deniedEventsSuppressed == 1)
    }

    @Test(arguments: [
        "1.2.3.in-addr.arpa", "01.2.3.4.in-addr.arpa", "1.2.3.4.5.in-addr.arpa", "256.2.3.4.in-addr.arpa", "a.2.3.4.in-addr.arpa",
    ])
    func aMalformedReverseNameIsRefused(name: String) throws {
        let rig = start()
        ask(rig, name, type: 12)
        #expect(try #require(takeReply(rig)).code == 3 && rig.host.resolutions.isEmpty)
    }

    @Test func aReverseLookupIsJudgedAsTheAddressItNames() throws {
        let rig = start()
        ask(rig, "34.216.184.93.in-addr.arpa", type: 12)
        #expect(rig.host.resolutions.count == 1, "a public address is looked up")
        for name in ["5.0.0.10.in-addr.arpa", "1.0.0.127.in-addr.arpa", "254.169.254.169.in-addr.arpa"] {
            ask(rig, name, type: 12)
            #expect(try #require(takeReply(rig)).code == 3, "\(name) names a host the policy refuses")
        }
        #expect(rig.host.resolutions.count == 1)
        #expect(denials(rig, .reservedRange(.privateNetwork, address: .v4(ipv4("10.0.0.5")))) == 1)
    }

    @Test func aReverseLookupFollowsTheAllowListInAllowListMode() throws {
        var policy = NetworkPolicy()
        policy.mode = .allowListed
        policy.allowedAddresses = [try AddressRule("93.184.216.0/24")]
        let rig = start(policy)
        ask(rig, "34.216.184.93.in-addr.arpa", type: 12)
        ask(rig, "34.216.185.93.in-addr.arpa", type: 12)
        #expect(rig.host.resolutions.map(\.name) == ["34.216.184.93.in-addr.arpa"])
        #expect(try #require(takeReply(rig)).code == 3)
    }

    @Test func aPolicyChangeWhileTheResolverWorksIsHonouredWhenTheAnswerArrives() throws {
        let rig = start()
        ask(rig, "host.test")
        let request = try #require(rig.host.resolutions.first)
        var blocking = NetworkPolicy()
        blocking.blockedDomains = [try DomainRule("host.test")]
        rig.core.updatePolicy(blocking, existingFlows: .keep)
        rig.core.nameResolved(token: request.token, result: result([a("host.test", publicAddress)]))
        let reply = try #require(takeReply(rig))
        #expect(reply.code == 3 && reply.answers.isEmpty)
        #expect(remembered(rig, publicAddress).isEmpty, "a refused answer teaches the name table nothing")
        #expect(rig.events { if case .denied(.policy(.blockedDomain)) = $0 { true } else { false } }.count == 1)
    }

    @Test func switchingToAnAllowListWhileTheResolverWorksIsHonouredToo() throws {
        let rig = start()
        ask(rig, "host.test")
        var allowing = NetworkPolicy()
        allowing.mode = .allowListed
        rig.core.updatePolicy(allowing, existingFlows: .keep)
        rig.core.nameResolved(token: rig.host.resolutions[0].token, result: result([a("host.test", publicAddress)]))
        #expect(try #require(takeReply(rig)).code == 3 && remembered(rig, publicAddress).isEmpty)
    }
}

struct UserNetDNSAnswerPolicyTests {
    @Test func addressesThePolicyRefusesAreRemovedFromTheAnswer() throws {
        let rig = start()
        let records = ["127.0.0.1", "169.254.169.254", "10.1.2.3", "0.0.0.0", publicAddress].map { a("host.test", $0) }
        let reply = try #require(resolve(rig, "host.test", result(records)))
        #expect(reply.code == 0 && reply.answers.count == 1)
        #expect(Array(reply.payload.suffix(4)) == Wire.be32(ipv4(publicAddress)))
        #expect(remembered(rig, publicAddress) == ["host.test"])
        for refused in ["127.0.0.1", "169.254.169.254", "10.1.2.3"] { #expect(remembered(rig, refused).isEmpty) }
    }

    @Test func aNameWhoseAddressesAreAllRefusedIsRefusedAndReported() throws {
        let rig = start { $0.dnsBlockResponse = .refused }
        let reply = try #require(resolve(rig, "internal.test", result([a("internal.test", "10.1.2.3"), a("internal.test", "127.0.0.1")])))
        #expect(reply.code == 5 && reply.answers.isEmpty)
        #expect(denials(rig, .reservedRange(.privateNetwork, address: .v4(ipv4("10.1.2.3")))) == 1)
        #expect(rig.core.gate.names.count < 1)
        #expect(rig.core.stats.dnsBlocked == 1)
    }

    @Test func blockedAddressRulesApplyToAnswersToo() throws {
        var policy = NetworkPolicy()
        policy.blockPrivateRanges = false
        policy.blockedAddresses = [try AddressRule("93.184.216.0/24")]
        let rig = start(policy)
        let reply = try #require(resolve(rig, "host.test", result([a("host.test", publicAddress), a("host.test", "10.1.2.3")])))
        #expect(reply.answers.count == 1 && Array(reply.payload.suffix(4)) == [10, 1, 2, 3], "private is allowed here, the block is not")
    }

    @Test func aDecisionThatDependsOnThePortIsLeftToTheConnection() throws {
        var policy = NetworkPolicy()
        policy.mode = .allowListed
        policy.allowedConnections = [try ConnectionRule("host.test:443")]
        policy.allowedPorts = [443]
        let rig = start(policy)
        let reply = try #require(resolve(rig, "host.test", result([a("host.test", publicAddress)])))
        #expect(reply.code == 0 && reply.answers.count == 1)
    }

    @Test func anAnswerKeepsOnlyTheRecordsOfTheChainFromTheQueriedName() throws {
        let rig = start()
        let records = [a("other.test", "6.6.6.6"), a("host.test", publicAddress), a("third.test", "7.7.7.7")]
        let reply = try #require(resolve(rig, "host.test", result(records)))
        #expect(reply.answers.count == 1)
        #expect(remembered(rig, "6.6.6.6").isEmpty && remembered(rig, "7.7.7.7").isEmpty)
        #expect(remembered(rig, publicAddress) == ["host.test"])
    }

    @Test func aCNAMEChainIsFollowedAndEveryNameOnItIsRemembered() throws {
        let rig = start()
        let records = [a("cdn.test", publicAddress), cname("host.test", "edge.test"), cname("edge.test", "cdn.test")]
        let reply = try #require(resolve(rig, "host.test", result(records)))
        #expect(reply.answers.map(\.type) == [5, 5, 1], "chain first, in order")
        #expect(remembered(rig, publicAddress) == ["host.test", "edge.test", "cdn.test"])
    }

    @Test func aCNAMELoopAndAnEndlessChainAreBounded() throws {
        let rig = start()
        let loop = try #require(resolve(rig, "a.test", result([cname("a.test", "b.test"), cname("b.test", "a.test")])))
        #expect(loop.code == 0 && loop.answers.count == 1)
        let links = (0..<20).map { cname("c\($0).test", "c\($0 + 1).test") } + [a("c20.test", publicAddress)]
        let long = try #require(resolve(rig, "c0.test", result(links)))
        #expect(
            long.answers.count == 8 && remembered(rig, publicAddress).isEmpty, "an address at the end of an over-long chain is not reached")
    }

    @Test func aChainThroughABlockedNameIsRefused() throws {
        var policy = NetworkPolicy()
        policy.blockedDomains = [try DomainRule("evil.test")]
        let rig = start(policy)
        let reply = try #require(resolve(rig, "host.test", result([cname("host.test", "evil.test"), a("evil.test", publicAddress)])))
        #expect(reply.code == 3 && reply.answers.isEmpty && remembered(rig, publicAddress).isEmpty)
        #expect(rig.events { if case .denied(.policy(.blockedDomain)) = $0 { true } else { false } }.count == 1)
    }

    @Test func anAllowListDoesNotApplyToTheNamesOfAChain() throws {
        var policy = NetworkPolicy()
        policy.mode = .allowListed
        policy.allowedDomains = [try DomainRule("host.test")]
        let rig = start(policy)
        let reply = try #require(resolve(rig, "host.test", result([cname("host.test", "cdn.other"), a("cdn.other", publicAddress)])))
        #expect(reply.answers.count == 2 && remembered(rig, publicAddress) == ["host.test", "cdn.other"])
    }

    @Test func recordsThatAnErrorCodeCameWithAreNotPassedOn() throws {
        let rig = start()
        let reply = try #require(resolve(rig, "host.test", DNSLookupResult(responseCode: 3, records: [a("host.test", publicAddress)])))
        #expect(reply.code == 3 && reply.answers.isEmpty && rig.core.gate.names.count < 1)
    }

    @Test func anAnswerWithNothingUsableInItIsAServerFailure() throws {
        let rig = start()
        let junk = DNSRecord(name: "host.test", type: DNSCode.typeA, ttl: 60, data: [1, 2, 3])
        #expect(try #require(resolve(rig, "host.test", result([junk]))).code == 2)
        let empty = try #require(resolve(rig, "host.test", result([])))
        #expect(empty.code == 0 && empty.answers.isEmpty, "no data is not a failure")
    }

    @Test func manyAddressesAreCappedSoOneAnswerCannotFlushTheNameTable() throws {
        let rig = start()
        let records = (0..<200).map { a("host.test", "93.184.\($0 / 200).\($0 + 1)") }
        let reply = try #require(resolve(rig, "host.test", result(records)))
        #expect(rig.core.gate.names.count == 32, "the first 32 are kept")
        #expect(reply.answers.count <= 32, "and the UDP message may carry fewer still")
    }
}

struct UserNetDNSRecordDataTests {
    private static let reverse = "4.3.2.1.in-addr.arpa"

    private static let invalidNames: [[UInt8]] = [
        [0xC0, 0x0C],  // a compression pointer
        [3, 0x61, 0x62],  // a label that runs past the data
        [1, 0x61],  // no terminator
        [1, 0x61, 0, 0],  // bytes after the name
        [1, 0x2E, 0],  // a dot inside a label
        [1, 0x07, 0],  // a control byte
        [1, 0x20, 0],  // a space
        [1, 0xE9, 0],  // not ASCII
        [64] + [UInt8](repeating: 0x61, count: 64) + [0],  // a label over 63 bytes
        [],
    ]

    @Test(arguments: invalidNames)
    func aPTRWithoutAWellFormedNameIsDropped(data: [UInt8]) throws {
        let rig = start()
        let reply = try #require(resolve(rig, Self.reverse, type: 12, result([ptr(Self.reverse, data)])))
        #expect(reply.code == 2 && reply.answers.isEmpty)
    }

    @Test func aCNAMEWithoutAWellFormedTargetIsDropped() throws {
        let rig = start()
        let bad = DNSRecord(name: "host.test", type: DNSCode.typeCNAME, ttl: 60, data: [0xC0, 0x0C])
        let reply = try #require(resolve(rig, "host.test", result([bad, a("host.test", publicAddress)])))
        #expect(reply.answers.map(\.type) == [1], "the address of the queried name stays")
    }

    @Test func aValidPTRIsRebuiltInCanonicalForm() throws {
        let rig = start()
        let shouting: [UInt8] = [4] + Array("Host".utf8) + [4] + Array("TEST".utf8) + [0]
        let reply = try #require(resolve(rig, Self.reverse, type: 12, result([ptr(Self.reverse, shouting)])))
        #expect(reply.code == 0 && reply.answers.count == 1)
        #expect(Array(reply.payload.suffix(11)) == [4] + Array("host".utf8) + [4] + Array("test".utf8) + [0])
    }

    @Test func recordsOfOtherTypesAreNotEchoed() throws {
        let rig = start()
        let txt = DNSRecord(name: "host.test", type: 16, ttl: 60, data: [1, 0x61])
        let reply = try #require(resolve(rig, "host.test", result([txt, a("host.test", publicAddress)])))
        #expect(reply.answers.map(\.type) == [1])
    }

    @Test func namesAreDecodedAndEncodedBothWays() {
        let encoded = DNSWire.encodeName("a.example.test")
        #expect(encoded.flatMap(DNSWire.decodeName) == "a.example.test")
        #expect(DNSWire.decodeName([0])?.isEmpty == true, "the root name has no labels")
        let fourFullLabels = ["a", "b", "c", "d"].map { String(repeating: $0, count: 63) }.joined(separator: ".")
        #expect(DNSWire.encodeName(fourFullLabels) == nil, "four full labels need 257 bytes")
    }
}

struct UserNetResolverNameTests {
    @Test func theResolverAsksForAnAbsoluteName() {
        #expect(SystemNameResolver.fullyQualified("host") == "host.")
        #expect(SystemNameResolver.fullyQualified("a.b.test") == "a.b.test.")
        #expect(SystemNameResolver.fullyQualified("a.b.test.") == "a.b.test.")
    }
}
