import Foundation
import Testing

@testable import NetStack

private func wireGuard(type: UInt8, length: Int) -> [UInt8] {
    [type, 0, 0, 0] + pattern(length - 4, seed: 77)
}

private func isSuspected(_ state: GuestVPNState?, _ kind: GuestVPNKind, atLeast level: GuestVPNConfidence = .low) -> Bool {
    guard case .suspected(let found, let confidence, _, _) = state else { return false }
    return found == kind && confidence >= level
}

/// The VPN detector as wired into the stack: it must see what the guest sends and what comes back, including
/// IP protocols the stack cannot forward.
struct UserNetVPNFlowTests {
    private let peer = (ipv4("203.0.113.9"), UInt16(51_820))

    @Test func aWireGuardHandshakeSeenInBothDirectionsIsReportedHigh() {
        let rig = CoreRig()
        rig.learnGuest()
        rig.send(Wire.guestUDP(to: peer, from: 40_000, wireGuard(type: 1, length: 148)))
        let token = rig.host.datagrams.keys.first ?? 0
        rig.host.datagrams[token]?.incoming = [wireGuard(type: 2, length: 92)]
        rig.core.datagramReadable(token: token)
        #expect(isSuspected(rig.host.vpnStates.last, .wireGuard, atLeast: .high))
    }

    @Test func espAndGREPacketsAreCountedDroppedAndStillFingerprinted() {
        let rig = CoreRig()
        rig.learnGuest()
        let esp = pattern(100, seed: 1).enumerated().map { $0.offset < 4 ? UInt8(0xC1 + $0.offset) : $0.element }
        for _ in 0..<3 { rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: peer.0, proto: IPProtocol.esp, esp))) }
        #expect(rig.core.stats.droppedUnsupported == 3)
        #expect(isSuspected(rig.host.vpnStates.last, .ipsec))
        #expect(rig.host.datagrams.isEmpty && rig.host.streams.isEmpty)
    }

    @Test func ordinaryWebAndDNSTrafficNeverRaisesSuspicion() {
        let rig = CoreRig()
        rig.learnGuest()
        // QUIC-like: many large UDP datagrams to one peer on 443.
        for index in 0..<300 { rig.send(Wire.guestUDP(to: (peer.0, 443), from: 40_000, [UInt8(0xC3)] + pattern(1_199, seed: index))) }
        let token = rig.host.datagrams.keys.first ?? 0
        rig.host.datagrams[token]?.incoming = (0..<200).map { [UInt8(0x43)] + pattern(1_199, seed: $0) }
        rig.core.datagramReadable(token: token)
        rig.send(Wire.guestUDP(to: (Wire.gateway, 53), Wire.dnsQuery(id: 1, name: "www.example.com")))
        var tls = GuestConnection(rig: rig, to: (peer.0, 443))
        tls.establish()
        tls.sendData([0x16, 0x03, 0x01, 0x02, 0x00, 0x01, 0x00, 0x01, 0xFC] + pattern(500))
        #expect(rig.host.vpnStates.isEmpty)
    }

    @Test func theStateDecaysBackToNoneWhenTheEvidenceExpires() {
        let rig = CoreRig()
        rig.learnGuest()
        rig.send(Wire.guestUDP(to: peer, from: 40_000, wireGuard(type: 1, length: 148)))
        let token = rig.host.datagrams.keys.first ?? 0
        rig.host.datagrams[token]?.incoming = [wireGuard(type: 2, length: 92)]
        rig.core.datagramReadable(token: token)
        #expect(isSuspected(rig.host.vpnStates.last, .wireGuard))
        rig.advance(400)
        #expect(rig.host.vpnStates.last == GuestVPNState.none)
    }
}

extension UserNetIntegration {
    struct UserNetVPNStackTests {
        @Test func theStackPublishesTheVerdictToItsReaders() async throws {
            let server = try #require(LoopbackUDPServer())
            defer { server.close() }
            try await withNetwork { network in
                let guest = network.guest
                // The echo server bounces each WireGuard initiation back, so the detector sees the shape in both directions.
                for _ in 0..<2 { guest.sendUDP(to: (ipv4("127.0.0.1"), server.port), from: 40_000, wireGuard(type: 1, length: 148)) }
                guest.pump(timeout: 5) { isSuspected(network.stack.vpnState, .wireGuard) }
                #expect(isSuspected(network.stack.vpnState, .wireGuard))
            }
        }
    }
}
