import Foundation
import Testing

@testable import VMRunner

struct UserNetLinkTests {
    @Test func gatewayAnswersArpForItsAddressOnly() throws {
        let rig = CoreRig()
        rig.send(Wire.arpRequest(senderMAC: Wire.guestMAC, senderIP: Wire.guest, targetIP: Wire.gateway))
        let reply = try #require(rig.host.takeFrames().first)
        #expect(reply.etherType == EtherType.arp && reply.arpOperation == 2)
        #expect(reply.arpSenderMAC == Wire.gatewayMAC && reply.arpSenderIP == Wire.gateway)
        #expect(reply.destination == Wire.guestMAC)
        rig.send(Wire.arpRequest(senderMAC: Wire.guestMAC, senderIP: Wire.guest, targetIP: ipv4("198.18.0.77")))
        rig.send(Wire.arpRequest(senderMAC: Wire.guestMAC, senderIP: Wire.guest, targetIP: ipv4("8.8.8.8")))
        #expect(rig.host.frames.isEmpty)
    }

    @Test func framesNotAddressedToTheGatewayAreIgnored() {
        let rig = CoreRig()
        let stranger = MACAddress(rawValue: 0x0200_DEAD_BEEF)
        let echo = Wire.ipv4(from: Wire.guest, to: Wire.gateway, proto: IPProtocol.icmp, Wire.icmpEcho(identifier: 1, sequence: 1))
        rig.send(Wire.ethernet(to: stranger, from: Wire.guestMAC, type: EtherType.ipv4, echo))
        #expect(rig.host.frames.isEmpty)
    }

    @Test func ipv6FramesAreDroppedAndCounted() {
        let rig = CoreRig()
        rig.send(Wire.ethernet(to: Wire.gatewayMAC, from: Wire.guestMAC, type: EtherType.ipv6, pattern(60)))
        #expect(rig.core.stats.droppedIPv6Frames == 1)
        #expect(rig.host.frames.isEmpty)
    }

    @Test func malformedFragmentedAndSpoofedPacketsAreDroppedAndCounted() {
        let rig = CoreRig()
        let udp = Wire.udp(from: (Wire.guest, 4_000), to: (ipv4("9.9.9.9"), 9_999), [1, 2, 3])
        rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: ipv4("9.9.9.9"), proto: IPProtocol.udp, udp, headerChecksum: false)))
        rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: ipv4("9.9.9.9"), proto: IPProtocol.udp, udp, fragmentField: 0x2000)))
        rig.send(Wire.guestFrame(Wire.ipv4(from: ipv4("198.18.0.99"), to: ipv4("9.9.9.9"), proto: IPProtocol.udp, udp)))
        rig.send([1, 2, 3])
        let stats = rig.core.stats
        #expect(stats.malformedFrames == 2)
        #expect(stats.droppedFragments == 1)
        #expect(stats.droppedUnsupported == 1)
        #expect(rig.host.datagrams.isEmpty)
    }

    @Test func trafficForOtherAddressesOnTheGuestSubnetIsNeverForwarded() {
        let rig = CoreRig()
        rig.learnGuest()
        rig.send(Wire.guestUDP(to: (ipv4("198.18.0.77"), 9_999), [1]))
        let syn = Wire.tcp(from: (Wire.guest, 50_000), to: (ipv4("198.18.0.77"), 80), sequence: 1, flags: .syn)
        rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: ipv4("198.18.0.77"), proto: IPProtocol.tcp, syn)))
        let echo = Wire.icmpEcho(identifier: 1, sequence: 1)
        rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: ipv4("198.18.0.77"), proto: IPProtocol.icmp, echo)))
        #expect(rig.host.datagrams.isEmpty && rig.host.streams.isEmpty && rig.host.frames.isEmpty)
        #expect(rig.core.stats.droppedUnsupported == 3)
    }

    @Test func gatewayAnswersPing() throws {
        let rig = CoreRig()
        let echo = Wire.icmpEcho(identifier: 0x42, sequence: 3, data: [1, 2, 3, 4, 5])
        rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: Wire.gateway, proto: IPProtocol.icmp, echo)))
        let reply = try #require(rig.host.takeFrames().first)
        #expect(reply.icmpType == 0 && reply.transportChecksumValid && reply.ipChecksumValid)
        #expect(reply.ipSource == Wire.gateway && reply.ipDestination == Wire.guest)
        #expect(Array(reply.payload[4..<8]) == [0, 0x42, 0, 3] || Array(reply.payload[4..<8]) == [0x00, 0x42, 0x00, 0x03])
        #expect(Array(reply.payload[8...]) == [1, 2, 3, 4, 5])
    }
}

struct UserNetDHCPTests {
    /// Sends a DHCP payload (from `0.0.0.0` to the broadcast address, as a client without a lease does) and returns the
    /// first frame the stack sends back.
    private func exchange(
        _ rig: CoreRig, _ payload: [UInt8], from source: UInt32 = 0, to destination: UInt32 = IPv4.broadcast
    ) -> DecodedFrame? {
        let udp = Wire.udp(from: (source, 68), to: (destination, 67), payload)
        let ip = Wire.ipv4(from: source, to: destination, proto: IPProtocol.udp, udp)
        rig.send(
            Wire.ethernet(to: destination == IPv4.broadcast ? .broadcast : Wire.gatewayMAC, from: Wire.guestMAC, type: EtherType.ipv4, ip))
        return rig.host.takeFrames().first
    }

    private func option(_ code: UInt8, in reply: DecodedFrame) -> [UInt8]? {
        var index = 240
        while index + 1 < reply.payload.count, reply.payload[index] != 255 {
            let length = Int(reply.payload[index + 1])
            if reply.payload[index] == code { return Array(reply.payload[(index + 2)..<(index + 2 + length)]) }
            index += 2 + length
        }
        return nil
    }

    @Test func discoverGetsAnOfferWithTheLeaseParameters() throws {
        let rig = CoreRig()
        let offer = try #require(exchange(rig, Wire.dhcp(type: 1)))
        #expect(offer.sourcePort == 67 && offer.destinationPort == 68)
        #expect(offer.ipSource == Wire.gateway && offer.ipDestination == IPv4.broadcast)
        #expect(offer.destination == .broadcast)
        #expect(offer.ipChecksumValid && offer.transportChecksumValid)
        #expect(Array(offer.payload[4..<8]) == Wire.be32(0xCAFE_F00D))
        #expect(Array(offer.payload[16..<20]) == Wire.be32(Wire.guest))
        #expect(option(53, in: offer) == [2])
        #expect(option(54, in: offer) == Wire.be32(Wire.gateway))
        #expect(option(1, in: offer) == [255, 255, 255, 0])
        #expect(option(3, in: offer) == Wire.be32(Wire.gateway))
        #expect(option(6, in: offer) == Wire.be32(Wire.gateway))
        #expect(option(26, in: offer) == Wire.be16(1_500))
        #expect(option(51, in: offer) == Wire.be32(86_400))
    }

    @Test func requestForTheOfferedAddressIsAcknowledged() throws {
        let rig = CoreRig()
        _ = exchange(rig, Wire.dhcp(type: 1))
        let ack = try #require(exchange(rig, Wire.dhcp(type: 3, requested: Wire.guest, server: Wire.gateway)))
        #expect(option(53, in: ack) == [5])
        #expect(Array(ack.payload[16..<20]) == Wire.be32(Wire.guest))
        #expect(rig.core.stats.dhcpAcks == 1)
    }

    @Test func requestForAnotherAddressIsRefused() throws {
        let rig = CoreRig()
        let nak = try #require(exchange(rig, Wire.dhcp(type: 3, requested: ipv4("198.18.0.50"), server: Wire.gateway)))
        #expect(option(53, in: nak) == [6])
    }

    @Test func requestToAnotherServerIsIgnored() {
        let rig = CoreRig()
        #expect(exchange(rig, Wire.dhcp(type: 3, requested: Wire.guest, server: ipv4("192.168.1.1"))) == nil)
    }

    @Test func renewalIsAnsweredByUnicast() throws {
        let rig = CoreRig()
        let ack = try #require(exchange(rig, Wire.dhcp(type: 3, clientAddress: Wire.guest, broadcast: false)))
        #expect(ack.ipDestination == Wire.guest && ack.destination == Wire.guestMAC)
    }

    @Test func aRenewalFromTheLeasedAddressToTheGatewayIsServed() throws {
        let rig = CoreRig()
        let ack = try #require(
            exchange(rig, Wire.dhcp(type: 3, clientAddress: Wire.guest, broadcast: false), from: Wire.guest, to: Wire.gateway))
        #expect(ack.ipDestination == Wire.guest && ack.destination == Wire.guestMAC)
    }

    @Test func aDHCPMessageToAnotherServerIsNotAnsweredLocallyButForwardedLikeAnyDatagram() {
        let rig = CoreRig()
        rig.learnGuest()
        let remote = ipv4("93.184.216.34")
        #expect(exchange(rig, Wire.dhcp(type: 1), from: Wire.guest, to: remote) == nil, "no offer from a server it was not sent to")
        #expect(rig.host.datagrams.values.map(\.address) == [remote], "it is an ordinary UDP flow, judged by the policy")
    }

    @Test func aDHCPMessageFromNoAddressToAnotherServerIsDropped() {
        let rig = CoreRig()
        rig.learnGuest()
        #expect(exchange(rig, Wire.dhcp(type: 1), from: 0, to: ipv4("93.184.216.34")) == nil)
        #expect(rig.host.datagrams.isEmpty, "only the leased address may use the guest's identity to reach the host network")
        #expect(rig.core.stats.droppedUnsupported == 1)
    }

    @Test func aNeighbourOnTheSubnetIsNotADHCPServer() {
        let rig = CoreRig()
        rig.learnGuest()
        #expect(exchange(rig, Wire.dhcp(type: 1), from: Wire.guest, to: ipv4("198.18.0.77")) == nil)
        #expect(exchange(rig, Wire.dhcp(type: 1), from: 0, to: ipv4("198.18.0.77")) == nil)
        #expect(rig.host.datagrams.isEmpty)
    }

    @Test func aClaimedClientAddressOtherThanTheLeaseIsAnsweredByBroadcast() throws {
        let rig = CoreRig()
        let message = Wire.dhcp(type: 3, requested: Wire.guest, server: Wire.gateway, clientAddress: ipv4("8.8.8.8"), broadcast: false)
        let ack = try #require(exchange(rig, message))
        #expect(ack.ipDestination == IPv4.broadcast && ack.destination == .broadcast, "not addressed to 8.8.8.8")
    }

    @Test func aSecondClientGetsNothingWhileTheLeaseHolds() throws {
        let rig = CoreRig()
        _ = exchange(rig, Wire.dhcp(type: 3, requested: Wire.guest, server: Wire.gateway))
        let other = MACAddress(rawValue: 0x0200_0000_FFFF)
        #expect(exchange(rig, Wire.dhcp(type: 1, client: other)) == nil)
        rig.advance(86_401)
        #expect(exchange(rig, Wire.dhcp(type: 1, client: other)) != nil)
    }

    @Test func releaseFreesTheLease() throws {
        let rig = CoreRig()
        _ = exchange(rig, Wire.dhcp(type: 3, requested: Wire.guest, server: Wire.gateway))
        _ = exchange(rig, Wire.dhcp(type: 7))
        #expect(exchange(rig, Wire.dhcp(type: 1, client: MACAddress(rawValue: 0x0200_0000_FFFF))) != nil)
    }

    @Test func informGetsAnAckWithoutALease() throws {
        let rig = CoreRig()
        let ack = try #require(exchange(rig, Wire.dhcp(type: 8, clientAddress: Wire.guest)))
        #expect(option(53, in: ack) == [5])
        #expect(option(51, in: ack) == nil)
        #expect(Array(ack.payload[16..<20]) == [0, 0, 0, 0])
    }

    @Test func garbageIsIgnored() {
        let rig = CoreRig()
        var bad = Wire.dhcp(type: 1)
        bad[236] = 0
        #expect(exchange(rig, bad) == nil)
        #expect(exchange(rig, Array(Wire.dhcp(type: 1).prefix(100))) == nil)
    }
}
