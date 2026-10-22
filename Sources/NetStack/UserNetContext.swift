import Foundation
import NetPolicy

/// The shared environment of the core's state machines: configuration, the host, counters, buffers, and the only
/// code that builds frames for the guest.
///
/// Every `send*` method assembles the frame in a buffer allocated once at initialization and passes it straight to
/// ``UserNetHost/sendToGuest(_:)``, so sending allocates nothing. Not thread-safe: the single thread that drives
/// the core owns it.
final class UserNetContext<Host: UserNetHost> {
    let config: UserNetConfig
    let host: Host
    var stats = UserNetStats()
    /// The stack's monotonic clock, in seconds; the core refreshes it at every entry point.
    var now: TimeInterval = 0
    /// Learned from the first frame the guest sends; until then frames for it are addressed to broadcast.
    var guestMAC: MACAddress?
    /// Passive VPN fingerprinting of the guest's traffic; fed by every module that sees packets.
    var vpn: GuestVPNDetector
    let sendRings: RingPool
    let receiveRings: RingPool

    /// Receives host datagrams and assembles small local replies (ICMP echo, DHCP); one datagram at a time.
    let datagramScratch = RawBuffer(capacity: 65_536)

    private let txBuffer: RawBuffer
    private var fragmentBuffer: RawBuffer?
    private var nextIdentification: UInt16 = 0x4000
    private var nextToken: UInt64 = 1

    init(config: UserNetConfig, host: Host) {
        self.config = config
        self.host = host
        vpn = GuestVPNDetector(configuration: config.vpnDetection)
        txBuffer = RawBuffer(capacity: config.mtu + EthernetHeader.length + 64)
        sendRings = RingPool(ringCapacity: config.tcpSendBuffer)
        receiveRings = RingPool(ringCapacity: config.tcpReceiveBuffer)
    }

    /// A fresh identifier for a flow or a pending query; also the key host sockets are registered under.
    func makeToken() -> UInt64 {
        defer { nextToken += 1 }
        return nextToken
    }

    var guestDestination: MACAddress { guestMAC ?? .broadcast }

    /// TCP segment from `remote` to the guest. `payload` and `tail` are consecutive bytes (a ring may wrap).
    func sendTCP(
        remote: (address: UInt32, port: UInt16), guestPort: UInt16, sequence: UInt32, acknowledgement: UInt32, flags: TCPFlags,
        window: UInt16, options: TCPSendOptions = .none, payload: ByteView = .empty, tail: ByteView = .empty
    ) {
        var writer = FrameWriter(txBuffer.mutableView)
        let headerLength = TCPHeader.minimumLength + options.encodedLength
        let segmentLength = headerLength + payload.count + tail.count
        EthernetHeader.write(destination: guestDestination, source: config.gatewayMAC, etherType: EtherType.ipv4, into: &writer)
        IPv4Header.write(
            source: remote.address, destination: config.guestAddress, proto: IPProtocol.tcp, payloadLength: segmentLength,
            identification: takeIdentification(), into: &writer)
        let start = writer.count
        writer.be16(remote.port)
        writer.be16(guestPort)
        writer.be32(sequence)
        writer.be32(acknowledgement)
        writer.u8(UInt8(headerLength / 4) << 4)
        writer.u8(flags.rawValue)
        writer.be16(window)
        writer.be16(0)
        writer.be16(0)
        options.write(into: &writer)
        writer.bytes(payload)
        writer.bytes(tail)
        let pseudo = InternetChecksum.pseudoHeaderSum(
            source: remote.address, destination: config.guestAddress, proto: IPProtocol.tcp, length: segmentLength)
        writer.patchBE16(InternetChecksum.finish(pseudo &+ writer.sum(from: start)), at: start + 16)
        transmit(writer)
    }

    /// UDP datagram to the guest (or, for DHCP, to its MAC and the broadcast address).
    func sendUDP(
        from source: (address: UInt32, port: UInt16), to destination: (address: UInt32, port: UInt16), mac: MACAddress,
        payload: ByteView
    ) {
        let datagramLength = UDPHeader.length + payload.count
        guard IPv4Header.minimumLength + datagramLength <= config.mtu else {
            sendFragmentedUDP(from: source, to: destination, mac: mac, payload: payload)
            return
        }
        var writer = FrameWriter(txBuffer.mutableView)
        EthernetHeader.write(destination: mac, source: config.gatewayMAC, etherType: EtherType.ipv4, into: &writer)
        IPv4Header.write(
            source: source.address, destination: destination.address, proto: IPProtocol.udp, payloadLength: datagramLength,
            identification: takeIdentification(), into: &writer)
        UDPHeader.append(from: source, to: destination, payload: payload, into: &writer)
        transmit(writer)
    }

    /// An ICMP message (already complete, checksum included) from `source` to the guest. Fragmented when needed.
    func sendICMP(from source: UInt32, message: ByteView) {
        sendFragmentable(proto: IPProtocol.icmp, source: source, destination: config.guestAddress, mac: guestDestination, body: message)
    }

    /// ARP packet to `mac`.
    func sendARP(_ packet: ARPPacket, to mac: MACAddress) {
        var writer = FrameWriter(txBuffer.mutableView)
        EthernetHeader.write(destination: mac, source: config.gatewayMAC, etherType: EtherType.arp, into: &writer)
        packet.write(into: &writer)
        transmit(writer)
    }

    /// Shows the VPN detector one packet and publishes the verdict if it changed. Allocation-free unless it does.
    func observe(
        _ direction: GuestPacketObservation.Direction, peer: UInt32, transport: GuestPacketObservation.Transport,
        payload: ByteView, wireLength: Int
    ) {
        let packet = GuestPacketObservation(
            direction: direction, peer: .v4(peer), transport: transport, payload: payload, wireLength: wireLength)
        if let state = vpn.observe(packet, at: now) { host.publish(vpnState: state) }
    }

    // MARK: Private

    private func sendFragmentedUDP(
        from source: (address: UInt32, port: UInt16), to destination: (address: UInt32, port: UInt16), mac: MACAddress,
        payload: ByteView
    ) {
        let scratch = fragmentScratch()
        var writer = FrameWriter(scratch.mutableView)
        UDPHeader.append(from: source, to: destination, payload: payload, into: &writer)
        guard !writer.overflowed else { return }
        sendFragmentable(proto: IPProtocol.udp, source: source.address, destination: destination.address, mac: mac, body: writer.written)
    }

    /// The parts of an IPv4 header that stay the same across the fragments of one packet.
    private struct Route {
        let proto: UInt8
        let source: UInt32
        let destination: UInt32
        let mac: MACAddress
        let identification: UInt16
    }

    /// Sends `body` as one IPv4 packet, or as fragments when it exceeds the MTU.
    private func sendFragmentable(proto: UInt8, source: UInt32, destination: UInt32, mac: MACAddress, body: ByteView) {
        let route = Route(proto: proto, source: source, destination: destination, mac: mac, identification: takeIdentification())
        let maximumBody = (config.mtu - IPv4Header.minimumLength) & ~7
        guard body.count + IPv4Header.minimumLength > config.mtu else {
            emitFragment(route, fragmentField: 0x4000, body)
            return
        }
        var offset = 0
        while offset < body.count {
            let length = min(maximumBody, body.count - offset)
            let isLast = offset + length == body.count
            let field = UInt16(offset / 8) | (isLast ? 0 : 0x2000)
            guard let piece = body.slice(from: offset, length: length) else { return }
            emitFragment(route, fragmentField: field, piece)
            offset += length
        }
    }

    private func emitFragment(_ route: Route, fragmentField: UInt16, _ body: ByteView) {
        var writer = FrameWriter(txBuffer.mutableView)
        EthernetHeader.write(destination: route.mac, source: config.gatewayMAC, etherType: EtherType.ipv4, into: &writer)
        IPv4Header.write(
            source: route.source, destination: route.destination, proto: route.proto, payloadLength: body.count,
            identification: route.identification, fragmentField: fragmentField, into: &writer)
        writer.bytes(body)
        transmit(writer)
    }

    private func fragmentScratch() -> RawBuffer {
        if let fragmentBuffer { return fragmentBuffer }
        let created = RawBuffer(capacity: 65_536)
        fragmentBuffer = created
        return created
    }

    private func takeIdentification() -> UInt16 {
        defer { nextIdentification &+= 1 }
        return nextIdentification
    }

    private func transmit(_ writer: FrameWriter) {
        guard !writer.overflowed else { return }
        stats.framesToGuest += 1
        stats.bytesToGuest += UInt64(writer.count)
        host.sendToGuest(writer.written)
    }
}
