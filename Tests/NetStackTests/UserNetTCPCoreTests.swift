import Foundation
import Testing

@testable import NetStack

private let server = (ipv4("93.184.216.34"), UInt16(443))

struct UserNetTCPHandshakeTests {
    @Test func theGuestHandshakeCompletesOnlyAfterTheHostConnects() throws {
        let rig = CoreRig()
        rig.learnGuest()
        var guest = GuestConnection(rig: rig, to: server)
        let immediate = guest.sendSYN(mss: 1_400, windowScale: 7)
        #expect(immediate.isEmpty, "no SYN-ACK before the host connection exists")
        #expect(rig.host.streamOrder.count == 1)
        let stream = try #require(rig.host.streams[rig.host.streamOrder[0]])
        #expect(stream.address == server.0 && stream.port == server.1)
        guest.token = rig.host.streamOrder[0]
        rig.core.streamConnected(token: guest.token, error: nil)
        let synAck = try #require(guest.collect().first)
        #expect(synAck.flags == [.syn, .ack])
        #expect(synAck.acknowledgement == 5_001)
        #expect(synAck.mss == 1_460, "MSS is the MTU minus 40")
        #expect(synAck.windowScale != nil, "window scaling is answered because the guest offered it")
        #expect(synAck.ipSource == server.0 && synAck.sourcePort == server.1, "the stack speaks as the destination")
        guest.sendACK()
        #expect(rig.events { $0 == .opened }.count == 1)
        #expect(rig.host.streams[guest.token]?.readInterest == true)
        #expect(rig.core.stats.activeTCPFlows == 1)
    }

    @Test func withoutTheWindowScaleOptionNeitherSideScales() throws {
        let rig = CoreRig()
        var guest = GuestConnection(rig: rig, to: server)
        guest.sendSYN(mss: nil, windowScale: nil)
        guest.token = rig.host.streamOrder[0]
        rig.core.streamConnected(token: guest.token, error: nil)
        let synAck = try #require(guest.collect().first)
        #expect(synAck.windowScale == nil)
        #expect(synAck.window == 65_535)
    }

    @Test func aRefusedHostConnectionAnswersRSTAndReportsIt() throws {
        let rig = CoreRig()
        var guest = GuestConnection(rig: rig, to: server)
        guest.sendSYN()
        guest.token = rig.host.streamOrder[0]
        rig.core.streamConnected(token: guest.token, error: ECONNREFUSED)
        let reset = try #require(guest.collect().first)
        #expect(reset.flags.contains(.rst) && reset.flags.contains(.ack))
        #expect(reset.acknowledgement == 5_001)
        #expect(rig.events { $0 == .closed(.connectFailed(ECONNREFUSED)) }.count == 1)
        #expect(rig.core.stats.activeTCPFlows == 0)
        #expect(rig.core.stats.tcpFlowsFailed == 1)
    }

    @Test func aHostConnectThatNeverFinishesTimesOut() throws {
        let rig = CoreRig()
        var guest = GuestConnection(rig: rig, to: server)
        guest.sendSYN()
        rig.advance(10)
        #expect(rig.host.takeFrames().isEmpty)
        rig.advance(11)
        let reset = try #require(rig.host.takeFrames().first)
        #expect(reset.flags.contains(.rst))
        #expect(rig.events { $0 == .closed(.connectFailed(0)) }.count == 1)
        #expect(rig.host.streams[rig.host.streamOrder[0]]?.closed == .aborted, "the pending host socket is aborted")
    }

    @Test func aResetWhileConnectingAbortsThePendingHostSocket() {
        let rig = CoreRig()
        var guest = GuestConnection(rig: rig, to: server)
        guest.sendSYN()
        let token = rig.host.streamOrder[0]
        guest.send([.rst, .ack], sequence: guest.sequence, acknowledgement: 0)
        #expect(rig.host.streams[token]?.closed == .aborted)
        #expect(rig.core.stats.activeTCPFlows == 0)
        #expect(rig.events { $0 == .closed(.guestReset) }.count == 1)
        rig.core.streamConnected(token: token, error: nil)  // a late completion is ignored
        #expect(rig.host.frames.isEmpty)
    }

    @Test func aRetransmittedSYNWhileConnectingOpensNoSecondConnection() {
        let rig = CoreRig()
        var guest = GuestConnection(rig: rig, to: server)
        guest.sendSYN()
        let retransmit = Wire.tcp(from: (Wire.guest, 50_000), to: server, sequence: 5_000, flags: .syn, mss: 1_460)
        rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: server.0, proto: IPProtocol.tcp, retransmit)))
        #expect(rig.host.streamOrder.count == 1)
        #expect(rig.host.frames.isEmpty)
    }

    @Test func aRetransmittedSYNAfterTheSynAckResendsTheSynAck() throws {
        let rig = CoreRig()
        var guest = GuestConnection(rig: rig, to: server)
        guest.sendSYN()
        guest.token = rig.host.streamOrder[0]
        rig.core.streamConnected(token: guest.token, error: nil)
        let first = try #require(guest.collect().first)
        let retransmit = Wire.tcp(from: (Wire.guest, 50_000), to: server, sequence: 5_000, flags: .syn, mss: 1_460)
        rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: server.0, proto: IPProtocol.tcp, retransmit)))
        let second = try #require(guest.collect().first)
        #expect(second.flags == [.syn, .ack] && second.sequence == first.sequence)
        #expect(rig.host.streamOrder.count == 1)
    }

    @Test func aMissingFinalAckMakesTheStackResendItsSynAck() throws {
        let rig = CoreRig()
        var guest = GuestConnection(rig: rig, to: server)
        guest.sendSYN()
        guest.token = rig.host.streamOrder[0]
        rig.core.streamConnected(token: guest.token, error: nil)
        guest.collect()
        rig.advance(0.3)
        let resent = try #require(guest.collect().first)
        #expect(resent.flags == [.syn, .ack])
    }

    @Test func segmentsForUnknownConnectionsGetTheRFCReset() throws {
        let rig = CoreRig()
        let withAck = Wire.tcp(from: (Wire.guest, 41_000), to: server, sequence: 77, acknowledgement: 9_000, flags: .ack, payload: [1])
        rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: server.0, proto: IPProtocol.tcp, withAck)))
        var reset = try #require(rig.host.takeFrames().first)
        #expect(reset.flags == .rst && reset.sequence == 9_000)
        let noAck = Wire.tcp(from: (Wire.guest, 41_000), to: server, sequence: 77, flags: .fin, payload: [1, 2])
        rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: server.0, proto: IPProtocol.tcp, noAck)))
        reset = try #require(rig.host.takeFrames().first)
        #expect(reset.flags == [.rst, .ack] && reset.sequence == 0 && reset.acknowledgement == 77 + 2 + 1)
        let rst = Wire.tcp(from: (Wire.guest, 41_000), to: server, sequence: 77, flags: .rst)
        rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: server.0, proto: IPProtocol.tcp, rst)))
        #expect(rig.host.frames.isEmpty, "never answer a reset with a reset")
    }

    @Test func theFlowLimitRefusesNewConnections() throws {
        let rig = CoreRig { $0.maxTCPFlows = 2 }
        var first = GuestConnection(rig: rig, to: server, from: 50_001)
        var second = GuestConnection(rig: rig, to: server, from: 50_002)
        var third = GuestConnection(rig: rig, to: server, from: 50_003)
        first.sendSYN()
        second.sendSYN()
        let refusal = try #require(third.sendSYN().first)
        #expect(refusal.flags.contains(.rst))
        #expect(rig.host.streamOrder.count == 2)
        #expect(rig.events { $0 == .denied(.flowLimit) }.count == 1)
    }
}
