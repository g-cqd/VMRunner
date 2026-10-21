import Foundation
import Testing

@testable import VMRunner

private func start(_ configure: (inout UserNetConfig) -> Void = { _ in }) -> CoreRig {
    let rig = CoreRig(configure: configure)
    rig.learnGuest()
    return rig
}

private func query(_ rig: CoreRig, _ name: String, type: Int = 1, server: UInt32 = Wire.gateway, port: UInt16 = 41_000) {
    rig.send(Wire.guestUDP(to: (server, 53), from: port, Wire.dnsQuery(id: 0xBEEF, name: name, type: type)))
}

private func address(_ text: String, ttl: UInt32 = 60) -> DNSRecord {
    DNSRecord(name: "host.test", type: 1, ttl: ttl, data: Wire.be32(ipv4(text)))
}

struct UserNetDNSProxyTests {
    @Test func aQueryIsResolvedByTheHostAndAnsweredFromTheGateway() throws {
        let rig = start()
        query(rig, "host.test")
        let request = try #require(rig.host.resolutions.first)
        #expect(request.name == "host.test" && request.type == 1)
        #expect(rig.host.frames.isEmpty, "the guest waits for the resolver")
        rig.core.nameResolved(token: request.token, result: DNSLookupResult(responseCode: 0, records: [address("10.1.2.3")]))
        let response = try #require(rig.host.takeFrames().first)
        #expect(response.ipSource == Wire.gateway && response.sourcePort == 53 && response.destinationPort == 41_000)
        #expect(response.transportChecksumValid && response.ipChecksumValid)
        #expect(Array(response.payload[0..<2]) == [0xBE, 0xEF])
        #expect(response.payload[3] & 0x0F == 0 && response.payload[7] == 1)
        #expect(Array(response.payload.suffix(4)) == [10, 1, 2, 3])
        #expect(rig.events { $0 == .answered(responseCode: 0) }.first?.destinationName == "host.test")
    }

    @Test func aaaaIsAnsweredEmptyWithoutAskingTheHost() throws {
        let rig = start()
        query(rig, "host.test", type: 28)
        let response = try #require(rig.host.takeFrames().first)
        #expect(response.payload[3] & 0x0F == 0 && response.payload[7] == 0)
        #expect(rig.host.resolutions.isEmpty)
    }

    @Test func otherRecordTypesAreForwardedToTheResolver() throws {
        let rig = start()
        for type in [5, 15, 16, 33, 65] { query(rig, "host.test", type: type) }
        #expect(rig.host.resolutions.map(\.type) == [5, 15, 16, 33, 65])
        let request = rig.host.resolutions[1]
        let mx = DNSRecord(name: "host.test", type: 15, ttl: 5, data: [0, 10, 0])
        rig.core.nameResolved(token: request.token, result: DNSLookupResult(responseCode: 0, records: [mx]))
        let response = try #require(rig.host.takeFrames().first)
        #expect(response.payload[7] == 1)
    }

    @Test func resolverFailuresPassThrough() throws {
        let rig = start()
        query(rig, "nothing.test")
        rig.core.nameResolved(token: rig.host.resolutions[0].token, result: DNSLookupResult(responseCode: 3))
        #expect(try #require(rig.host.takeFrames().first).payload[3] & 0x0F == 3)
    }

    @Test func aSlowResolverGetsSERVFAILAndALateAnswerIsDiscarded() throws {
        let rig = start { $0.dnsTimeout = 2 }
        query(rig, "slow.test")
        rig.advance(1)
        #expect(rig.host.frames.isEmpty)
        rig.advance(1.5)
        #expect(try #require(rig.host.takeFrames().first).payload[3] & 0x0F == 2)
        rig.core.nameResolved(token: rig.host.resolutions[0].token, result: DNSLookupResult(responseCode: 0, records: [address("1.1.1.1")]))
        #expect(rig.host.frames.isEmpty)
        #expect(rig.core.dns.pendingCount == 0)
    }

    @Test func unusualQueriesAreRefusedNotForwarded() throws {
        let rig = start()
        var inverse = Wire.dnsQuery(id: 1, name: "host.test")
        inverse[2] = 0x08  // opcode 1
        rig.send(Wire.guestUDP(to: (Wire.gateway, 53), inverse))
        #expect(try #require(rig.host.takeFrames().first).payload[3] & 0x0F == 4)
        var chaos = Wire.dnsQuery(id: 2, name: "version.bind", type: 16)
        chaos[chaos.count - 1] = 3  // class CH
        rig.send(Wire.guestUDP(to: (Wire.gateway, 53), chaos))
        #expect(try #require(rig.host.takeFrames().first).payload[3] & 0x0F == 5)
        rig.send(Wire.guestUDP(to: (Wire.gateway, 53), [1, 2, 3]))
        #expect(rig.host.frames.isEmpty && rig.host.resolutions.isEmpty)
    }

    @Test func queriesToOtherServersAreInterceptedAndAnsweredFromThatAddress() throws {
        let rig = start()
        query(rig, "host.test", server: ipv4("8.8.8.8"))
        #expect(rig.host.datagrams.isEmpty, "no UDP flow to the external resolver is created")
        rig.core.nameResolved(token: rig.host.resolutions[0].token, result: DNSLookupResult(responseCode: 0, records: [address("4.4.4.4")]))
        let response = try #require(rig.host.takeFrames().first)
        #expect(response.ipSource == ipv4("8.8.8.8") && response.sourcePort == 53)
    }

    @Test func interceptionCanBeTurnedOff() {
        let rig = start { $0.interceptAllDNS = false }
        query(rig, "host.test", server: ipv4("8.8.8.8"))
        #expect(rig.host.resolutions.isEmpty)
        #expect(rig.host.datagrams.count == 1, "it is an ordinary UDP flow, judged by the policy")
    }

    @Test func manyUnansweredQueriesAreBounded() {
        let rig = start()
        for index in 0..<400 { query(rig, "n\(index).test", port: UInt16(30_000 + index)) }
        #expect(rig.core.dns.pendingCount == 256)
    }

    @Test func dnsHintsFeedTheVPNDetectorOnlyWhenConfigured() throws {
        let hint = try DomainRule("*.vpn-hint.test")
        let rig = start { $0.vpnDetection.hintDomains = [hint] }
        query(rig, "node.vpn-hint.test")
        query(rig, "node.vpn-hint.test", port: 41_001)
        #expect(rig.host.vpnStates.last.map { if case .suspected(.dnsHint, .low, _, _) = $0 { true } else { false } } == true)
    }
}

struct UserNetDNSOverTCPTests {
    @Test func aTCPQueryToTheGatewayIsAnsweredOnTheStream() throws {
        let rig = start()
        var guest = GuestConnection(rig: rig, to: (Wire.gateway, 53))
        guest.sendSYN()
        #expect(rig.host.streamOrder.isEmpty, "DNS over TCP never opens a host socket")
        #expect(guest.serverISN != 0 || guest.expected != 0)
        guest.sendACK()
        let message = Wire.dnsQuery(id: 0x1234, name: "host.test")
        guest.sendData(Wire.be16(message.count) + message)
        let request = try #require(rig.host.resolutions.first)
        rig.core.nameResolved(token: request.token, result: DNSLookupResult(responseCode: 0, records: [address("10.9.8.7")]))
        guest.collect()
        let length = Int(guest.received[0]) << 8 | Int(guest.received[1])
        #expect(guest.received.count == 2 + length)
        #expect(Array(guest.received[2..<4]) == [0x12, 0x34])
        #expect(Array(guest.received.suffix(4)) == [10, 9, 8, 7])
        guest.send([.fin, .ack])
        guest.sendACK()
        #expect(guest.sawFIN)
        #expect(rig.events { if case .opened = $0 { true } else { false } }.isEmpty, "DNS sessions are not reported as flows")
    }

    @Test func queriesSplitAcrossSegmentsAreReassembled() throws {
        let rig = start()
        var guest = GuestConnection(rig: rig, to: (Wire.gateway, 53))
        guest.sendSYN()
        guest.sendACK()
        let message = Wire.dnsQuery(id: 7, name: "split.test")
        let framed = Wire.be16(message.count) + message
        guest.sendData(Array(framed.prefix(5)))
        #expect(rig.host.resolutions.isEmpty)
        guest.sendData(Array(framed.dropFirst(5)))
        #expect(rig.host.resolutions.count == 1)
    }

    @Test func aTCPQueryToAnotherServerIsIntercepted() {
        let rig = start()
        var guest = GuestConnection(rig: rig, to: (ipv4("1.1.1.1"), 53))
        guest.sendSYN()
        #expect(rig.host.streamOrder.isEmpty)
    }
}

struct UserNetSystemResolverTests {
    /// `localhost` comes from /etc/hosts, so the system resolver answers it without touching the network.
    @Test func theSystemResolverAnswersLocalhostFromTheHostsFile() async {
        let result = await SystemNameResolver().lookup(name: "localhost", recordType: DNSCode.typeA)
        #expect(result.responseCode == DNSCode.noError)
        #expect(result.records.contains { $0.type == DNSCode.typeA && $0.data == [127, 0, 0, 1] })
    }

    @Test func unsupportedLookupsFailSafelyWithoutHanging() async {
        let result = await SystemNameResolver().lookup(name: "bad name with spaces", recordType: 16)
        #expect(result.responseCode != DNSCode.noError || result.records.isEmpty)
    }
}
