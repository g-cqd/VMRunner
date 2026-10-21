/// IPv4 dispatch and ICMP.
extension UserNetCore {
    func handleIPv4(_ payload: ByteView) {
        let header: IPv4Header
        do {
            header = try IPv4Header(parsing: payload)
        } catch {
            ctx.stats.malformedFrames += 1
            return
        }
        // Only a DHCP client may speak before it has an address (source 0.0.0.0, UDP).
        guard header.source == ctx.config.guestAddress || (header.source == 0 && header.proto == IPProtocol.udp) else {
            ctx.stats.droppedUnsupported += 1  // not the address we leased: the guest may not spoof
            return
        }
        guard !header.isFragment else {
            ctx.stats.droppedFragments += 1
            return
        }
        // The guest's own subnet is on-link: traffic for it never goes through the gateway, and the gateway itself
        // is the only address on it that this stack answers. Anything else addressed there is not forwarded to the
        // host, whatever the policy says.
        if ctx.config.isOnLink(header.destination), header.destination != ctx.config.gatewayAddress,
            header.destination != IPv4.broadcast, !isDHCPRequest(header)
        {
            ctx.stats.droppedUnsupported += 1
            return
        }
        switch header.proto {
        case IPProtocol.udp: handleUDP(header)
        case IPProtocol.tcp: handleTCP(header)
        case IPProtocol.icmp: handleICMP(header)
        default:
            // ESP, AH, GRE, IGMP...: nothing to NAT them with, but a VPN detector wants to know they exist.
            ctx.observe(
                .fromGuest, peer: header.destination, transport: .ipProtocol(header.proto), payload: header.payload,
                wireLength: header.totalLength)
            ctx.stats.droppedUnsupported += 1
        }
    }

    /// DHCP clients broadcast (or unicast to the gateway) to port 67; those packets are handled locally.
    private func isDHCPRequest(_ header: IPv4Header) -> Bool {
        header.proto == IPProtocol.udp && ((try? header.payload.be16(at: 2)) ?? 0) == DHCPServer.serverPort
    }

    // MARK: ICMP

    private func handleICMP(_ header: IPv4Header) {
        guard let echo = try? ICMPHeader(parsing: header.payload, verifyChecksum: ctx.config.verifyTransportChecksums),
            echo.type == ICMPHeader.echoRequest, echo.code == 0
        else {
            ctx.stats.droppedUnsupported += 1
            return
        }
        ctx.stats.icmpEchoes += 1
        if header.destination == ctx.config.gatewayAddress {
            replyToEcho(echo, from: header.destination)
            return
        }
        guard !IPv4.isMulticast(header.destination), header.destination != IPv4.broadcast else {
            ctx.stats.droppedUnsupported += 1
            return
        }
        let key = FlowKey(guestPort: echo.identifier, remotePort: 0, remoteAddress: header.destination)
        if let flow = icmpFlows[key] {
            flow.forward(header.payload, ctx: ctx)
            return
        }
        openEchoFlow(key, message: header.payload)
    }

    private func openEchoFlow(_ key: FlowKey, message: ByteView) {
        let verdict = gate.judgeEcho(address: key.remoteAddress, now: ctx.now)
        let name: String?
        switch verdict {
        case .deny(let reason, let deniedName):
            publishDenied(.icmp, key: key, name: deniedName, .policy(reason))
            return
        case .allow(let allowedName):
            name = allowedName
        }
        guard udpFlows.count + icmpFlows.count < ctx.config.maxUDPFlows || evictOldestDatagramFlow() else {
            publishDenied(.icmp, key: key, name: name, .flowLimit)
            return
        }
        let token = ctx.makeToken()
        guard ctx.host.openDatagram(token: token, kind: .icmpEcho, address: key.remoteAddress, port: 0) else {
            publishDenied(.icmp, key: key, name: name, .unroutable)
            return
        }
        let flow = DatagramFlow(token: token, key: key, kind: .icmpEcho, name: name, now: ctx.now)
        icmpFlows[key] = flow
        datagramByToken[token] = flow
        publishOpened(flow)
        flow.forward(message, ctx: ctx)
    }

    /// Answers an echo addressed to the gateway itself.
    private func replyToEcho(_ echo: ICMPHeader, from address: UInt32) {
        var writer = FrameWriter(ctx.datagramScratch.mutableView)
        writer.u8(ICMPHeader.echoReply)
        writer.u8(0)
        writer.be16(0)
        writer.be16(echo.identifier)
        writer.be16(echo.sequence)
        writer.bytes(echo.payload)
        writer.patchBE16(InternetChecksum.finish(writer.sum(from: 0)), at: 2)
        ctx.sendICMP(from: address, message: writer.written)
    }

    // MARK: Events

    func publishDenied(_ transport: FlowTransport, key: FlowKey, name: String?, _ denial: FlowDenial) {
        ctx.host.publish(
            FlowEvent(
                flowID: ctx.makeToken(), transport: transport, phase: .denied(denial), remote: (key.remoteAddress, key.remotePort),
                name: name, time: ctx.now))
    }

    func publishOpened(_ flow: DatagramFlow) {
        ctx.host.publish(
            FlowEvent(
                flowID: flow.token, transport: flow.transport, phase: .opened, remote: (flow.key.remoteAddress, flow.key.remotePort),
                name: flow.destinationName, time: ctx.now))
    }
}
