/// Refusals as events: one per destination per interval, with the rest counted (see ``DenialSuppression``).
extension UserNetCore {
    func publishDenied(_ transport: FlowTransport, key: FlowKey, name: String?, _ denial: FlowDenial) {
        let endpoint = DenialSuppression.Endpoint(transport: transport, address: key.remoteAddress, port: key.remotePort, name: nil)
        publishDenied(endpoint, name: name, denial)
    }

    /// Publishes the refusal unless an equal one went out within the interval; then it is only counted.
    func publishDenied(
        _ endpoint: DenialSuppression.Endpoint, name: String?, _ denial: FlowDenial, bytesToGuest: UInt64 = 0
    ) {
        switch denials.admit(endpoint, denial, name: name, now: ctx.now) {
        case .suppress:
            ctx.stats.deniedEventsSuppressed += 1
        case .publish(let held):
            if let held { publish(held) }
            ctx.host.publish(
                FlowEvent(
                    flowID: ctx.makeToken(), transport: endpoint.transport, phase: .denied(denial),
                    remote: (endpoint.address, endpoint.port), name: name, time: ctx.now, bytesToGuest: bytesToGuest))
        }
    }

    /// Publishes what was held back for refusals whose interval is over.
    func publishExpiredDenials() {
        for held in denials.expire(now: ctx.now) { publish(held) }
    }

    /// Publishes everything held back and starts afresh: the policy that made the refusals is gone.
    func publishAndForgetDenials() {
        for held in denials.drain() { publish(held) }
    }

    private func publish(_ held: DenialSuppression.Held) {
        ctx.host.publish(
            FlowEvent(
                flowID: ctx.makeToken(), transport: held.endpoint.transport, phase: .denied(held.denial),
                remote: (held.endpoint.address, held.endpoint.port), name: held.name, time: ctx.now, count: held.count))
    }
}
