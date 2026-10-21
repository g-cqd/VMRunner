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
        if datagram.destinationPort == DHCPServer.serverPort, isDHCPClientTraffic(header) {
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

    /// Whether a datagram to port 67 is for the DHCP server: from the address the guest leases or from `0.0.0.0` (a client
    /// that has none yet), and to the broadcast address or the gateway (a renewal). A datagram to port 67 of anything else,
    /// on or off the guest's subnet, is not DHCP; it goes the way any other datagram goes.
    private func isDHCPClientTraffic(_ header: IPv4Header) -> Bool {
        (header.source == 0 || header.source == ctx.config.guestAddress)
            && (header.destination == IPv4.broadcast || header.destination == ctx.config.gatewayAddress)
    }

    private func isSubnetBroadcast(_ address: UInt32) -> Bool {
        address == ctx.config.gatewayAddress | ~IPv4.mask(prefixLength: ctx.config.prefixLength)
    }

    private func forwardDatagram(_ key: FlowKey, payload: ByteView) {
        if let flow = udpFlows[key] {
            flow.forward(payload, ctx: ctx)
            return
        }
        let endpoint = DenialSuppression.Endpoint(transport: .udp, address: key.remoteAddress, port: key.remotePort, name: nil)
        if denials.absorbs(endpoint, now: ctx.now) {
            ctx.stats.deniedEventsSuppressed += 1
            return
        }
        let name: String?
        switch gate.judge(address: key.remoteAddress, port: key.remotePort, now: ctx.now) {
        case .deny(let reason, let deniedName):
            denyDatagram(key, name: deniedName, .policy(reason))
            return
        case .allow(let allowedName):
            name = allowedName
        }
        guard admitNewDatagramFlow() else {
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
        publishDenied(.udp, key: key, name: name, denial)
    }

    /// Whether the guest may open one more UDP or ICMP flow now. How fast it opens them is limited (each is a host
    /// socket), and at the table's limit the least recently used flows go in one batch, down to a low-water mark: a
    /// guest that sends to a new destination with every datagram costs one pass per batch, not a scan of the table
    /// and a closed socket for every packet.
    func admitNewDatagramFlow() -> Bool {
        guard datagramFlowBudget.take(now: ctx.now) else { return false }
        return udpFlows.count + icmpFlows.count < ctx.config.maxUDPFlows || evictLeastRecentlyUsedDatagramFlows()
    }

    /// Closes the least recently used eighth of the table (at least one flow). `true` if anything was closed.
    private func evictLeastRecentlyUsedDatagramFlows() -> Bool {
        guard !datagramByToken.isEmpty else { return false }
        let batch = max(ctx.config.maxUDPFlows / 8, 1)
        let oldestFirst = datagramByToken.values.sorted { ($0.lastActivity, $0.token) < ($1.lastActivity, $1.token) }
        ctx.stats.datagramEvictionPasses += 1
        for flow in oldestFirst.prefix(batch) {
            closeDatagramFlow(flow, .evicted)
            ctx.stats.datagramFlowsEvicted += 1
        }
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
