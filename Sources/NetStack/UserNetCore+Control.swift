/// Time, policy changes, host path changes, and shutdown.
import NetPolicy

extension UserNetCore {
    /// Periodic housekeeping: timeouts, retransmission, delayed acknowledgements. Call a few times per second.
    func tick() {
        ctx.now = currentTime()
        endOfBatch()  // a shell that forgot to call it still makes progress
        for flow in tcpFlows.values {
            flow.tick(ctx: ctx)
            if !flow.isFinished, flow.unacknowledgedSegments > 0 { flow.sendAcknowledgement(ctx: ctx) }
        }
        sweepFinishedTCPFlows()
        sweepIdleDatagramFlows()
        for answer in dns.expire(now: ctx.now) { deliver(answer) }
        publishExpiredDenials()
        publishHeldAnswers()
        if let state = ctx.vpn.tick(at: ctx.now) { ctx.host.publish(vpnState: state) }
        if ctx.now - lastHousekeeping >= 30 {
            lastHousekeeping = ctx.now
            gate.names.prune(now: ctx.now)
            gate.derivedBlocks.prune(now: ctx.now)
        }
    }

    private func sweepFinishedTCPFlows() {
        scratchKeys.removeAll(keepingCapacity: true)
        for (key, flow) in tcpFlows where flow.isFinished { scratchKeys.append(key) }
        for key in scratchKeys {
            if let flow = tcpFlows[key] { removeTCPFlow(flow) }
        }
    }

    private func sweepIdleDatagramFlows() {
        scratchKeys.removeAll(keepingCapacity: true)
        for (key, flow) in udpFlows where ctx.now - flow.lastActivity >= ctx.config.udpIdleTimeout { scratchKeys.append(key) }
        for key in scratchKeys {
            if let flow = udpFlows[key] { closeDatagramFlow(flow, .idleTimeout) }
        }
        scratchKeys.removeAll(keepingCapacity: true)
        for (key, flow) in icmpFlows where ctx.now - flow.lastActivity >= ctx.config.icmpIdleTimeout { scratchKeys.append(key) }
        for key in scratchKeys {
            if let flow = icmpFlows[key] { closeDatagramFlow(flow, .idleTimeout) }
        }
    }

    /// Installs a new policy. New flows are judged by it from the next packet on.
    ///
    /// - Parameters:
    ///   - policy: The policy to enforce from now on.
    ///   - existingFlows: `.terminate` re-judges every open flow against the new policy and tears down
    ///   those that no longer pass (TCP flows get RST, so the guest reconnects and is judged afresh; datagram flows
    ///   are forgotten). `.keep` leaves them running until they end on their own.
    /// - Returns: How many flows were torn down.
    @discardableResult
    func updatePolicy(_ policy: NetworkPolicy, existingFlows: ExistingFlowAction) -> Int {
        ctx.now = currentTime()
        gate.policy = policy
        publishAndForgetDenials()  // a refusal made under the old policy says nothing about the new one
        guard existingFlows == .terminate else { return 0 }
        var revoked = 0
        for flow in tcpFlows.values where flow.backend == .host && flow.isLive {
            if case .deny(let reason, _) = gate.judge(address: flow.key.remoteAddress, port: flow.key.remotePort, now: ctx.now) {
                flow.terminate(.policyRevoked(reason), resetGuest: true, ctx: ctx)
                revoked += 1
            }
        }
        sweepFinishedTCPFlows()
        for flow in Array(datagramByToken.values) {
            let verdict =
                flow.kind == .udp
                ? gate.judge(address: flow.key.remoteAddress, port: flow.key.remotePort, now: ctx.now)
                : gate.judgeEcho(address: flow.key.remoteAddress, now: ctx.now)
            if case .deny(let reason, _) = verdict {
                closeDatagramFlow(flow, .policyRevoked(reason))
                revoked += 1
            }
        }
        return revoked
    }

    /// The host's network path changed (interface, gateway or VPN state). `.terminate` resets every flow so the guest
    /// reconnects over the new path; see ``UserNetStack`` for the trade-off.
    func hostPathChanged(existingFlows: ExistingFlowAction) {
        ctx.now = currentTime()
        guard existingFlows == .terminate else { return }
        for flow in tcpFlows.values where flow.backend == .host && flow.isLive {
            flow.terminate(.hostPathChanged, resetGuest: true, ctx: ctx)
        }
        sweepFinishedTCPFlows()
        for flow in Array(datagramByToken.values) { closeDatagramFlow(flow, .hostPathChanged) }
    }

    /// Ends every flow (reporting each as closed by shutdown) and releases host sockets.
    func shutdown() {
        ctx.now = currentTime()
        publishAndForgetDenials()
        publishHeldAnswers(everything: true)
        for flow in tcpFlows.values where flow.isLive { flow.terminate(.stackStopped, resetGuest: false, ctx: ctx) }
        tcpFlows.removeAll()
        tcpByToken.removeAll()
        localDNSFlows = 0
        for flow in Array(datagramByToken.values) { closeDatagramFlow(flow, .stackStopped) }
    }
}

extension TCPFlow {
    /// Whether the flow is still carrying a connection (not finished, and not just a tombstone).
    var isLive: Bool { state != .closed && state != .timeWait }
}
