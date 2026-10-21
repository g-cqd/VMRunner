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
        let phase: FlowEvent.Phase = answer.denial.map { .denied(.policy($0)) } ?? .answered(responseCode: answer.responseCode)
        ctx.host.publish(
            FlowEvent(
                flowID: ctx.makeToken(), transport: .dns, phase: phase, remote: (answer.server, 53), name: answer.name, time: ctx.now,
                bytesToGuest: UInt64(answer.message.count)))
        switch answer.route {
        case .udp(let guestPort, let server):
            ByteView.withBytes(of: answer.message) { payload in
                ctx.sendUDP(
                    from: (server, 53), to: (ctx.config.guestAddress, guestPort), mac: ctx.guestDestination, payload: payload)
            }
        case .tcp(let token):
            guard let flow = tcpByToken[token] else { return }
            let framed = [UInt8(answer.message.count >> 8), UInt8(answer.message.count & 0xFF)] + answer.message
            _ = ByteView.withBytes(of: framed) { flow.enqueueLocalResponse($0, ctx: ctx) }
        }
    }

    /// Extracts complete length-prefixed queries from a DNS-over-TCP flow's inbox.
    func drainDNSStream(_ flow: TCPFlow) {
        while flow.localInbox.count >= 2 {
            let length = Int(flow.localInbox[0]) << 8 | Int(flow.localInbox[1])
            guard flow.localInbox.count >= 2 + length else { return }
            let message = Array(flow.localInbox[2..<(2 + length)])
            flow.localInbox.removeFirst(2 + length)
            ByteView.withBytes(of: message) { handleDNSQuery($0, route: .tcp(flowToken: flow.token)) }
        }
    }
}
