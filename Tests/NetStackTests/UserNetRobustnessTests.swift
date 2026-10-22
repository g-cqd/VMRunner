import Foundation
import Testing

@testable import NetStack

/// A tiny deterministic generator so failures reproduce.
struct XorShift {
    var state: UInt64

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

struct UserNetRobustnessTests {
    private static let server = (ipv4("93.184.216.34"), UInt16(443))

    /// Valid frames of every kind the core understands, to mutate.
    private func seeds() -> [[UInt8]] {
        let remote = Self.server
        return [
            Wire.arpRequest(senderMAC: Wire.guestMAC, senderIP: Wire.guest, targetIP: Wire.gateway),
            Wire.guestUDP(to: remote, [1, 2, 3, 4]),
            Wire.guestUDP(to: (Wire.gateway, 53), Wire.dnsQuery(id: 1, name: "fuzz.test")),
            Wire.guestUDP(to: (Wire.gateway, 53), Wire.dnsQuery(id: 2, name: "fuzz.test", type: 16)),
            Wire.ethernet(
                to: .broadcast, from: Wire.guestMAC, type: EtherType.ipv4,
                Wire.ipv4(
                    from: 0, to: IPv4.broadcast, proto: IPProtocol.udp,
                    Wire.udp(from: (0, 68), to: (IPv4.broadcast, 67), Wire.dhcp(type: 1)))),
            Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: remote.0, proto: IPProtocol.icmp, Wire.icmpEcho(identifier: 3, sequence: 1))),
            Wire.guestFrame(
                Wire.ipv4(from: Wire.guest, to: Wire.gateway, proto: IPProtocol.icmp, Wire.icmpEcho(identifier: 3, sequence: 1))),
            Wire.guestFrame(
                Wire.ipv4(
                    from: Wire.guest, to: remote.0, proto: IPProtocol.tcp,
                    Wire.tcp(from: (Wire.guest, 50_000), to: remote, sequence: 10, flags: .syn, mss: 1_460, windowScale: 5))),
            Wire.guestFrame(
                Wire.ipv4(
                    from: Wire.guest, to: remote.0, proto: IPProtocol.tcp,
                    Wire.tcp(
                        from: (Wire.guest, 50_000), to: remote, sequence: 11, acknowledgement: 1_000_001, flags: .pushAck,
                        payload: pattern(200)))),
            Wire.guestFrame(
                Wire.ipv4(
                    from: Wire.guest, to: remote.0, proto: IPProtocol.tcp,
                    Wire.tcp(from: (Wire.guest, 50_000), to: remote, sequence: 211, acknowledgement: 1_000_001, flags: .finAck))),
            Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: remote.0, proto: 50, pattern(40))),
        ]
    }

    @Test func mutatedAndRandomFramesNeverCrashTheCoreOrLeakFlowsPastTheirLimits() {
        let rig = CoreRig {
            $0.maxTCPFlows = 16
            $0.maxUDPFlows = 16
        }
        var random = XorShift(state: 0x9E37_79B9_7F4A_7C15)
        let seeds = seeds()
        for round in 0..<20_000 {
            var frame = seeds[random.below(seeds.count)]
            switch random.below(5) {
            case 0:  // flip bits
                for _ in 0..<random.below(6) + 1 where !frame.isEmpty {
                    frame[random.below(frame.count)] ^= UInt8(truncatingIfNeeded: random.next())
                }
            case 1:  // truncate
                frame = Array(frame.prefix(random.below(frame.count + 1)))
            case 2:  // random garbage after a valid Ethernet header to the gateway
                frame =
                    Array(Wire.ethernet(to: Wire.gatewayMAC, from: Wire.guestMAC, type: EtherType.ipv4, []))
                    + (0..<random.below(120)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            case 3:  // valid IP header, garbage transport
                let proto = [IPProtocol.tcp, IPProtocol.udp, IPProtocol.icmp, 47, 50][random.below(5)]
                let body = (0..<random.below(80)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
                frame = Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: Self.server.0, proto: proto, body))
            default: break
            }
            ByteView.withBytes(of: frame) { rig.core.receiveFrame($0) }
            if round.isMultiple(of: 50) {
                rig.core.endOfBatch()
                rig.advance(0.2)
                rig.host.frames.removeAll()
                // Let any pending host connection "succeed" so established-state code is fuzzed too.
                for token in rig.host.streamOrder.suffix(4) { rig.core.streamConnected(token: token, error: nil) }
            }
        }
        let stats = rig.core.stats
        #expect(stats.activeTCPFlows <= 16)
        #expect(stats.activeUDPFlows <= 16)
        rig.advance(10_000)
        #expect(rig.core.stats.activeTCPFlows == 0, "idle and half-open flows all expire")
        #expect(rig.core.stats.activeUDPFlows == 0)
    }

    @Test func randomHostEventsForUnknownTokensAreHarmless() {
        let rig = CoreRig()
        for token in UInt64(0)..<64 {
            rig.core.streamConnected(token: token, error: nil)
            rig.core.streamReadable(token: token)
            rig.core.streamWritable(token: token)
            rig.core.datagramReadable(token: token)
            rig.core.nameResolved(token: token, result: DNSLookupResult(responseCode: 0))
        }
        #expect(rig.host.frames.isEmpty)
    }
}
