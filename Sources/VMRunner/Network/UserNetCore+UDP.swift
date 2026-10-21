/// UDP: DHCP, DNS interception, and NATed datagram flows.
extension UserNetCore {
    func handleUDP(_ header: IPv4Header) {
        let pseudo = InternetChecksum.pseudoHeaderSum(
            source: header.source, destination: header.destination, proto: IPProtocol.udp, length: header.payload.count)
        let datagram: UDPHeader
        do {
            datagram = try UDPHeader(parsing: header.payload, verifyingWith: ctx.config.verifyTransportChecksums ? pseudo : nil)
        } catch {
            ctx.stats.malformedFrames += 1
            return
        }
        if datagram.destinationPort == DHCPServer.serverPort {
            dhcp.handle(datagram.payload, ctx: ctx)
            return
        }
        guard header.source == ctx.config.guestAddress else {
            ctx.stats.droppedUnsupported += 1
            return
        }
        ctx.observe(
            .fromGuest, peer: header.destination,
            transport: .udp(sourcePort: datagram.sourcePort, destinationPort: datagram.destinationPort),
            payload: datagram.payload, wireLength: header.totalLength)
        let key = FlowKey(guestPort: datagram.sourcePort, remotePort: datagram.destinationPort, remoteAddress: header.destination)
        if datagram.destinationPort == 53, header.destination == ctx.config.gatewayAddress || ctx.config.interceptAllDNS {
            handleDNSQuery(datagram.payload, route: .udp(guestPort: key.guestPort, server: header.destination))
        } else if header.destination == ctx.config.gatewayAddress {
            publishDenied(.udp, key: key, name: nil, .gatewayService(port: key.remotePort))
        } else if IPv4.isMulticast(header.destination) || header.destination == IPv4.broadcast || isSubnetBroadcast(header.destination) {
            ctx.stats.droppedUnsupported += 1
        } else {
            forwardDatagram(key, payload: datagram.payload)
        }
    }

    private func isSubnetBroadcast(_ address: UInt32) -> Bool {
        address == ctx.config.gatewayAddress | ~IPv4.mask(prefixLength: ctx.config.prefixLength)
    }

    private func forwardDatagram(_ key: FlowKey, payload: ByteView) {
        if let flow = udpFlows[key] {
            flow.forward(payload, ctx: ctx)
            return
        }
        if let until = recentUDPDenials[key], until > ctx.now { return }
        let name: String?
        switch gate.judge(address: key.remoteAddress, port: key.remotePort, now: ctx.now) {
        case .deny(let reason, let deniedName):
            denyDatagram(key, name: deniedName, .policy(reason))
            return
        case .allow(let allowedName):
            name = allowedName
        }
        guard udpFlows.count + icmpFlows.count < ctx.config.maxUDPFlows || evictOldestDatagramFlow() else {
            denyDatagram(key, name: name, .flowLimit)
            return
        }
        let token = ctx.makeToken()
        guard ctx.host.openDatagram(token: token, kind: .udp, address: key.remoteAddress, port: key.remotePort) else {
            denyDatagram(key, name: name, .unroutable)
            return
        }
        let flow = DatagramFlow(token: token, key: key, kind: .udp, name: name, now: ctx.now)
        udpFlows[key] = flow
        datagramByToken[token] = flow
        ctx.stats.udpFlowsOpened += 1
        publishOpened(flow)
        flow.forward(payload, ctx: ctx)
    }

    private func denyDatagram(_ key: FlowKey, name: String?, _ denial: FlowDenial) {
        ctx.stats.udpFlowsDenied += 1
        if recentUDPDenials.count >= 256 { recentUDPDenials.removeAll(keepingCapacity: true) }
        recentUDPDenials[key] = ctx.now + 5
        publishDenied(.udp, key: key, name: name, denial)
    }

    /// Closes the least recently used datagram flow to make room. `true` if one was closed.
    func evictOldestDatagramFlow() -> Bool {
        let oldest = datagramByToken.values.min { $0.lastActivity < $1.lastActivity }
        guard let oldest else { return false }
        closeDatagramFlow(oldest, .evicted)
        return true
    }

    func closeDatagramFlow(_ flow: DatagramFlow, _ reason: FlowCloseReason) {
        flow.close(reason, ctx: ctx)
        if flow.kind == .udp { udpFlows[flow.key] = nil } else { icmpFlows[flow.key] = nil }
        datagramByToken[flow.token] = nil
    }

    /// The host datagram socket for `token` has data.
    func datagramReadable(token: UInt64) {
        ctx.now = currentTime()
        guard let flow = datagramByToken[token] else { return }
        flow.hostReadable(ctx: ctx)
        if flow.isClosed { closeDatagramFlow(flow, .finished) }
    }
}
