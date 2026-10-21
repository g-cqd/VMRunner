import Foundation
import Testing

@testable import VMRunner

/// What a guest can make the stack spend, measured with counters rather than wall-clock time: sockets opened and closed,
/// passes over a table, bytes held.
struct UserNetDatagramChurnTests {
    /// A destination of the `index`-th flow: distinct addresses, so every datagram would be a new flow.
    private func destination(_ index: Int) -> (UInt32, UInt16) {
        (IPv4.make(93, UInt8(184 + index / 60_000 % 8), UInt8(index / 250 % 240), UInt8(1 + index % 250)), 9_999)
    }

    private func start(_ configure: (inout UserNetConfig) -> Void = { _ in }) -> CoreRig {
        let rig = CoreRig(configure: configure)
        rig.learnGuest()
        return rig
    }

    private func closed(_ rig: CoreRig) -> Int { rig.host.datagrams.values.filter(\.closed).count }

    @Test func aGuestOpeningFlowsAsFastAsItCanGetsTheBurstAndThenTheRate() {
        let rig = start()
        for index in 0..<10_000 { rig.send(Wire.guestUDP(to: destination(index), from: 40_000, [1])) }
        #expect(rig.host.datagrams.count == 256, "the burst, not a socket per datagram")
        #expect(rig.core.stats.udpFlowsOpened == 256)
        rig.advance(1)
        for index in 10_000..<20_000 { rig.send(Wire.guestUDP(to: destination(index), from: 40_000, [1])) }
        #expect(rig.host.datagrams.count == 256 + 128, "and the rate after it")
    }

    @Test func pingsShareTheSameBudgetAsUDP() {
        let rig = start { $0.datagramFlowBurst = 10 }
        for index in 0..<30 {
            let target = destination(index)
            if index.isMultiple(of: 2) {
                rig.send(Wire.guestUDP(to: target, [1]))
            } else {
                let echo = Wire.icmpEcho(identifier: index, sequence: 1)
                rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: target.0, proto: IPProtocol.icmp, echo)))
            }
        }
        #expect(rig.host.datagrams.count == 10)
    }

    @Test func aFullTableMakesRoomInBatchesNotPerPacket() {
        let rig = start {
            $0.maxUDPFlows = 64
            $0.datagramFlowBurst = 100_000
        }
        for index in 0..<1_000 {
            rig.send(Wire.guestUDP(to: destination(index), from: 40_000, [1]))
            #expect(rig.core.stats.activeUDPFlows <= 64)
        }
        let stats = rig.core.stats
        #expect(stats.udpFlowsOpened == 1_000)
        let batch = UInt64(64 / 8)
        #expect(stats.datagramFlowsEvicted == UInt64(1_000 - stats.activeUDPFlows), "every flow is open or was evicted")
        #expect(stats.datagramEvictionPasses <= (1_000 - 64) / batch + 1, "\(stats.datagramEvictionPasses) passes for 936 new flows")
        #expect(UInt64(closed(rig)) == stats.datagramFlowsEvicted, "and no socket is closed that was not evicted")
        #expect(stats.activeUDPFlows >= 64 - Int(batch))
    }

    @Test func theFlowsThatGoAreTheLeastRecentlyUsed() {
        let rig = start {
            $0.maxUDPFlows = 16
            $0.datagramFlowBurst = 100_000
        }
        for index in 0..<16 {
            rig.send(Wire.guestUDP(to: destination(index), from: 40_000, [1]))
            rig.advance(1)
        }
        // Touch the first two, so they are now the most recently used.
        rig.send(Wire.guestUDP(to: destination(0), from: 40_000, [2]))
        rig.send(Wire.guestUDP(to: destination(1), from: 40_000, [2]))
        rig.send(Wire.guestUDP(to: destination(100), from: 40_000, [1]))  // the table is full: the oldest two go
        let gone = Set(rig.host.datagrams.values.filter(\.closed).map(\.address))
        #expect(gone == [destination(2).0, destination(3).0])
        #expect(!gone.contains(destination(0).0) && !gone.contains(destination(1).0))
    }

    @Test func aRefusedOpeningIsOneEventNotOnePerDatagram() {
        let rig = start { $0.datagramFlowBurst = 1 }
        for index in 0..<2_000 { rig.send(Wire.guestUDP(to: destination(index), from: 40_000, [1])) }
        let refusals = rig.events { $0 == .denied(.flowLimit) }
        #expect(refusals.count <= DenialSuppression.capacity, "bounded by the suppression table, not by the guest")
    }
}

struct UserNetDNSOverTCPChurnTests {
    private func start(_ configure: (inout UserNetConfig) -> Void = { _ in }) -> CoreRig {
        let rig = CoreRig(configure: configure)
        rig.learnGuest()
        return rig
    }

    private func established(_ rig: CoreRig, port: UInt16 = 50_000) -> GuestConnection {
        var guest = GuestConnection(rig: rig, to: (Wire.gateway, 53), from: port)
        guest.sendSYN()
        guest.sendACK()
        return guest
    }

    private func framed(_ id: Int) -> [UInt8] {
        let query = Wire.dnsQuery(id: id, name: "q\(id % 1000).test")
        return Wire.be16(query.count) + query
    }

    /// The responses, in order, as `(id, record count)`.
    private func responses(_ stream: [UInt8]) -> [Int] {
        var ids: [Int] = []
        var offset = 0
        while offset + 2 <= stream.count {
            let length = Int(stream[offset]) << 8 | Int(stream[offset + 1])
            guard offset + 2 + length <= stream.count, length >= 12 else { break }
            ids.append(Int(stream[offset + 2]) << 8 | Int(stream[offset + 3]))
            offset += 2 + length
        }
        return ids
    }

    @Test func aThousandPipelinedQueriesAcrossTheRingWrapAreAllAnsweredInOrder() throws {
        let rig = start { $0.tcpReceiveBuffer = 16_384 }  // small ring: the stream wraps around it several times
        var guest = established(rig)
        var random = XorShift(state: 0xD45_7C9)
        var stream: [UInt8] = []
        for id in 0..<1_000 { stream += framed(id) }
        var sent = 0
        var answered = 0
        var rounds = 0
        while sent < stream.count, rounds < 100_000 {
            rounds += 1
            let flow = try #require(rig.core.tcpByToken.values.first)
            let chunk = min(1 + random.below(900), stream.count - sent, max(flow.receiveSpace, 0))
            if chunk > 0 {
                guest.sendData(Array(stream[sent..<(sent + chunk)]))
                sent += chunk
            } else {
                guest.sendACK()
            }
            while answered < rig.host.resolutions.count {  // the resolver answers at once, so nothing queues up
                let request = rig.host.resolutions[answered]
                let record = DNSRecord(name: request.name, type: 1, ttl: 60, data: [93, 184, 216, 34])
                rig.core.nameResolved(token: request.token, result: DNSLookupResult(responseCode: 0, records: [record]))
                answered += 1
            }
            guest.collect()
        }
        for _ in 0..<50 where responses(guest.received).count < 1_000 { guest.sendACK() }
        #expect(responses(guest.received) == Array(0..<1_000))
        #expect(rig.core.dns.pendingCount == 0)
    }

    @Test func theGuestIsToldItMaySendOnlyAsMuchAsTheInboxHolds() throws {
        let rig = start()
        var guest = established(rig)
        #expect(guest.advertised <= TCPFlow.dnsInboxLimit && guest.advertised > 0, "window \(guest.advertised)")
        let flow = try #require(rig.core.tcpByToken.values.first)
        // One oversized burst: a maximal query, then more than the inbox can take. Only the inbox's worth is accepted.
        guest.sendData(Wire.be16(TCPFlow.maximumDNSQuery) + [UInt8](repeating: 0, count: 20_000))
        #expect(flow.bytesToHost == UInt64(TCPFlow.dnsInboxLimit))
        #expect((flow.toHost?.count ?? 0) <= TCPFlow.dnsInboxLimit)
    }

    @Test func aLengthPrefixLongerThanAnyQueryResetsTheConnection() {
        let rig = start()
        var guest = established(rig)
        guest.sendData(Wire.be16(TCPFlow.maximumDNSQuery + 1) + pattern(100))
        #expect(guest.sawRST)
        #expect(rig.core.stats.activeTCPFlows == 0 && rig.core.localDNSFlows == 0)
        #expect(rig.host.resolutions.isEmpty)
    }

    @Test func aQueryAtTheLimitIsStillTaken() throws {
        let rig = start()
        var guest = established(rig)
        let query = Wire.dnsQuery(id: 7, name: "limit.test")
        let padded = query + [UInt8](repeating: 0, count: TCPFlow.maximumDNSQuery - query.count)
        guest.sendData(Wire.be16(padded.count) + padded)
        #expect(!guest.sawRST && rig.host.resolutions.map(\.name) == ["limit.test"])
    }

    @Test func aQueryThatNeverCompletesDoesNotKeepTheConnectionAfterTheGuestClosesIt() {
        let rig = start()
        var guest = established(rig)
        guest.sendData(Wire.be16(200) + pattern(50))
        guest.send([.fin, .ack])
        guest.sendACK()
        #expect(guest.sawFIN, "the half-open query is dropped, and the stack answers the close")
        #expect(rig.core.stats.activeTCPFlows == 0, "and the connection is gone, not waiting for bytes that cannot complete")
    }

    @Test func dnsConnectionsAreCappedWellBelowTheFlowLimit() {
        let rig = start()
        var accepted = 0
        var guests: [GuestConnection] = []
        for index in 0..<40 {
            var guest = GuestConnection(rig: rig, to: (Wire.gateway, 53), from: UInt16(50_000 + index))
            let answer = guest.sendSYN()
            if answer.contains(where: { $0.flags.contains(.syn) && $0.flags.contains(.ack) }) { accepted += 1 }
            guests.append(guest)
        }
        #expect(accepted == 32 && accepted == rig.core.localDNSFlows)
        let refused = guests.suffix(8).allSatisfy { $0.sawRST }
        #expect(refused, "the rest are refused")
        #expect(rig.events { $0 == .denied(.flowLimit) }.count == 1)
        #expect(rig.core.stats.activeTCPFlows == 32)

        var plain = GuestConnection(rig: rig, to: (ipv4("93.184.216.34"), 443), from: 51_000)
        plain.sendSYN()
        #expect(rig.host.streamOrder.count == 1, "ordinary connections are not counted against the DNS cap")
    }

    @Test func aClosedDNSConnectionFreesItsPlace() {
        let rig = start { $0.maxDNSTCPFlows = 2 }
        var first = established(rig, port: 50_000)
        _ = established(rig, port: 50_001)
        var third = GuestConnection(rig: rig, to: (Wire.gateway, 53), from: 50_002)
        third.sendSYN()
        #expect(third.sawRST)
        first.send([.fin, .ack])
        first.sendACK()
        rig.advance(10)  // past the lingering state of the finished connection
        var fourth = GuestConnection(rig: rig, to: (Wire.gateway, 53), from: 50_003)
        let answer = fourth.sendSYN()
        #expect(answer.contains { $0.flags.contains(.syn) && $0.flags.contains(.ack) })
        #expect(rig.core.localDNSFlows == 2)
    }
}

struct ByteRingCopyTests {
    @Test func bytesAreCopiedFromAnywhereInTheRingIncludingAcrossTheWrap() {
        let ring = ByteRing(capacity: 8)
        #expect(ByteView.withBytes(of: [1, 2, 3, 4, 5, 6]) { ring.append($0) })
        ring.discard(4)
        #expect(ByteView.withBytes(of: [7, 8, 9, 10, 11, 12]) { ring.append($0) })  // wraps: 5 6 | 7 8 9 10 11 12
        #expect(ring.bytes(from: 0, count: 8) == [5, 6, 7, 8, 9, 10, 11, 12])
        #expect(ring.bytes(from: 1, count: 2) == [6, 7])
        #expect(ring.bytes(from: 7, count: 1) == [12])
        #expect(ring.bytes(from: 3, count: 0)?.isEmpty == true)
        #expect(ring.bytes(from: 0, count: 9) == nil && ring.bytes(from: 8, count: 1) == nil && ring.bytes(from: -1, count: 1) == nil)
    }
}
