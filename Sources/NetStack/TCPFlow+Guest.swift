/// Segments arriving from the guest.
extension TCPFlow {
    /// Processes one segment for an existing flow. Called by the core after it matched the flow key.
    func receive(_ segment: TCPHeader, ctx: UserNetContext<some UserNetHost>) {
        lastActivity = ctx.now
        switch state {
        case .closed: return
        case .connecting:
            // A retransmitted SYN (or an early ACK) waits for the host connection; a reset cancels it, so the
            // pending host socket is aborted instead of connecting for nobody.
            if segment.flags.contains(.rst), segment.sequence == receiveNext || segment.sequence &+ 1 == receiveNext {
                terminate(.guestReset, resetGuest: false, ctx: ctx)
            }
            return
        case .timeWait:
            if segment.flags.contains(.fin) { sendAcknowledgement(ctx: ctx) }
            return
        default: break
        }
        if segment.flags.contains(.rst) {
            acceptReset(segment, ctx: ctx)
            return
        }
        if segment.flags.contains(.syn) {
            if state == .synReceived, segment.sequence &+ 1 == receiveNext { sendSynAck(ctx: ctx) }
            return
        }
        guard segment.flags.contains(.ack) else { return }
        guard processAcknowledgement(segment, ctx: ctx) else { return }
        processData(segment, ctx: ctx)
        pump(ctx: ctx)
        updateReadInterest(ctx: ctx)
    }

    /// An RST is honoured when its sequence number is inside the receive window (RFC 5961), which stops a stray
    /// or forged segment from killing the flow.
    private func acceptReset(_ segment: TCPHeader, ctx: UserNetContext<some UserNetHost>) {
        let offset = TCPSequence.distance(from: receiveNext, to: segment.sequence)
        // Never before the next expected sequence number; from there, inside the window, or anywhere while the handshake
        // is unfinished (there is no window to speak of yet).
        let withinReach = offset <= max(receiveSpace, 1) || state == .synReceived
        guard offset >= 0, withinReach else { return }
        terminate(.guestReset, resetGuest: false, ctx: ctx)
    }

    /// Handles the ACK field. Returns `false` when the segment was rejected and must not be processed further.
    private func processAcknowledgement(_ segment: TCPHeader, ctx: UserNetContext<some UserNetHost>) -> Bool {
        let ack = segment.acknowledgement
        if state == .synReceived {
            guard ack == sendNext else {
                ctx.sendTCP(remote: remote, guestPort: key.guestPort, sequence: ack, acknowledgement: 0, flags: .rst, window: 0)
                return false
            }
            sendUnacknowledged = ack
            state = .established
            retransmitDeadline = .infinity
            retransmitTimeout = Self.initialRetransmitTimeout
            retransmits = 0
            reportOpened(ctx: ctx)
            if backend == .host { ctx.stats.tcpFlowsOpened += 1 }
        }
        if TCPSequence.greaterThan(ack, sendNext) {
            sendAcknowledgement(ctx: ctx)
            return false
        }
        if TCPSequence.greaterThan(ack, sendUnacknowledged) {
            advanceAcknowledgement(to: ack, ctx: ctx)
        } else if ack == sendUnacknowledged, segment.payload.isEmpty, !segment.flags.contains(.fin), sendUnacknowledged != sendNext,
            Int(segment.window) << Int(guestWindowShift) == sendWindow
        {
            countDuplicateAcknowledgement(ctx: ctx)
        }
        if TCPSequence.lessOrEqual(sendUnacknowledged, ack) { sendWindow = Int(segment.window) << Int(guestWindowShift) }
        return state != .closed
    }

    private func advanceAcknowledgement(to ack: UInt32, ctx: UserNetContext<some UserNetHost>) {
        var acknowledged = TCPSequence.distance(from: sendUnacknowledged, to: ack)
        if finSent, ack == sendNext {
            finAcknowledged = true
            acknowledged -= 1
        }
        toGuest?.discard(acknowledged)
        sendUnacknowledged = ack
        duplicateAcknowledgements = 0
        retransmits = 0
        retransmitTimeout = Self.initialRetransmitTimeout
        retransmitDeadline = ack == sendNext ? .infinity : ctx.now + retransmitTimeout
        if let ring = toGuest, ring.isEmpty, !hostFinished {
            ctx.sendRings.release(ring)
            toGuest = nil
        }
        if finAcknowledged { ourFinWasAcknowledged(ctx: ctx) }
    }

    private func countDuplicateAcknowledgement(ctx: UserNetContext<some UserNetHost>) {
        duplicateAcknowledgements += 1
        if duplicateAcknowledgements == 3 {
            ctx.stats.tcpRetransmits += 1
            retransmitFirstSegment(ctx: ctx)
        }
    }

    private func ourFinWasAcknowledged(ctx: UserNetContext<some UserNetHost>) {
        switch state {
        case .finWait1: state = .finWait2
        case .closing, .lastAck: finishIfDrained(ctx: ctx)
        default: break
        }
    }

    // MARK: Data

    private func processData(_ segment: TCPHeader, ctx: UserNetContext<some UserNetHost>) {
        var payload = segment.payload
        var hasFin = segment.flags.contains(.fin)
        guard !payload.isEmpty || hasFin else { return }
        guard state == .established || state == .finWait1 || state == .finWait2 else {
            sendAcknowledgement(ctx: ctx)  // a retransmission after we already saw the guest's FIN
            return
        }
        let skew = TCPSequence.distance(from: receiveNext, to: segment.sequence)
        if skew > 0 {
            sendAcknowledgement(ctx: ctx)  // out of order: duplicate ACK, the guest retransmits
            return
        }
        if skew < 0 {
            let overlap = -skew
            if overlap >= payload.count {
                if overlap > payload.count || !hasFin {
                    sendAcknowledgement(ctx: ctx)  // entirely old
                    return
                }
                payload = .empty
            } else {
                payload = payload.suffix(from: overlap) ?? .empty
            }
        }
        let accepted = min(payload.count, max(receiveSpace, 0))
        if accepted > 0, let part = payload.slice(from: 0, length: accepted) {
            forwardToHost(part, ctx: ctx)
            receiveNext &+= UInt32(accepted)
            bytesToHost += UInt64(accepted)
        }
        if accepted < payload.count { hasFin = false }
        if hasFin {
            receiveNext &+= 1
            guestFinArrived(ctx: ctx)
            sendAcknowledgement(ctx: ctx)
        } else if state != .closed {
            unacknowledgedSegments += 1
            if unacknowledgedSegments >= 2 || accepted < payload.count { sendAcknowledgement(ctx: ctx) }
        }
    }

    private func guestFinArrived(ctx: UserNetContext<some UserNetHost>) {
        guestFinReceived = true
        switch state {
        case .established: state = .closeWait
        case .finWait1: state = finAcknowledged ? .closeWait : .closing
        case .finWait2: finishIfDrained(ctx: ctx)
        default: break
        }
        if backend == .localDNS {
            hostFinished = true
        } else if toHost?.isEmpty ?? true {
            ctx.host.shutdownStreamWrite(token: token)
        } else {
            shutdownAfterDrain = true
        }
    }

    /// Stages guest bytes for the host socket. They are written together at the end of the batch of frames being
    /// processed (see ``flushToHost(ctx:)``), so a burst of segments costs one write call instead of one each.
    private func forwardToHost(_ bytes: ByteView, ctx: UserNetContext<some UserNetHost>) {
        let ring = toHost ?? ctx.receiveRings.acquire()
        toHost = ring
        _ = ring.append(bytes)  // fits: the caller limited `bytes` to the free receive space
        hostWriteStaged = backend == .host  // a DNS flow's bytes wait for the core to take whole queries out
    }
}
