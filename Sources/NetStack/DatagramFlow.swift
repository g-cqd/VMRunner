import Foundation

/// One guest UDP "connection" (a 5-tuple seen from the guest) or ICMP echo conversation, relayed through a host
/// datagram socket that is connected to the destination.
///
/// The NAT is port-restricted: the host socket only exchanges datagrams with the one address and port the guest
/// first sent to, which is what almost every UDP client expects (DNS, NTP, QUIC, WireGuard). Protocols that
/// expect answers from a different address (some STUN and active-FTP-style exchanges) will not work.
final class DatagramFlow {
    let token: UInt64
    /// For ICMP, `guestPort` holds the echo identifier and `remotePort` is zero.
    let key: FlowKey
    let kind: DatagramKind
    let destinationName: String?
    let openedAt: TimeInterval
    var lastActivity: TimeInterval
    var bytesToHost: UInt64 = 0
    var bytesToGuest: UInt64 = 0
    private(set) var isClosed = false

    init(token: UInt64, key: FlowKey, kind: DatagramKind, name: String?, now: TimeInterval) {
        self.token = token
        self.key = key
        self.kind = kind
        destinationName = name
        openedAt = now
        lastActivity = now
    }

    var transport: FlowTransport { kind == .udp ? .udp : .icmp }

    /// Sends a guest payload (a UDP payload, or a whole ICMP message) to the host socket.
    func forward(_ payload: ByteView, ctx: UserNetContext<some UserNetHost>) {
        guard !isClosed else { return }
        lastActivity = ctx.now
        switch ctx.host.writeDatagram(token: token, payload) {
        case .transferred: bytesToHost += UInt64(payload.count)
        case .wouldBlock, .endOfStream: break  // UDP is lossy by contract: a full socket drops the datagram
        case .failed(let error): close(.hostError(error), ctx: ctx)
        }
    }

    /// The host socket has datagrams: relay up to a bounded batch to the guest.
    func hostReadable(ctx: UserNetContext<some UserNetHost>) {
        // A `while` loop, not `for _ in 0..<32`: an unoptimized build boxes a generic range iterator on every call.
        var datagrams = 0
        while datagrams < 32, !isClosed {
            datagrams += 1
            let region = ctx.datagramScratch.mutableView
            switch ctx.host.readDatagram(token: token, into: region) {
            case .transferred(let count):
                lastActivity = ctx.now
                bytesToGuest += UInt64(count)
                deliver(region.readable.prefix(count), ctx: ctx)
            case .wouldBlock, .endOfStream:
                return
            case .failed(let error):
                // ECONNREFUSED on a connected UDP socket is the ICMP port-unreachable of an earlier datagram.
                if error != ECONNREFUSED { close(.hostError(error), ctx: ctx) }
                return
            }
        }
    }

    private func deliver(_ payload: ByteView, ctx: UserNetContext<some UserNetHost>) {
        switch kind {
        case .udp:
            ctx.observe(
                .toGuest, peer: key.remoteAddress, transport: .udp(sourcePort: key.remotePort, destinationPort: key.guestPort),
                payload: payload, wireLength: payload.count + 28)
            ctx.sendUDP(
                from: (key.remoteAddress, key.remotePort), to: (ctx.config.guestAddress, key.guestPort), mac: ctx.guestDestination,
                payload: payload)
        case .icmpEcho:
            // macOS delivers an echo reply to every ICMP socket connected to the replying address, so each flow passes on only
            // the replies that carry its own identifier; otherwise a guest sees one copy per recent ping.
            if payload[0] == ICMPHeader.echoReply, (try? payload.be16(at: 4)) != key.guestPort { return }
            ctx.sendICMP(from: key.remoteAddress, message: payload)
        }
    }

    func close(_ reason: FlowCloseReason, ctx: UserNetContext<some UserNetHost>) {
        guard !isClosed else { return }
        isClosed = true
        ctx.host.closeDatagram(token: token)
        ctx.host.publish(
            FlowEvent(
                flowID: token, transport: transport, phase: .closed(reason), remote: (key.remoteAddress, key.remotePort),
                name: destinationName, time: ctx.now, bytesToHost: bytesToHost, bytesToGuest: bytesToGuest,
                duration: ctx.now - openedAt))
    }
}
