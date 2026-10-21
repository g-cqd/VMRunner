import Foundation
import Testing

@testable import VMRunner

private let remote = (ipv4("93.184.216.34"), UInt16(5_000))

private func open(_ policy: NetworkPolicy = CoreRig.openPolicy, configure: (inout UserNetConfig) -> Void = { _ in }) -> CoreRig {
    let rig = CoreRig(policy: policy, configure: configure)
    rig.learnGuest()
    return rig
}

struct UserNetUDPTests {
    @Test func aDatagramOpensAFlowAndAnswersComeBackFromTheRemoteAddress() throws {
        let rig = open()
        rig.send(Wire.guestUDP(to: remote, from: 40_001, [1, 2, 3]))
        let (token, socket) = try #require(rig.host.datagrams.first)
        #expect(socket.kind == .udp && socket.address == remote.0 && socket.port == remote.1)
        #expect(socket.written == [[1, 2, 3]])
        #expect(rig.events { $0 == .opened }.count == 1)
        rig.host.datagrams[token]?.incoming = [[9, 9], [8]]
        rig.core.datagramReadable(token: token)
        let replies = rig.host.takeFrames()
        #expect(replies.count == 2)
        #expect(replies[0].ipSource == remote.0 && replies[0].sourcePort == remote.1 && replies[0].destinationPort == 40_001)
        #expect(replies[0].payload == [9, 9] && replies[0].ipChecksumValid && replies[0].transportChecksumValid)
        #expect(replies[0].destination == Wire.guestMAC)
    }

    @Test func theSameFiveTupleReusesItsSocketAndNewTuplesGetTheirOwn() {
        let rig = open()
        rig.send(Wire.guestUDP(to: remote, from: 40_001, [1]))
        rig.send(Wire.guestUDP(to: remote, from: 40_001, [2]))
        #expect(rig.host.datagrams.count == 1)
        rig.send(Wire.guestUDP(to: remote, from: 40_002, [3]))
        rig.send(Wire.guestUDP(to: (remote.0, 5_001), from: 40_001, [4]))
        #expect(rig.host.datagrams.count == 3)
        #expect(rig.core.stats.activeUDPFlows == 3)
    }

    @Test func idleFlowsAreClosedAndReported() throws {
        let rig = open { $0.udpIdleTimeout = 30 }
        rig.send(Wire.guestUDP(to: remote, [1]))
        rig.advance(20)
        rig.send(Wire.guestUDP(to: remote, [2]))
        rig.advance(20)
        #expect(rig.core.stats.activeUDPFlows == 1, "traffic restarts the idle clock")
        rig.advance(11)
        #expect(rig.core.stats.activeUDPFlows == 0)
        let closed = try #require(rig.events { $0 == .closed(.idleTimeout) }.first)
        #expect(closed.bytesToHost == 2 && closed.transport == .udp)
        #expect(rig.host.datagrams.values.allSatisfy { $0.closed })
    }

    @Test func policyIsEvaluatedPerNewFlowAndDeniedFlowsOpenNoSocket() {
        let rig = open(NetworkPolicy())
        rig.send(Wire.guestUDP(to: (ipv4("127.0.0.1"), 9_999), [1]))
        #expect(rig.host.datagrams.isEmpty)
        #expect(rig.core.stats.udpFlowsDenied == 1)
    }

    @Test func aDeniedFlowProducesOneEventUntilItsDenialExpires() {
        let rig = open(NetworkPolicy())
        let denied: (FlowEvent.Phase) -> Bool = { if case .denied = $0 { true } else { false } }
        for _ in 0..<50 { rig.send(Wire.guestUDP(to: (ipv4("127.0.0.1"), 9_999), [1])) }
        #expect(rig.events(denied).count == 1)
        // When the interval ends, one more event says how many were folded into it (49), then a new refusal is news again.
        rig.advance(6)
        #expect(rig.events(denied).map(\.count) == [1, 49])
        rig.send(Wire.guestUDP(to: (ipv4("127.0.0.1"), 9_999), [1]))
        #expect(rig.events(denied).map(\.count) == [1, 49, 1])
    }

    @Test func broadcastAndMulticastAreDropped() {
        let rig = open()
        rig.send(Wire.guestUDP(to: (IPv4.broadcast, 9_999), [1]))
        rig.send(Wire.guestUDP(to: (ipv4("198.18.0.255"), 9_999), [1]))
        rig.send(Wire.guestUDP(to: (ipv4("224.0.0.251"), 5_353), [1]))
        #expect(rig.host.datagrams.isEmpty && rig.core.stats.droppedUnsupported == 3)
    }

    @Test func aSocketThatCannotBeOpenedIsReportedAsUnroutable() {
        let rig = open()
        rig.host.refuseDatagrams = true
        rig.send(Wire.guestUDP(to: remote, [1]))
        #expect(rig.events { $0 == .denied(.unroutable) }.count == 1)
    }

    @Test func repliesLargerThanTheMTUAreFragmentedAndReassembleExactly() throws {
        let rig = open()
        rig.send(Wire.guestUDP(to: remote, from: 40_001, [1]))
        let token = try #require(rig.host.datagrams.keys.first)
        let reply = pattern(4_000)
        rig.host.datagrams[token]?.incoming = [reply]
        rig.core.datagramReadable(token: token)
        let frames = rig.host.takeFrames()
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.ipChecksumValid && $0.ipPayload.count <= 1_480 })
        #expect(frames.map { ($0.fragmentField & 0x1FFF) * 8 } == [0, 1_480, 2_960])
        #expect(frames.map { $0.fragmentField & 0x2000 != 0 } == [true, true, false])
        #expect(Set(frames.map(\.fragmentField).map { $0 & 0x4000 }) == [0], "fragments never carry don't-fragment")
        let datagram = frames.flatMap(\.ipPayload)
        #expect(datagram.count == 8 + reply.count)
        #expect(Array(datagram[8...]) == reply)
        #expect(Wire.checksum(datagram, seed: Wire.pseudoSeed(remote.0, Wire.guest, IPProtocol.udp, datagram.count)) == 0)
    }

    @Test func theFlowLimitEvictsTheOldestFlow() throws {
        let rig = open { $0.maxUDPFlows = 2 }
        rig.send(Wire.guestUDP(to: remote, from: 40_001, [1]))
        rig.advance(1)
        rig.send(Wire.guestUDP(to: remote, from: 40_002, [1]))
        rig.advance(1)
        rig.send(Wire.guestUDP(to: remote, from: 40_003, [1]))
        #expect(rig.core.stats.activeUDPFlows == 2)
        #expect(rig.events { $0 == .closed(.evicted) }.count == 1)
    }

    @Test func policyChangesTearDownDatagramFlowsToo() throws {
        let rig = open()
        rig.send(Wire.guestUDP(to: remote, [1]))
        var strict = CoreRig.openPolicy
        strict.blockedPorts = [PortRule(remote.1)]
        #expect(rig.core.updatePolicy(strict, existingFlows: .terminate) == 1)
        #expect(rig.core.stats.activeUDPFlows == 0)
        #expect(rig.events { if case .closed(.policyRevoked) = $0 { true } else { false } }.count == 1)
    }
}

struct UserNetICMPTests {
    @Test func anAllowedEchoIsRelayedThroughAnICMPSocketAndTheReplyReturns() throws {
        let rig = open()
        let echo = Wire.icmpEcho(identifier: 0x77, sequence: 1, data: [1, 2, 3, 4])
        rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: remote.0, proto: IPProtocol.icmp, echo)))
        let (token, socket) = try #require(rig.host.datagrams.first)
        #expect(socket.kind == .icmpEcho && socket.address == remote.0 && socket.written == [echo])
        let reply = Wire.icmpEcho(type: 0, identifier: 0x77, sequence: 1, data: [1, 2, 3, 4])
        rig.host.datagrams[token]?.incoming = [reply]
        rig.core.datagramReadable(token: token)
        let frame = try #require(rig.host.takeFrames().first)
        #expect(frame.icmpType == 0 && frame.payload == reply && frame.ipSource == remote.0 && frame.transportChecksumValid)
        rig.send(
            Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: remote.0, proto: IPProtocol.icmp, Wire.icmpEcho(identifier: 0x77, sequence: 2)))
        )
        #expect(rig.host.datagrams.count == 1, "the same identifier reuses the socket")
    }

    @Test func aDeniedDestinationGetsNoSocketAndNoReply() {
        let rig = open(NetworkPolicy())
        let echo = Wire.icmpEcho(identifier: 1, sequence: 1)
        rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: ipv4("127.0.0.1"), proto: IPProtocol.icmp, echo)))
        #expect(rig.host.datagrams.isEmpty && rig.host.frames.isEmpty)
        #expect(rig.events { if case .denied(.policy) = $0 { true } else { false } }.first?.transport == .icmp)
    }

    @Test func pingIgnoresThePortAllowList() throws {
        var policy = CoreRig.openPolicy
        policy.mode = .allowListed
        policy.allowedAddresses = [try AddressRule("93.184.216.34")]
        policy.allowedPorts = [443]
        let rig = open(policy)
        rig.send(
            Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: remote.0, proto: IPProtocol.icmp, Wire.icmpEcho(identifier: 1, sequence: 1))))
        #expect(rig.host.datagrams.count == 1)
        rig.send(
            Wire.guestFrame(
                Wire.ipv4(from: Wire.guest, to: ipv4("8.8.8.8"), proto: IPProtocol.icmp, Wire.icmpEcho(identifier: 2, sequence: 1))))
        #expect(rig.host.datagrams.count == 1)
    }

    @Test func idleEchoFlowsExpire() {
        let rig = open { $0.icmpIdleTimeout = 10 }
        rig.send(
            Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: remote.0, proto: IPProtocol.icmp, Wire.icmpEcho(identifier: 1, sequence: 1))))
        rig.advance(11)
        #expect(rig.core.stats.activeUDPFlows == 0)
    }
}
