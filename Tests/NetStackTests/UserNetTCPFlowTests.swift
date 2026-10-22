import Foundation
import Testing

@testable import NetStack

private let server = (ipv4("93.184.216.34"), UInt16(443))

private func established(
    _ rig: CoreRig, from port: UInt16 = 50_000, windowScale: UInt8? = nil, guestWindow: Int = 65_535
) -> GuestConnection {
    rig.learnGuest()
    var guest = GuestConnection(rig: rig, to: server, from: port)
    guest.window = guestWindow
    guest.establish(windowScale: windowScale)
    return guest
}

struct UserNetTCPDataTests {
    @Test func guestDataReachesTheHostSocketInOrder() {
        let rig = CoreRig()
        var guest = established(rig)
        let first = pattern(1_000)
        let second = pattern(500, seed: 9)
        guest.sendData(first)
        guest.sendData(second)
        #expect(rig.host.streams[guest.token]?.written == first + second)
        #expect(guest.lastAcknowledgement == guest.sequence, "the bytes are acknowledged")
    }

    @Test func aBurstOfSegmentsReachesTheHostSocketInOneWriteAtTheEndOfTheBatch() {
        let rig = CoreRig()
        var guest = established(rig)
        let payload = pattern(8_000)
        var offset = 0
        while offset < payload.count {
            let chunk = Array(payload[offset..<min(offset + 1_000, payload.count)])
            let segment = Wire.tcp(
                from: (Wire.guest, 50_000), to: server, sequence: guest.sequence &+ UInt32(offset), acknowledgement: guest.expected,
                flags: .pushAck, payload: chunk)
            ByteView.withBytes(of: Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: server.0, proto: IPProtocol.tcp, segment))) {
                rig.core.receiveFrame($0)
            }
            offset += chunk.count
        }
        #expect(rig.host.streams[guest.token]?.written.isEmpty == true, "nothing is written until the batch ends")
        rig.core.endOfBatch()
        #expect(rig.host.streams[guest.token]?.written == payload)
        #expect(rig.host.streams[guest.token]?.writeCalls == 1, "eight segments, one write")
        guest.sequence &+= UInt32(payload.count)
        guest.collect()
        #expect(guest.lastAcknowledgement == guest.sequence)
    }

    @Test func theWindowEdgeDoesNotShrinkWhileABatchIsStaged() {
        let rig = CoreRig { $0.tcpReceiveBuffer = 32 * 1_024 }
        var guest = established(rig)
        let edgeBefore = Int(guest.lastAcknowledgement) + guest.advertised
        var offset = 0
        while offset < 16_000 {
            let segment = Wire.tcp(
                from: (Wire.guest, 50_000), to: server, sequence: guest.sequence &+ UInt32(offset), acknowledgement: guest.expected,
                flags: .pushAck, payload: pattern(1_000))
            ByteView.withBytes(of: Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: server.0, proto: IPProtocol.tcp, segment))) {
                rig.core.receiveFrame($0)
            }
            offset += 1_000
        }
        guest.collect()
        let edgeDuring = Int(guest.lastAcknowledgement) + guest.advertised
        #expect(edgeDuring >= edgeBefore, "staged bytes are acknowledged and occupy buffer, so the right edge holds still")
        rig.core.endOfBatch()
        guest.collect()
        #expect(Int(guest.lastAcknowledgement) + guest.advertised >= edgeDuring)
    }

    @Test func aSingleSegmentIsAcknowledgedAtTheEndOfTheBatch() {
        let rig = CoreRig()
        var guest = established(rig)
        let frames = guest.sendData([1, 2, 3])
        #expect(frames.count == 1 && frames[0].flags == .ack && frames[0].acknowledgement == guest.sequence)
    }

    @Test func hostDataIsSegmentedByTheMSSAndAcknowledgedByTheGuest() throws {
        let rig = CoreRig()
        var guest = established(rig)
        let payload = pattern(10_000)
        guest.serverSends(payload)
        #expect(guest.received == payload)
        #expect(guest.segmentSizes.allSatisfy { $0 <= 1_460 })
        #expect(guest.segmentSizes.dropLast().allSatisfy { $0 == 1_460 })
        guest.sendACK()
        #expect(rig.core.stats.tcpRetransmits == 0)
        rig.advance(5)
        #expect(rig.host.frames.isEmpty, "everything was acknowledged, so nothing is retransmitted")
    }

    @Test func theMSSFromTheSynBoundsTheSegmentSize() {
        let rig = CoreRig()
        rig.learnGuest()
        var guest = GuestConnection(rig: rig, to: server)
        guest.establish(mss: 536)
        guest.serverSends(pattern(3_000))
        #expect(guest.segmentSizes.allSatisfy { $0 <= 536 })
    }

    @Test func theGuestWindowLimitsTheBytesInFlight() {
        let rig = CoreRig()
        var guest = established(rig, guestWindow: 3_000)
        guest.serverSends(pattern(20_000))
        #expect(guest.received.count <= 3_000)
        #expect(guest.received.count >= 2_920)
        let before = guest.received.count
        guest.sendACK()
        #expect(guest.received.count > before, "an acknowledgement opens the window")
        #expect(guest.received.count <= before + 3_000)
    }

    @Test func aLargeTransferNeedsNoRetransmissionAndArrivesIntact() {
        let rig = CoreRig()
        var guest = established(rig, windowScale: 7)
        let payload = pattern(1_000_000)
        var offered = 0
        while guest.received.count < payload.count {
            let chunk = Array(payload[offered..<min(offered + 60_000, payload.count)])
            offered += chunk.count
            guest.serverSends(chunk)
            guest.sendACK()
            while rig.host.streams[guest.token]?.incoming.isEmpty == false || guest.received.count < offered {
                guest.sendACK()
                rig.core.streamReadable(token: guest.token)
                guest.collect()
                guest.sendACK()
            }
        }
        #expect(guest.received == payload)
        #expect(rig.core.stats.tcpRetransmits == 0)
    }

    @Test func hostBackPressureShrinksTheWindowAndResumesWhenTheSocketDrains() throws {
        let rig = CoreRig { $0.tcpReceiveBuffer = 32 * 1_024 }
        var guest = established(rig)
        rig.host.streams[guest.token]?.capacity = 0
        let big = pattern(60_000)
        // The guest sends only what the advertised window allows.
        var sent = 0
        while sent < big.count {
            let room = max(guest.advertised, 0)
            if room == 0 { break }
            let chunk = Array(big[sent..<min(sent + min(1_460, room), big.count)])
            guest.sendData(chunk)
            sent += chunk.count
        }
        #expect(rig.host.streams[guest.token]?.written.isEmpty == true)
        #expect(rig.host.streams[guest.token]?.writeInterest == true, "the core asks to be told when the socket drains")
        #expect(guest.advertised < 1_460, "the window closes as data is held back")
        let held = sent
        rig.host.streams[guest.token]?.capacity = .max
        rig.core.streamWritable(token: guest.token)
        guest.collect()
        #expect(rig.host.streams[guest.token]?.written == Array(big[..<held]))
        #expect(rig.host.streams[guest.token]?.writeInterest == false)
        #expect(guest.advertised > 30_000, "draining announces the reopened window")
    }

    @Test func aFullGuestBoundBufferPausesReadingFromTheHost() {
        let rig = CoreRig()
        var guest = established(rig, guestWindow: 0)
        rig.host.streams[guest.token]?.incoming = pattern(400_000)
        rig.core.streamReadable(token: guest.token)
        guest.collect()
        #expect(guest.received.isEmpty)
        for _ in 0..<4 { rig.core.streamReadable(token: guest.token) }
        let remaining = rig.host.streams[guest.token]?.incoming.count ?? 0
        #expect(remaining >= 400_000 - 128 * 1_024, "no more than the per-flow buffer is pulled from the socket")
        #expect(rig.host.streams[guest.token]?.readInterest == false, "reading stops until the buffer drains")
        guest.window = 65_535
        for _ in 0..<20 {
            guest.sendACK()
            rig.core.streamReadable(token: guest.token)
            guest.collect()
        }
        #expect(guest.received.count > 128 * 1_024)
        #expect(rig.host.streams[guest.token]?.readInterest == true)
    }

    @Test func outOfOrderAndDuplicateSegmentsAreNotForwarded() throws {
        let rig = CoreRig()
        var guest = established(rig)
        let data = pattern(100)
        let ahead = guest.send(.ack, payload: data, sequence: guest.sequence &+ 50)
        #expect(ahead.first?.acknowledgement == guest.sequence, "a duplicate ACK asks for the missing bytes")
        #expect(rig.host.streams[guest.token]?.written.isEmpty == true)
        let start = guest.sequence
        guest.sendData(data)
        let duplicate = guest.send(.ack, payload: data, sequence: start)
        #expect(duplicate.first?.acknowledgement == start &+ 100)
        #expect(rig.host.streams[guest.token]?.written == data, "the retransmitted copy is dropped")
    }

    @Test func overlappingRetransmissionForwardsOnlyTheNewBytes() {
        let rig = CoreRig()
        var guest = established(rig)
        let data = pattern(100)
        let start = guest.sequence
        guest.sendData(Array(data[..<60]))
        guest.send(.ack, payload: data, sequence: start)
        #expect(rig.host.streams[guest.token]?.written == data)
    }
}

struct UserNetTCPCloseTests {
    @Test func guestFinHalfClosesTheHostSocketAndTheHostMayKeepSending() throws {
        let rig = CoreRig()
        var guest = established(rig)
        guest.sendData(pattern(10))
        let acks = guest.send([.fin, .ack])
        #expect(acks.last?.acknowledgement == guest.sequence)
        #expect(rig.host.streams[guest.token]?.shutDown == true)
        guest.serverSends(pattern(5_000))
        #expect(guest.received.count == 5_000, "the response still flows after the guest closed its side")
        guest.sendACK()
        guest.serverCloses()
        #expect(guest.sawFIN)
        guest.sendACK()
        let closed = rig.events { if case .closed = $0 { true } else { false } }
        #expect(closed.count == 1 && closed[0].phase == .closed(.finished))
        #expect(closed[0].bytesToHost == 10 && closed[0].bytesToGuest == 5_000)
        #expect(rig.host.streams[guest.token]?.closed == .graceful, "the socket closes gracefully")
    }

    @Test func hostCloseFirstSendsFinAfterAllData() throws {
        let rig = CoreRig()
        var guest = established(rig)
        rig.host.streams[guest.token]?.incoming = pattern(3_000)
        rig.host.streams[guest.token]?.incomingEnds = true
        rig.core.streamReadable(token: guest.token)
        guest.collect()
        #expect(guest.received.count == 3_000 && guest.sawFIN)
        guest.sendACK()
        let finishing = guest.send([.fin, .ack])
        #expect(finishing.last?.acknowledgement == guest.sequence)
        #expect(rig.events { $0 == .closed(.finished) }.count == 1)
    }

    @Test func aFinWaitsForDataThatIsStillBlockedOnTheHostSocket() {
        let rig = CoreRig()
        var guest = established(rig)
        rig.host.streams[guest.token]?.capacity = 0
        guest.sendData(pattern(500))
        guest.send([.fin, .ack])
        #expect(rig.host.streams[guest.token]?.shutDown == false, "unsent data goes first")
        rig.host.streams[guest.token]?.capacity = .max
        rig.core.streamWritable(token: guest.token)
        #expect(rig.host.streams[guest.token]?.written.count == 500)
        #expect(rig.host.streams[guest.token]?.shutDown == true)
    }

    @Test func serverCloseWithPendingGuestDataStillDeliversIt() {
        let rig = CoreRig()
        var guest = established(rig)
        rig.host.streams[guest.token]?.capacity = 0
        guest.sendData(pattern(500))
        guest.serverCloses()
        guest.sendACK()
        guest.send([.fin, .ack])
        #expect(rig.events { $0 == .closed(.finished) }.isEmpty, "the flow cannot finish while guest data is unwritten")
        rig.host.streams[guest.token]?.capacity = .max
        rig.core.streamWritable(token: guest.token)
        #expect(rig.host.streams[guest.token]?.written.count == 500)
        #expect(rig.events { $0 == .closed(.finished) }.count == 1)
    }

    @Test func guestResetAbortsTheHostConnection() {
        let rig = CoreRig()
        var guest = established(rig)
        guest.send([.rst, .ack])
        #expect(rig.host.streams[guest.token]?.closed == .aborted)
        #expect(rig.events { $0 == .closed(.guestReset) }.count == 1)
        #expect(rig.core.stats.activeTCPFlows == 0)
    }

    @Test func aResetOutsideTheWindowIsIgnored() {
        let rig = CoreRig()
        var guest = established(rig)
        guest.send([.rst, .ack], sequence: guest.sequence &+ 1_000_000)
        #expect(rig.events { if case .closed = $0 { true } else { false } }.isEmpty)
        #expect(rig.core.stats.activeTCPFlows == 1)
    }

    @Test func anEstablishedFlowHonoursAResetExactlyFromTheNextSequenceNumberThroughTheWindow() throws {
        let rig = CoreRig()
        var guest = established(rig)
        let flow = try #require(rig.core.tcpByToken[guest.token])
        let next = flow.receiveNext
        let window = UInt32(max(flow.receiveSpace, 1))
        guest.send([.rst, .ack], sequence: next &- 1)
        guest.send([.rst, .ack], sequence: next &+ window &+ 1)
        #expect(rig.core.stats.activeTCPFlows == 1, "one behind and one past the window are both ignored")
        guest.send([.rst, .ack], sequence: next &+ window)
        #expect(rig.core.stats.activeTCPFlows == 0, "the last sequence number inside the window is honoured")
    }

    @Test func aFlowWaitingForTheHandshakeHonoursAnyResetFromTheNextSequenceNumberOn() throws {
        let rig = CoreRig()
        rig.learnGuest()
        var guest = GuestConnection(rig: rig, to: server)
        guest.sendSYN()
        guest.token = rig.host.streamOrder[0]
        rig.core.streamConnected(token: guest.token, error: nil)
        guest.collect()
        let flow = try #require(rig.core.tcpByToken[guest.token])
        #expect(flow.state == .synReceived)
        guest.send([.rst, .ack], sequence: flow.receiveNext &- 1)
        #expect(rig.core.stats.activeTCPFlows == 1, "behind the next sequence number is never a valid reset")
        guest.send([.rst, .ack], sequence: flow.receiveNext &+ 1_000_000)
        #expect(rig.core.stats.activeTCPFlows == 0, "ahead of it is honoured in this state, whatever the window")
    }

    @Test func aHostSideResetBecomesAResetToTheGuest() {
        let rig = CoreRig()
        var guest = established(rig)
        rig.host.streams[guest.token]?.failure = ECONNRESET
        rig.core.streamReadable(token: guest.token)
        guest.collect()
        #expect(guest.sawRST)
        #expect(rig.events { $0 == .closed(.hostError(ECONNRESET)) }.count == 1)
        #expect(rig.host.streams[guest.token]?.closed == .aborted)
    }

    @Test func aFlowThatCompletedLingersBrieflyThenDisappears() {
        let rig = CoreRig()
        var guest = established(rig)
        guest.serverCloses()
        guest.sendACK()
        guest.send([.fin, .ack])
        #expect(rig.core.stats.activeTCPFlows == 1, "a tombstone re-acknowledges a retransmitted FIN")
        let again = guest.send([.fin, .ack], sequence: guest.sequence &- 1)
        #expect(again.first?.flags == .ack)
        rig.advance(3)
        #expect(rig.core.stats.activeTCPFlows == 0)
    }

    @Test func aReusedSourcePortStartsAFreshConnection() {
        let rig = CoreRig()
        var first = established(rig)
        first.sendData(pattern(10))
        var second = GuestConnection(rig: rig, to: server, from: 50_000, isn: 900_000)
        second.sendSYN()
        #expect(rig.host.streamOrder.count == 2)
        #expect(rig.events { $0 == .closed(.guestReset) }.count == 1, "the old connection is torn down")
    }
}

struct UserNetTCPTimerTests {
    @Test func unacknowledgedDataIsRetransmittedWithBackoff() throws {
        let rig = CoreRig()
        var guest = established(rig)
        guest.serverSends(pattern(2_000))
        let original = guest.received.count
        #expect(original == 2_000)
        rig.advance(0.3)
        let first = guest.collect()
        #expect(first.count == 1 && first[0].sequence == guest.serverISN &+ 1)
        #expect(first[0].payload == Array(pattern(2_000).prefix(1_460)))
        #expect(guest.retransmissions == 1)
        rig.advance(0.3)
        #expect(guest.collect().isEmpty, "the second timeout is longer than the first")
        rig.advance(0.3)
        #expect(guest.collect().count == 1)
        #expect(rig.core.stats.tcpRetransmits >= 2)
    }

    @Test func aGuestThatNeverAcknowledgesIsResetEventually() {
        let rig = CoreRig()
        var guest = established(rig)
        guest.serverSends(pattern(100))
        for _ in 0..<40 { rig.advance(9) }
        guest.collect()
        #expect(guest.sawRST)
        #expect(rig.events { $0 == .closed(.retransmitTimeout) }.count == 1)
    }

    @Test func threeDuplicateAcknowledgementsTriggerFastRetransmit() {
        let rig = CoreRig()
        var guest = established(rig)
        guest.serverSends(pattern(5_000))
        let frames = guest.received.count
        #expect(frames == 5_000)
        var recovered: [DecodedFrame] = []
        for _ in 0..<3 { recovered += guest.send(.ack, acknowledgement: guest.serverISN &+ 1) }
        let retransmitted = recovered.filter { !$0.payload.isEmpty }
        #expect(retransmitted.count == 1 && retransmitted[0].sequence == guest.serverISN &+ 1)
    }

    @Test func aZeroWindowIsProbedAndReopens() {
        let rig = CoreRig()
        var guest = established(rig, guestWindow: 0)
        guest.serverSends(pattern(1_000))
        #expect(guest.received.isEmpty)
        rig.advance(0.3)
        let probes = guest.collect()
        #expect(probes.count == 1 && probes[0].payload.count == 1, "a one-byte probe, not the whole segment")
        guest.window = 65_535
        guest.sendACK()
        #expect(guest.received.count == 1_000)
    }

    @Test func anIdleFlowIsResetAfterTheTimeout() {
        let rig = CoreRig { $0.tcpIdleTimeout = 60 }
        var guest = established(rig)
        rig.advance(30)
        #expect(rig.core.stats.activeTCPFlows == 1)
        rig.advance(31)
        guest.collect()
        #expect(guest.sawRST)
        #expect(rig.events { $0 == .closed(.idleTimeout) }.count == 1)
    }

    @Test func activityKeepsAFlowAlive() {
        let rig = CoreRig { $0.tcpIdleTimeout = 60 }
        var guest = established(rig)
        for _ in 0..<5 {
            rig.advance(40)
            guest.sendData([1])
        }
        #expect(rig.core.stats.activeTCPFlows == 1)
    }
}
