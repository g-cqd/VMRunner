/// Wiring between the DNS proxy, the guest, and the host resolver.
extension UserNetCore {
    func handleDNSQuery(_ message: ByteView, route: DNSReplyRoute) {
        let server: UInt32
        switch route {
        case .udp(_, let address): server = address
        case .tcp(let token): server = tcpByToken[token]?.key.remoteAddress ?? ctx.config.gatewayAddress
        }
        let outcome = dns.begin(message, route: route, server: server, gate: gate, ctx: ctx)
        switch outcome {
        case .answered(let answer):
            deliver(answer)
        case .pending(let token, let name, let type):
            if let state = ctx.vpn.observeDNSQuery(name: name, at: ctx.now) { ctx.host.publish(vpnState: state) }
            ctx.host.resolve(token: token, name: name, recordType: type)
        case .ignored:
            break
        }
    }

    /// The host resolver finished the query registered under `token`.
    func nameResolved(token: UInt64, result: DNSLookupResult) {
        ctx.now = currentTime()
        if let answer = dns.complete(token: token, result: result, gate: &gate, ctx: ctx) { deliver(answer) }
    }

    func deliver(_ answer: DNSAnswer) {
        if let reason = answer.denial {
            let endpoint = DenialSuppression.Endpoint(transport: .dns, address: answer.server, port: 53, name: answer.name)
            publishDenied(endpoint, name: answer.name, .policy(reason), bytesToGuest: UInt64(answer.message.count))
        } else {
            ctx.host.publish(
                FlowEvent(
                    flowID: ctx.makeToken(), transport: .dns, phase: .answered(responseCode: answer.responseCode),
                    remote: (answer.server, 53), name: answer.name, time: ctx.now, bytesToGuest: UInt64(answer.message.count)))
        }
        switch answer.route {
        case .udp(let guestPort, let server):
            ByteView.withBytes(of: answer.message) { payload in
                ctx.sendUDP(
                    from: (server, 53), to: (ctx.config.guestAddress, guestPort), mac: ctx.guestDestination, payload: payload)
            }
        case .tcp(let token):
            // `DNSWire.response` keeps a message within 65,535 bytes; anything else is not framed rather than trapped on.
            guard let flow = tcpByToken[token], let length = UInt16(exactly: answer.message.count) else { return }
            let framed = [UInt8(length >> 8), UInt8(length & 0xFF)] + answer.message
            _ = ByteView.withBytes(of: framed) { flow.enqueueLocalResponse($0, ctx: ctx) }
        }
    }

    /// Extracts complete length-prefixed queries from a DNS-over-TCP flow's inbox (its ring: taking one out moves the
    /// head, nothing is shifted). A length prefix longer than any query resets the connection instead of waiting
    /// for the rest.
    func drainDNSStream(_ flow: TCPFlow) {
        guard let ring = flow.toHost else { return }
        while let prefix = ring.bytes(from: 0, count: 2) {
            let length = Int(prefix[0]) << 8 | Int(prefix[1])
            guard length <= TCPFlow.maximumDNSQuery else {
                flow.terminate(.guestReset, resetGuest: true, ctx: ctx)
                removeTCPFlow(flow)
                return
            }
            guard let message = ring.bytes(from: 2, count: length) else { break }
            ring.discard(2 + length)
            ByteView.withBytes(of: message) { handleDNSQuery($0, route: .tcp(flowToken: flow.token)) }
        }
        if ring.isEmpty, flow.toHost === ring {  // nothing buffered: give the ring back until the next query
            ctx.receiveRings.release(ring)
            flow.toHost = nil
        }
        // Room opened up in the small inbox: say so, or a guest that filled the window waits for a probe.
        if flow.state == .established, flow.receiveSpace - flow.advertisedWindow >= 2 * flow.guestMSS {
            flow.sendAcknowledgement(ctx: ctx)
        }
    }
}
