import Foundation
import Testing

@testable import VMRunner

private let example = ipv4("93.184.216.34")

/// What happened to a guest's attempt to connect.
private enum Attempt: Equatable {
    case connected, refused, silent
}

private func policy(_ configure: (inout NetworkPolicy) throws -> Void) rethrows -> NetworkPolicy {
    var value = NetworkPolicy()
    value.blockPrivateRanges = false
    try configure(&value)
    return value
}

private func attempt(_ rig: CoreRig, to target: (UInt32, UInt16), port: UInt16 = 50_000) -> Attempt {
    var guest = GuestConnection(rig: rig, to: target, from: port)
    let before = rig.host.streamOrder.count
    let answer = guest.sendSYN()
    if rig.host.streamOrder.count > before { return .connected }
    return answer.contains { $0.flags.contains(.rst) } ? .refused : .silent
}

private struct DNSResult {
    var responseCode: Int
    var answerCount: Int
    var frame: DecodedFrame?
}

/// Sends a DNS query for `name` through the proxy and, if the proxy asks the host to resolve it, answers with `addresses`.
private func resolve(
    _ rig: CoreRig, _ name: String, type: Int = 1, addresses: [String] = [], canonical: String? = nil, server: UInt32 = Wire.gateway
) -> DNSResult {
    let before = rig.host.resolutions.count
    rig.send(Wire.guestUDP(to: (server, 53), from: 41_000, Wire.dnsQuery(id: 0x1111, name: name, type: type)))
    if rig.host.resolutions.count > before {
        let request = rig.host.resolutions[before]
        let owner = canonical ?? name
        var records: [DNSRecord] = []
        if let canonical { records.append(DNSRecord(name: name, type: 5, ttl: 60, data: DNSWire.encodeName(canonical) ?? [])) }
        for text in addresses {
            records.append(DNSRecord(name: owner, type: 1, ttl: 60, data: Wire.be32(ipv4(text))))
        }
        rig.core.nameResolved(token: request.token, result: DNSLookupResult(responseCode: 0, records: records))
    }
    let frame = rig.host.takeFrames().first { $0.proto == IPProtocol.udp && $0.sourcePort == 53 }
    guard let frame, frame.payload.count >= 12 else { return DNSResult(responseCode: -1, answerCount: 0, frame: frame) }
    return DNSResult(
        responseCode: Int(frame.payload[3] & 0x0F), answerCount: Int(frame.payload[6]) << 8 | Int(frame.payload[7]), frame: frame)
}

struct UserNetDefaultPolicyTests {
    @Test func theDefaultPolicyRefusesLoopbackAndPrivateTargets() throws {
        let rig = CoreRig(policy: NetworkPolicy())
        #expect(attempt(rig, to: (ipv4("127.0.0.1"), 8_080)) == .refused)
        #expect(attempt(rig, to: (ipv4("10.0.0.5"), 22), port: 50_001) == .refused)
        #expect(attempt(rig, to: (ipv4("192.168.64.1"), 22), port: 50_002) == .refused)
        #expect(attempt(rig, to: (ipv4("169.254.169.254"), 80), port: 50_003) == .refused)
        #expect(rig.host.streamOrder.isEmpty, "a denied destination never gets a host connection")
        let denials = rig.events { if case .denied(.policy(.reservedRange)) = $0 { true } else { false } }
        #expect(denials.count == 4)
        #expect(attempt(rig, to: (example, 443), port: 50_004) == .connected)
    }

    /// Turning the switch off admits private networks; loopback is on the floor and stays refused (UserNetFloorTests).
    @Test func turningOffPrivateRangeBlockingAdmitsPrivateNetworks() {
        let rig = CoreRig(policy: policy { _ in })
        #expect(attempt(rig, to: (ipv4("10.0.0.5"), 8_080)) == .connected)
        #expect(attempt(rig, to: (ipv4("127.0.0.1"), 8_080), port: 50_001) == .refused)
    }

    @Test func denialsCarryTheReasonAndDestination() throws {
        let rig = CoreRig(policy: NetworkPolicy())
        _ = attempt(rig, to: (ipv4("127.0.0.1"), 8_080))
        let event = try #require(rig.host.events.first)
        #expect(event.transport == .tcp && event.destinationPort == 8_080)
        #expect(event.destinationAddress == .v4(ipv4("127.0.0.1")))
        #expect(event.phase == .denied(.policy(.reservedRange(.loopback, address: .v4(ipv4("127.0.0.1"))))))
    }

    @Test func dropModeStaysSilent() {
        let rig = CoreRig(policy: NetworkPolicy()) { $0.denyAction = .drop }
        #expect(attempt(rig, to: (ipv4("127.0.0.1"), 80)) == .silent)
        #expect(rig.events { if case .denied = $0 { true } else { false } }.count == 1)
    }

    @Test func theGatewayServesDNSAndNothingElse() {
        let rig = CoreRig()
        #expect(attempt(rig, to: (Wire.gateway, 22)) == .refused)
        #expect(rig.events { $0 == .denied(.gatewayService(port: 22)) }.count == 1)
        rig.send(Wire.guestUDP(to: (Wire.gateway, 123), [1, 2, 3]))
        #expect(rig.events { $0 == .denied(.gatewayService(port: 123)) }.count == 1)
        #expect(rig.host.datagrams.isEmpty)
    }
}

struct UserNetPolicyRuleTests {
    @Test func denyListByAddressBlocksOnlyThatBlock() throws {
        let rig = CoreRig(policy: try policy { $0.blockedAddresses = [try AddressRule("93.184.216.0/24")] })
        #expect(attempt(rig, to: (example, 443)) == .refused)
        #expect(attempt(rig, to: (ipv4("8.8.8.8"), 443), port: 50_001) == .connected)
    }

    @Test func denyListByPortBlocksThePortEverywhere() throws {
        let rig = CoreRig(policy: try policy { $0.blockedPorts = [22, try PortRule("8000-8100")] })
        #expect(attempt(rig, to: (example, 22)) == .refused)
        #expect(attempt(rig, to: (ipv4("8.8.8.8"), 8_050), port: 50_001) == .refused)
        #expect(attempt(rig, to: (example, 443), port: 50_002) == .connected)
    }

    @Test func denyListByConnectionBlocksAPortOnADestination() throws {
        let rig = CoreRig(policy: try policy { $0.blockedConnections = [try ConnectionRule("93.184.216.0/24:22,8080")] })
        #expect(attempt(rig, to: (example, 22)) == .refused)
        #expect(attempt(rig, to: (example, 8_080), port: 50_001) == .refused)
        #expect(attempt(rig, to: (example, 443), port: 50_002) == .connected)
        #expect(attempt(rig, to: (ipv4("8.8.8.8"), 22), port: 50_003) == .connected)
    }

    @Test func allowListByAddressAdmitsOnlyListedAddresses() throws {
        let rig = CoreRig(
            policy: try policy {
                $0.mode = .allowListed
                $0.allowedAddresses = [try AddressRule("93.184.216.34")]
            })
        #expect(attempt(rig, to: (example, 443)) == .connected)
        #expect(attempt(rig, to: (ipv4("8.8.8.8"), 443), port: 50_001) == .refused)
        #expect(rig.events { $0 == .denied(.policy(.notAllowListed)) }.count == 1)
    }

    @Test func allowListPortsNarrowAnAllowedAddress() throws {
        let rig = CoreRig(
            policy: try policy {
                $0.mode = .allowListed
                $0.allowedAddresses = [try AddressRule("93.184.216.0/24")]
                $0.allowedPorts = [443]
            })
        #expect(attempt(rig, to: (example, 443)) == .connected)
        #expect(attempt(rig, to: (example, 22), port: 50_001) == .refused)
        #expect(rig.events { $0 == .denied(.policy(.portNotAllowListed(22))) }.count == 1)
    }

    @Test func allowListConnectionsGrantOneDestinationAndPort() throws {
        let rig = CoreRig(
            policy: try policy {
                $0.mode = .allowListed
                $0.allowedConnections = [try ConnectionRule("93.184.216.34:443")]
            })
        #expect(attempt(rig, to: (example, 443)) == .connected)
        #expect(attempt(rig, to: (example, 80), port: 50_001) == .refused)
    }

    @Test func denyBeatsAllow() throws {
        let rig = CoreRig(
            policy: try policy {
                $0.mode = .allowListed
                $0.allowedAddresses = [try AddressRule("93.184.216.0/24")]
                $0.blockedConnections = [try ConnectionRule("93.184.216.34:22")]
                $0.blockedPorts = [25]
            })
        #expect(attempt(rig, to: (example, 443)) == .connected)
        #expect(attempt(rig, to: (example, 22), port: 50_001) == .refused)
        #expect(attempt(rig, to: (example, 25), port: 50_002) == .refused)
    }

    @Test func privateRangesStayBlockedEvenWhenAllowListed() throws {
        var strict = NetworkPolicy()
        strict.mode = .allowListed
        strict.allowedAddresses = [try AddressRule("10.0.0.0/8")]
        let rig = CoreRig(policy: strict)
        #expect(attempt(rig, to: (ipv4("10.1.2.3"), 22)) == .refused)
    }
}

struct UserNetDomainPolicyTests {
    @Test func aBlockedDomainIsAnsweredNXDOMAINWithoutAskingTheHost() throws {
        let rig = CoreRig(policy: try policy { $0.blockedDomains = [try DomainRule("*.evil.test")] })
        let blocked = resolve(rig, "cdn.evil.test", addresses: ["6.6.6.6"])
        #expect(blocked.responseCode == 3 && blocked.answerCount == 0)
        #expect(rig.host.resolutions.isEmpty, "a blocked name never reaches the resolver")
        #expect(rig.events { if case .denied(.policy(.blockedDomain)) = $0 { true } else { false } }.count == 1)
        #expect(rig.core.stats.dnsBlocked == 1)
        let allowed = resolve(rig, "good.test", addresses: ["1.2.3.4"])
        #expect(allowed.responseCode == 0 && allowed.answerCount == 1)
    }

    @Test func theBlockResponseIsConfigurable() throws {
        let rig = CoreRig(policy: try policy { $0.blockedDomains = [try DomainRule("evil.test")] }) { $0.dnsBlockResponse = .refused }
        #expect(resolve(rig, "evil.test").responseCode == 5)
    }

    @Test func aCNAMEIntoABlockedNameIsCaught() throws {
        let rig = CoreRig(policy: try policy { $0.blockedDomains = [try DomainRule("tracker.test")] })
        let result = resolve(rig, "innocent.test", addresses: ["6.6.6.6"], canonical: "tracker.test")
        #expect(result.responseCode == 3 && result.answerCount == 0)
        #expect(attempt(rig, to: (ipv4("6.6.6.6"), 443)) == .connected, "nothing was learned about the blocked answer")
    }

    @Test func aBlockedConnectionRuleOnAllPortsBlocksResolution() throws {
        let rig = CoreRig(policy: try policy { $0.blockedConnections = [try ConnectionRule("evil.test")] })
        #expect(resolve(rig, "evil.test", addresses: ["6.6.6.6"]).responseCode == 3)
        let onePort = CoreRig(policy: try policy { $0.blockedConnections = [try ConnectionRule("evil.test:22")] })
        #expect(resolve(onePort, "evil.test", addresses: ["6.6.6.6"]).responseCode == 0)
    }

    @Test func aConnectionToAnAnsweredAddressIsJudgedByItsName() throws {
        let rig = CoreRig(
            policy: try policy {
                $0.mode = .allowListed
                $0.allowedDomains = [try DomainRule("github.com")]
            })
        #expect(resolve(rig, "github.com", addresses: ["140.82.112.3"]).answerCount == 1)
        #expect(attempt(rig, to: (ipv4("140.82.112.3"), 443)) == .connected)
        #expect(attempt(rig, to: (ipv4("140.82.112.99"), 443), port: 50_001) == .refused, "an address nobody resolved is not allowed")
        #expect(rig.host.streams.values.allSatisfy { $0.address == ipv4("140.82.112.3") })
    }

    @Test func theConnectionEventNamesTheDestination() throws {
        let rig = CoreRig(
            policy: try policy {
                $0.mode = .allowListed
                $0.allowedDomains = [try DomainRule("github.com")]
            })
        _ = resolve(rig, "github.com", addresses: ["140.82.112.3"])
        var guest = GuestConnection(rig: rig, to: (ipv4("140.82.112.3"), 443))
        guest.establish()
        let opened = try #require(rig.events { $0 == .opened }.first)
        #expect(opened.destinationName == "github.com")
    }

    @Test func aNameRuleBlocksConnectionsToItsAddressesAfterThePolicyChanges() throws {
        let rig = CoreRig(policy: policy { _ in })
        _ = resolve(rig, "later.test", addresses: ["7.7.7.7"])
        var guest = GuestConnection(rig: rig, to: (ipv4("7.7.7.7"), 443))
        guest.establish()
        rig.core.updatePolicy(try policy { $0.blockedDomains = [try DomainRule("later.test")] }, existingFlows: .keep)
        #expect(attempt(rig, to: (ipv4("7.7.7.7"), 443), port: 50_009) == .refused, "new flows see the new rule at once")
        #expect(rig.core.stats.activeTCPFlows == 1, "the old flow is kept")
    }

    @Test func allowedDomainsDoNotOverrideBlockedAddresses() throws {
        let rig = CoreRig(
            policy: try policy {
                $0.mode = .allowListed
                $0.allowedDomains = [try DomainRule("github.com")]
                $0.blockedAddresses = [try AddressRule("140.82.112.0/24")]
            })
        _ = resolve(rig, "github.com", addresses: ["140.82.112.3"])
        #expect(attempt(rig, to: (ipv4("140.82.112.3"), 443)) == .refused)
    }

    @Test func nameTableExpiresAndStaysBounded() {
        var table = NameTable(capacity: 3)
        table.record(name: "a.test", address: 1, ttl: 10, now: 0)
        #expect(table.names(for: 1, now: 5) == ["a.test"])
        #expect(table.names(for: 1, now: 11).isEmpty)
        for address in 10...20 { table.record(name: "n\(address).test", address: UInt32(address), ttl: 100, now: 0) }
        #expect(table.count <= 3)
        for index in 0..<10 { table.record(name: "shared\(index).test", address: 99, ttl: 100, now: 0) }
        #expect(table.names(for: 99, now: 1).count == 4, "a shared address keeps its most recent names")
    }
}

struct UserNetPolicyChangeTests {
    private func openTwoFlows(_ rig: CoreRig) -> (GuestConnection, GuestConnection) {
        rig.learnGuest()
        var allowed = GuestConnection(rig: rig, to: (ipv4("8.8.8.8"), 443), from: 50_001)
        var doomed = GuestConnection(rig: rig, to: (example, 443), from: 50_002)
        allowed.establish()
        doomed.establish()
        return (allowed, doomed)
    }

    @Test func tighteningThePolicyTearsDownFlowsThatNoLongerPass() throws {
        let rig = CoreRig(policy: policy { _ in })
        var (allowed, doomed) = openTwoFlows(rig)
        let revoked = rig.core.updatePolicy(
            try policy { $0.blockedAddresses = [try AddressRule("93.184.216.0/24")] }, existingFlows: .terminate)
        #expect(revoked == 1)
        doomed.collect()
        allowed.collect()
        #expect(doomed.sawRST && !allowed.sawRST)
        #expect(rig.host.streams[doomed.token]?.closed == .aborted && rig.host.streams[allowed.token]?.closed == nil)
        let closed = rig.events { if case .closed(.policyRevoked) = $0 { true } else { false } }
        #expect(closed.count == 1)
        allowed.sendData([1])
        #expect(rig.host.streams[allowed.token]?.written == [1])
    }

    @Test func keepingFlowsLeavesThemAlone() throws {
        let rig = CoreRig(policy: policy { _ in })
        var (_, doomed) = openTwoFlows(rig)
        let revoked = rig.core.updatePolicy(try policy { $0.blockedAddresses = [try AddressRule("93.184.216.0/24")] }, existingFlows: .keep)
        doomed.collect()
        #expect(revoked == 0 && !doomed.sawRST)
        #expect(rig.core.stats.activeTCPFlows == 2)
    }

    @Test func relaxingThePolicyAdmitsNewFlowsImmediately() {
        let rig = CoreRig(policy: NetworkPolicy())
        #expect(attempt(rig, to: (ipv4("10.0.0.5"), 80)) == .refused)
        rig.core.updatePolicy(policy { _ in }, existingFlows: .terminate)
        #expect(attempt(rig, to: (ipv4("10.0.0.5"), 80), port: 50_001) == .connected)
    }

    @Test func aHostPathChangeResetsEveryFlowSoTheGuestReconnects() {
        let rig = CoreRig(policy: policy { _ in })
        var (first, second) = openTwoFlows(rig)
        rig.core.hostPathChanged(existingFlows: .terminate)
        first.collect()
        second.collect()
        #expect(first.sawRST && second.sawRST)
        #expect(rig.events { $0 == .closed(.hostPathChanged) }.count == 2)
        #expect(attempt(rig, to: (example, 443), port: 50_010) == .connected, "new flows are unaffected")
    }

    @Test func aHostPathChangeCanLeaveFlowsAlone() {
        let rig = CoreRig(policy: policy { _ in })
        var (first, _) = openTwoFlows(rig)
        rig.core.hostPathChanged(existingFlows: .keep)
        first.collect()
        #expect(!first.sawRST && rig.core.stats.activeTCPFlows == 2)
    }

    @Test func shutdownClosesEverythingAndReportsIt() {
        let rig = CoreRig(policy: policy { _ in })
        let (first, _) = openTwoFlows(rig)
        rig.send(Wire.guestUDP(to: (ipv4("9.9.9.9"), 9_999), [1]))
        rig.core.shutdown()
        #expect(rig.events { $0 == .closed(.stackStopped) }.count == 3)
        #expect(rig.host.streams[first.token]?.closed == .aborted)
        #expect(rig.host.datagrams.values.allSatisfy { $0.closed })
        #expect(rig.core.stats.activeTCPFlows == 0 && rig.core.stats.activeUDPFlows == 0)
    }
}
