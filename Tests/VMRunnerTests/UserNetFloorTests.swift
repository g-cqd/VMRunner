import Foundation
import NetPolicy
import Testing

@testable import VMRunner

/// With `blockPrivateRanges` off and no rule at all, the floor (ADR-0029) still holds on every transport, and the
/// private networks it never covered are reachable.
struct UserNetFloorTests {
    private static let floor: [(address: String, kind: ReservedRangeKind)] = [
        ("127.0.0.1", .loopback), ("127.9.9.9", .loopback), ("0.0.0.0", .unspecified), ("169.254.169.254", .cloudMetadata),
        ("169.254.7.7", .linkLocal), ("192.168.64.1", .hostGateway), ("198.19.0.9", .benchmarking),
    ]

    private static let privateNetworks = ["10.1.2.3", "172.16.5.5", "192.168.1.9", "100.64.0.1"]

    @Test func theAppNeverExemptsAnything() {
        #expect(UserNetConfig().exemptedFloorKinds.isEmpty, "only the integration tests lift a floor range")
    }

    private func start() -> CoreRig {
        let rig = CoreRig(policy: CoreRig.openPolicy)
        rig.learnGuest()
        return rig
    }

    private func denial(_ rig: CoreRig, _ transport: FlowTransport, _ kind: ReservedRangeKind, _ address: String) -> Bool {
        rig.host.events.contains { event in
            guard event.transport == transport, case .denied(.policy(.reservedRange(let found, _))) = event.phase else { return false }
            return found == kind && event.destinationAddress == .v4(ipv4(address))
        }
    }

    private func connects(_ rig: CoreRig, to address: String, port: UInt16) -> (opened: Bool, reset: Bool) {
        var guest = GuestConnection(rig: rig, to: (ipv4(address), 443), from: port)
        let before = rig.host.streamOrder.count
        let answer = guest.sendSYN()
        return (rig.host.streamOrder.count > before, answer.contains { $0.flags.contains(.rst) })
    }

    @Test func tcpToTheFloorIsRefusedAndNeverConnected() {
        let rig = start()
        for (index, entry) in Self.floor.enumerated() {
            let result = connects(rig, to: entry.address, port: UInt16(50_000 + index))
            #expect(!result.opened && result.reset, "\(entry.address)")
            #expect(denial(rig, .tcp, entry.kind, entry.address), "\(entry.address)")
        }
        #expect(rig.host.streamOrder.isEmpty)
    }

    @Test func udpToTheFloorIsDeniedAndNeverOpened() {
        let rig = start()
        for entry in Self.floor {
            rig.send(Wire.guestUDP(to: (ipv4(entry.address), 9_999), [1]))
            #expect(denial(rig, .udp, entry.kind, entry.address), "\(entry.address)")
        }
        #expect(rig.host.datagrams.isEmpty)
    }

    @Test func pingToTheFloorIsDeniedAndNeverOpened() {
        let rig = start()
        for entry in Self.floor {
            let echo = Wire.icmpEcho(identifier: 0x42, sequence: 1)
            rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: ipv4(entry.address), proto: IPProtocol.icmp, echo)))
            #expect(denial(rig, .icmp, entry.kind, entry.address), "\(entry.address)")
        }
        #expect(rig.host.datagrams.isEmpty)
    }

    @Test func privateNetworksAreReachableOnceTheirSwitchIsOff() {
        let rig = start()
        for (index, address) in Self.privateNetworks.enumerated() {
            #expect(connects(rig, to: address, port: UInt16(50_100 + index)).opened, "TCP to \(address)")
            rig.send(Wire.guestUDP(to: (ipv4(address), 9_999), [1]))
            let echo = Wire.icmpEcho(identifier: index + 1, sequence: 1)
            rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: ipv4(address), proto: IPProtocol.icmp, echo)))
        }
        let kinds = rig.host.datagrams.values.map(\.kind)
        #expect(kinds.filter { $0 == .udp }.count == Self.privateNetworks.count)
        #expect(kinds.filter { $0 == .icmpEcho }.count == Self.privateNetworks.count)
    }

    @Test func theDefaultPolicyStillBlocksPrivateNetworksToo() {
        let rig = CoreRig(policy: NetworkPolicy())
        rig.learnGuest()
        for (index, address) in Self.privateNetworks.enumerated() {
            #expect(!connects(rig, to: address, port: UInt16(50_200 + index)).opened, "\(address)")
        }
    }

    @Test func theStacksOwnGatewayServesNothingButDNS() {
        let rig = start()
        #expect(connects(rig, to: "198.18.0.1", port: 50_300) == (opened: false, reset: true))
        rig.send(Wire.guestUDP(to: (Wire.gateway, 123), [1, 2, 3]))
        #expect(rig.events { $0 == .denied(.gatewayService(port: 123)) }.count == 1)
        #expect(rig.host.streamOrder.isEmpty && rig.host.datagrams.isEmpty)
    }

    @Test func ipv6IsNotRoutedAtAll() {
        let rig = start()
        let before = rig.core.stats.droppedIPv6Frames
        rig.send(Wire.ethernet(to: Wire.gatewayMAC, from: Wire.guestMAC, type: EtherType.ipv6, pattern(60)))
        #expect(rig.core.stats.droppedIPv6Frames == before + 1)
        #expect(rig.host.streamOrder.isEmpty && rig.host.datagrams.isEmpty)
    }

    @Test func answersNeverHandTheGuestAFloorAddress() throws {
        let rig = start()
        rig.send(Wire.guestUDP(to: (Wire.gateway, 53), from: 41_000, Wire.dnsQuery(id: 9, name: "host.test")))
        let addresses = ["127.0.0.1", "0.0.0.0", "169.254.169.254", "192.168.64.1", "198.19.0.9", "10.1.2.3"]
        let records = addresses.map { DNSRecord(name: "host.test", type: DNSCode.typeA, ttl: 60, data: Wire.be32(ipv4($0))) }
        rig.core.nameResolved(token: rig.host.resolutions[0].token, result: DNSLookupResult(responseCode: 0, records: records))
        let response = try #require(rig.host.takeFrames().first { $0.sourcePort == 53 })
        #expect(response.payload[7] == 1, "only the private network the switch allows is left")
        #expect(Array(response.payload.suffix(4)) == [10, 1, 2, 3])
    }
}
