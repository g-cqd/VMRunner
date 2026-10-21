/// TCP: new connections, existing flows, and the host-side events that drive them.
extension UserNetCore {
    func handleTCP(_ header: IPv4Header) {
        let pseudo = InternetChecksum.pseudoHeaderSum(
            source: header.source, destination: header.destination, proto: IPProtocol.tcp, length: header.payload.count)
        let segment: TCPHeader
        do {
            segment = try TCPHeader(parsing: header.payload, verifyingWith: ctx.config.verifyTransportChecksums ? pseudo : nil)
        } catch {
            ctx.stats.malformedFrames += 1
            return
        }
        if !segment.payload.isEmpty && segment.payload.count <= 512 {
            ctx.observe(
                .fromGuest, peer: header.destination,
                transport: .tcp(sourcePort: segment.sourcePort, destinationPort: segment.destinationPort),
                payload: segment.payload, wireLength: header.totalLength)
        }
        let key = FlowKey(guestPort: segment.sourcePort, remotePort: segment.destinationPort, remoteAddress: header.destination)
        let isNewConnection = segment.flags.contains(.syn) && !segment.flags.contains(.ack) && !segment.flags.contains(.rst)
        if let flow = tcpFlows[key] {
            if isNewConnection, flow.isReplaceable(by: segment) {
                flow.terminate(.guestReset, resetGuest: false, ctx: ctx)
                removeTCPFlow(flow)
            } else {
                dispatch(segment, to: flow)
                return
            }
        }
        if isNewConnection {
            openConnection(key: key, syn: segment)
        } else if !segment.flags.contains(.rst) {
            replyWithReset(to: key, segment: segment)
        }
    }

    private func dispatch(_ segment: TCPHeader, to flow: TCPFlow) {
        flow.receive(segment, ctx: ctx)
        if flow.isFinished {
            removeTCPFlow(flow)
        } else if flow.unacknowledgedSegments > 0 || flow.hostWriteStaged, !flow.batchEndQueued {
            flow.batchEndQueued = true
            pendingBatchEnd.append(flow)
        }
        if flow.backend == .localDNS, !flow.localInbox.isEmpty { drainDNSStream(flow) }
    }

    /// RFC 793 reset for a segment that belongs to no connection.
    private func replyWithReset(to key: FlowKey, segment: TCPHeader) {
        let remote = (key.remoteAddress, key.remotePort)
        if segment.flags.contains(.ack) {
            ctx.sendTCP(
                remote: remote, guestPort: key.guestPort, sequence: segment.acknowledgement, acknowledgement: 0, flags: .rst,
                window: 0)
        } else {
            ctx.sendTCP(
                remote: remote, guestPort: key.guestPort, sequence: 0, acknowledgement: segment.sequence &+ segment.sequenceLength,
                flags: .rstAck, window: 0)
        }
    }

    // MARK: New connections

    private func openConnection(key: FlowKey, syn: TCPHeader) {
        let isDNS = key.remotePort == 53 && (key.remoteAddress == ctx.config.gatewayAddress || ctx.config.interceptAllDNS)
        if isDNS {
            startLocalDNS(key: key, syn: syn)
            return
        }
        if key.remoteAddress == ctx.config.gatewayAddress {
            refuse(key: key, syn: syn, denial: .gatewayService(port: key.remotePort), name: nil)
            return
        }
        guard !IPv4.isMulticast(key.remoteAddress), key.remoteAddress != IPv4.broadcast else {
            ctx.stats.droppedUnsupported += 1
            return
        }
        let name: String?
        switch gate.judge(address: key.remoteAddress, port: key.remotePort, now: ctx.now) {
        case .deny(let reason, let deniedName):
            refuse(key: key, syn: syn, denial: .policy(reason), name: deniedName)
            return
        case .allow(let allowedName):
            name = allowedName
        }
        guard tcpFlows.count < ctx.config.maxTCPFlows else {
            refuse(key: key, syn: syn, denial: .flowLimit, name: name)
            return
        }
        let flow = TCPFlow(
            token: ctx.makeToken(), key: key, syn: syn, name: name, backend: .host, initialSequence: makeSequence(), ctx: ctx)
        register(flow)
        ctx.host.openStream(token: flow.token, address: key.remoteAddress, port: key.remotePort)
    }

    private func startLocalDNS(key: FlowKey, syn: TCPHeader) {
        guard tcpFlows.count < ctx.config.maxTCPFlows else {
            refuse(key: key, syn: syn, denial: .flowLimit, name: nil)
            return
        }
        let flow = TCPFlow(
            token: ctx.makeToken(), key: key, syn: syn, name: nil, backend: .localDNS, initialSequence: makeSequence(), ctx: ctx)
        register(flow)
        flow.beginHandshake(ctx: ctx)
    }

    private func refuse(key: FlowKey, syn: TCPHeader, denial: FlowDenial, name: String?) {
        ctx.stats.tcpFlowsDenied += 1
        publishDenied(.tcp, key: key, name: name, denial)
        guard ctx.config.denyAction == .reset else { return }
        ctx.sendTCP(
            remote: (key.remoteAddress, key.remotePort), guestPort: key.guestPort, sequence: 0,
            acknowledgement: syn.sequence &+ 1, flags: .rstAck, window: 0)
    }

    private func register(_ flow: TCPFlow) {
        tcpFlows[flow.key] = flow
        tcpByToken[flow.token] = flow
    }

    func removeTCPFlow(_ flow: TCPFlow) {
        if tcpFlows[flow.key] === flow { tcpFlows[flow.key] = nil }
        tcpByToken[flow.token] = nil
    }

    // MARK: Host events

    /// The non-blocking connect for `token` finished; `error` is its `errno`, or `nil` on success.
    func streamConnected(token: UInt64, error: Int32?) {
        ctx.now = currentTime()
        guard let flow = tcpByToken[token] else { return }
        flow.hostConnected(error: error, ctx: ctx)
        afterHostEvent(flow)
    }

    func streamReadable(token: UInt64) {
        ctx.now = currentTime()
        guard let flow = tcpByToken[token] else { return }
        flow.hostReadable(ctx: ctx)
        afterHostEvent(flow)
    }

    func streamWritable(token: UInt64) {
        ctx.now = currentTime()
        guard let flow = tcpByToken[token] else { return }
        flow.hostWritable(ctx: ctx)
        afterHostEvent(flow)
    }

    private func afterHostEvent(_ flow: TCPFlow) {
        if flow.isFinished { removeTCPFlow(flow) }
    }
}

extension TCPFlow {
    /// Whether a new SYN on this 4-tuple means the guest reused the port, as opposed to retransmitting the SYN
    /// that created this flow.
    func isReplaceable(by syn: TCPHeader) -> Bool {
        switch state {
        case .timeWait, .closed: true
        case .connecting, .synReceived: syn.sequence &+ 1 != receiveNext
        default: true
        }
    }
}
