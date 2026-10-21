import Foundation

/// A DHCP server for exactly one guest (RFC 2131): DISCOVER gets an OFFER, REQUEST gets an ACK or NAK, RELEASE and
/// DECLINE free the lease, INFORM gets an option-only ACK.
///
/// The guest always gets `UserNetConfig.guestAddress`; the router and DNS server options are the gateway (so
/// guests resolve through the built-in proxy), the MTU option matches the link, and the lease lasts
/// `leaseDuration`. The first client hardware address to ask owns the lease; another client is ignored until the
/// lease expires or is released, because there is only one address to give.
///
/// Parsing walks the options in place and the reply is assembled in a reusable scratch buffer, so a handshake
/// allocates nothing.
final class DHCPServer {
    private enum MessageType: UInt8 {
        case discover = 1
        case offer = 2
        case request = 3
        case decline = 4
        case ack = 5
        case nak = 6
        case release = 7
        case inform = 8
    }

    private enum Option {
        static let subnetMask: UInt8 = 1
        static let router: UInt8 = 3
        static let dnsServers: UInt8 = 6
        static let interfaceMTU: UInt8 = 26
        static let broadcastAddress: UInt8 = 28
        static let requestedAddress: UInt8 = 50
        static let leaseTime: UInt8 = 51
        static let messageType: UInt8 = 53
        static let serverIdentifier: UInt8 = 54
        static let renewalTime: UInt8 = 58
        static let rebindingTime: UInt8 = 59
        static let end: UInt8 = 255
    }

    private struct Request {
        var type: MessageType
        var transaction: UInt32
        var flags: UInt16
        var clientAddress: UInt32
        var client: MACAddress
        var requestedAddress: UInt32?
        var serverIdentifier: UInt32?
    }

    static let clientPort: UInt16 = 68
    static let serverPort: UInt16 = 67
    private static let headerLength = 240

    private var leaseHolder: MACAddress?
    private var leaseExpiry: TimeInterval = 0

    /// Handles one DHCP datagram payload from the guest.
    func handle(_ payload: ByteView, ctx: UserNetContext<some UserNetHost>) {
        guard let request = parse(payload) else { return }
        if let holder = leaseHolder, leaseExpiry > ctx.now, holder != request.client { return }
        switch request.type {
        case .discover:
            reply(.offer, to: request, ctx: ctx)
        case .request:
            answerRequest(request, ctx: ctx)
        case .inform:
            reply(.ack, to: request, ctx: ctx, includeLease: false)
        case .release, .decline:
            if leaseHolder == request.client { leaseHolder = nil }
        case .offer, .ack, .nak:
            break
        }
    }

    private func answerRequest(_ request: Request, ctx: UserNetContext<some UserNetHost>) {
        if let server = request.serverIdentifier, server != ctx.config.gatewayAddress { return }  // chose another server
        let wanted = request.requestedAddress ?? (request.clientAddress != 0 ? request.clientAddress : nil)
        guard wanted == ctx.config.guestAddress else {
            reply(.nak, to: request, ctx: ctx)
            return
        }
        leaseHolder = request.client
        leaseExpiry = ctx.now + ctx.config.leaseDuration
        ctx.stats.dhcpAcks += 1
        reply(.ack, to: request, ctx: ctx)
    }

    // MARK: Parsing

    private func parse(_ payload: ByteView) -> Request? {
        guard payload.count >= Self.headerLength, payload[0] == 1, payload[1] == 1, payload[2] == 6,
            let magic = try? payload.be32(at: 236), magic == 0x6382_5363,
            let transaction = try? payload.be32(at: 4), let flags = try? payload.be16(at: 10),
            let clientAddress = try? payload.be32(at: 12), let mac = try? payload.be48(at: 28)
        else { return nil }
        var type: MessageType?
        var requested: UInt32?
        var server: UInt32?
        var offset = Self.headerLength
        while offset < payload.count, let code = payload[offset], code != Option.end {
            if code == 0 {
                offset += 1
                continue
            }
            guard let length = payload[offset + 1].map(Int.init), offset + 2 + length <= payload.count else { return nil }
            switch code {
            case Option.messageType where length == 1: type = payload[offset + 2].flatMap(MessageType.init(rawValue:))
            case Option.requestedAddress where length == 4: requested = try? payload.be32(at: offset + 2)
            case Option.serverIdentifier where length == 4: server = try? payload.be32(at: offset + 2)
            default: break
            }
            offset += 2 + length
        }
        guard let type else { return nil }
        return Request(
            type: type, transaction: transaction, flags: flags, clientAddress: clientAddress, client: MACAddress(rawValue: mac),
            requestedAddress: requested, serverIdentifier: server)
    }

    // MARK: Replies

    private func reply(
        _ type: MessageType, to request: Request, ctx: UserNetContext<some UserNetHost>, includeLease: Bool = true
    ) {
        let config = ctx.config
        var writer = FrameWriter(ctx.datagramScratch.mutableView)
        writer.u8(2)  // BOOTREPLY
        writer.u8(1)
        writer.u8(6)
        writer.u8(0)
        writer.be32(request.transaction)
        writer.be16(0)
        writer.be16(request.flags)
        writer.be32(request.clientAddress)
        writer.be32(type == .nak || !includeLease ? 0 : config.guestAddress)
        writer.be32(0)
        writer.be32(0)
        writer.be48(request.client.rawValue)
        writer.zeros(10 + 64 + 128)
        writer.be32(0x6382_5363)
        writeOptions(type, includeLease: includeLease && type != .nak, config: config, into: &writer)
        if writer.count < 300 { writer.zeros(300 - writer.count) }
        let unicast = request.clientAddress != 0 && request.flags & 0x8000 == 0
        ctx.sendUDP(
            from: (config.gatewayAddress, Self.serverPort),
            to: (unicast ? request.clientAddress : IPv4.broadcast, Self.clientPort),
            mac: unicast ? request.client : .broadcast, payload: writer.written)
    }

    private func writeOptions(_ type: MessageType, includeLease: Bool, config: UserNetConfig, into writer: inout FrameWriter) {
        writer.u8(Option.messageType)
        writer.u8(1)
        writer.u8(type.rawValue)
        writer.u8(Option.serverIdentifier)
        writer.u8(4)
        writer.be32(config.gatewayAddress)
        guard type != .nak else {
            writer.u8(Option.end)
            return
        }
        let mask = IPv4.mask(prefixLength: config.prefixLength)
        if includeLease {
            let lease = UInt32(clamping: Int(config.leaseDuration))
            writeWord(Option.leaseTime, lease, into: &writer)
            writeWord(Option.renewalTime, lease / 2, into: &writer)
            writeWord(Option.rebindingTime, lease / 8 * 7, into: &writer)
        }
        writeWord(Option.subnetMask, mask, into: &writer)
        writeWord(Option.router, config.gatewayAddress, into: &writer)
        writeWord(Option.dnsServers, config.gatewayAddress, into: &writer)
        writeWord(Option.broadcastAddress, config.gatewayAddress | ~mask, into: &writer)
        writer.u8(Option.interfaceMTU)
        writer.u8(2)
        writer.be16(UInt16(clamping: config.mtu))
        writer.u8(Option.end)
    }

    private func writeWord(_ code: UInt8, _ value: UInt32, into writer: inout FrameWriter) {
        writer.u8(code)
        writer.u8(4)
        writer.be32(value)
    }
}
