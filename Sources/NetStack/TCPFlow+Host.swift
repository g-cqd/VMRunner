/// Host-side events, sending to the guest, and timers.
extension TCPFlow {
    // MARK: Handshake

    /// The host connection finished: complete the guest handshake, or refuse it.
    func hostConnected(error: Int32?, ctx: UserNetContext<some UserNetHost>) {
        guard state == .connecting else { return }
        if let error {
            ctx.stats.tcpFlowsFailed += 1
            terminate(.connectFailed(error), resetGuest: true, ctx: ctx)
            return
        }
        beginHandshake(ctx: ctx)
    }

    /// Starts the guest side of the handshake (also used directly by DNS-over-TCP, which has no host connection).
    func beginHandshake(ctx: UserNetContext<some UserNetHost>) {
        state = .synReceived
        sendNext = initialSequence &+ 1
        sendSynAck(ctx: ctx)
        retransmitTimeout = Self.initialRetransmitTimeout
        retransmitDeadline = ctx.now + retransmitTimeout
        setInterest(read: true, write: writeInterest, ctx: ctx)
    }

    // MARK: Host to guest

    /// The host socket has data (or end of stream, or an error).
    func hostReadable(ctx: UserNetContext<some UserNetHost>) {
        guard backend == .host, !hostFinished, state == .established || state == .synReceived || state == .closeWait else { return }
        lastActivity = ctx.now
        // A `while` loop, not `for _ in 0..<2`: an unoptimized build boxes a generic range iterator on every call.
        var reads = 0
        while reads < 2 {
            reads += 1
            let ring = toGuest ?? ctx.sendRings.acquire()
            toGuest = ring
            guard ring.freeSpace > 0 else { break }
            let region = ring.writableRegion()
            switch ctx.host.readStream(token: token, into: region) {
            case .transferred(let count):
                ring.commit(count)
                bytesToGuest += UInt64(count)
            case .wouldBlock:
                dropEmptyRing(ctx: ctx)
                pump(ctx: ctx)
                updateReadInterest(ctx: ctx)
                return
            case .endOfStream:
                hostFinished = true
            case .failed(let error):
                hostFailed(error, ctx: ctx)
                return
            }
            if hostFinished { break }
        }
        pump(ctx: ctx)
        updateReadInterest(ctx: ctx)
    }

    func hostFailed(_ error: Int32, ctx: UserNetContext<some UserNetHost>) {
        terminate(.hostError(error), resetGuest: true, ctx: ctx)
    }

    private func dropEmptyRing(ctx: UserNetContext<some UserNetHost>) {
        if let ring = toGuest, ring.isEmpty, !hostFinished {
            ctx.sendRings.release(ring)
            toGuest = nil
        }
    }

    /// Read from the host only while there is room to hold what it returns; resume once a quarter is free.
    func updateReadInterest(ctx: UserNetContext<some UserNetHost>) {
        guard backend == .host, state != .closed, state != .timeWait else { return }
        let free = sendCapacity - heldToGuest
        let wanted = !hostFinished && (readInterest ? free > 0 : free >= sendCapacity / 4)
        let ready = state == .established || state == .closeWait
        setInterest(read: wanted && ready, write: writeInterest, ctx: ctx)
    }

    /// Sends what the guest's window allows, then the FIN once all data is out and the host has finished.
    func pump(ctx: UserNetContext<some UserNetHost>) {
        guard state == .established || state == .closeWait, !finSent else {
            armRetransmitIfNeeded(ctx: ctx)
            return
        }
        while true {
            let pending = unsent
            let room = min(sendWindow, sendCapacity) - inFlight
            let size = min(pending, room, guestMSS)
            guard size > 0 else { break }
            sendData(size: size, offset: inFlight, sequence: sendNext, push: size == pending, ctx: ctx)
            sendNext &+= UInt32(size)
        }
        if hostFinished, unsent == 0 {
            sendControl(.finAck, ctx: ctx)
            sendNext &+= 1
            finSent = true
            state = state == .closeWait ? .lastAck : .finWait1
        }
        armRetransmitIfNeeded(ctx: ctx)
    }

    private func armRetransmitIfNeeded(ctx: UserNetContext<some UserNetHost>) {
        let awaitingAcknowledgement = sendUnacknowledged != sendNext || (sendWindow == 0 && unsent > 0)
        if awaitingAcknowledgement, retransmitDeadline == .infinity {
            retransmitDeadline = ctx.now + retransmitTimeout
        }
    }

    private func sendData(size: Int, offset: Int, sequence: UInt32, push: Bool, ctx: UserNetContext<some UserNetHost>) {
        guard let ring = toGuest else { return }
        let first = ring.contiguous(from: offset, limit: size)
        let second = first.count < size ? ring.contiguous(from: offset + first.count, limit: size - first.count) : .empty
        let field = currentWindowField()
        advertisedWindow = Int(field) << Int(ownWindowShift ?? 0)
        unacknowledgedSegments = 0
        ctx.sendTCP(
            remote: remote, guestPort: key.guestPort, sequence: sequence, acknowledgement: receiveNext,
            flags: push ? .pushAck : .ack, window: field, payload: first, tail: second)
    }

    // MARK: Guest-bound window updates and host writes

    /// The host socket can take more.
    func hostWritable(ctx: UserNetContext<some UserNetHost>) {
        flushToHost(ctx: ctx)
    }

    /// Writes staged guest bytes to the host socket until it blocks or the ring is empty; then honours a pending
    /// half-close and announces the reopened window. A blocked socket leaves the rest in the ring with write
    /// interest on, so the window the guest sees shrinks by exactly what is held back.
    func flushToHost(ctx: UserNetContext<some UserNetHost>) {
        hostWriteStaged = false
        guard backend == .host, state != .closed, let ring = toHost else { return }
        while !ring.isEmpty {
            let chunk = ring.contiguous(from: 0, limit: ring.count)
            switch ctx.host.writeStream(token: token, chunk) {
            case .transferred(let written):
                ring.discard(written)
            case .wouldBlock, .endOfStream:
                setInterest(read: readInterest, write: true, ctx: ctx)
                return
            case .failed(let error):
                hostFailed(error, ctx: ctx)
                return
            }
        }
        ctx.receiveRings.release(ring)
        toHost = nil
        setInterest(read: readInterest, write: false, ctx: ctx)
        if shutdownAfterDrain {
            shutdownAfterDrain = false
            ctx.host.shutdownStreamWrite(token: token)
        }
        if completionPending { finishIfDrained(ctx: ctx) }
        if receiveSpace - advertisedWindow >= min(receiveCapacity / 2, 2 * guestMSS) { sendAcknowledgement(ctx: ctx) }
    }

    // MARK: Timers

    /// Drives timeouts and retransmission. Cheap when nothing is due.
    func tick(ctx: UserNetContext<some UserNetHost>) {
        switch state {
        case .closed: return
        case .connecting:
            if ctx.now >= connectDeadline {
                ctx.stats.tcpFlowsFailed += 1
                terminate(.connectFailed(0), resetGuest: true, ctx: ctx)
            }
            return
        case .timeWait:
            if ctx.now >= timeWaitDeadline { state = .closed }
            return
        default: break
        }
        // DNS-over-TCP sessions are short; do not let an abandoned one hold a flow slot for the full idle timeout.
        let idleLimit = backend == .localDNS ? min(ctx.config.tcpIdleTimeout, 30) : ctx.config.tcpIdleTimeout
        if ctx.now - lastActivity >= idleLimit {
            terminate(.idleTimeout, resetGuest: true, ctx: ctx)
            return
        }
        if ctx.now >= retransmitDeadline { retransmit(ctx: ctx) }
    }

    private func retransmit(ctx: UserNetContext<some UserNetHost>) {
        let probing = sendWindow == 0 && state != .synReceived
        if !probing { retransmits += 1 }
        guard retransmits <= Self.maximumRetransmits else {
            terminate(.retransmitTimeout, resetGuest: true, ctx: ctx)
            return
        }
        ctx.stats.tcpRetransmits += 1
        retransmitTimeout = min(retransmitTimeout * 2, probing ? 2 : Self.maximumRetransmitTimeout)
        retransmitDeadline = ctx.now + retransmitTimeout
        if state == .synReceived {
            sendSynAck(ctx: ctx)
        } else if inFlight > 0 {
            retransmitFirstSegment(ctx: ctx)
        } else if sendWindow == 0, unsent > 0 {
            sendData(size: 1, offset: 0, sequence: sendNext, push: false, ctx: ctx)  // zero-window probe
            sendNext &+= 1
        } else if finSent, !finAcknowledged {
            sendControl(.finAck, sequence: sendNext &- 1, ctx: ctx)
        } else {
            retransmitDeadline = .infinity
        }
    }

    /// Resends the oldest unacknowledged data segment.
    func retransmitFirstSegment(ctx: UserNetContext<some UserNetHost>) {
        let size = min(inFlight, guestMSS)
        guard size > 0 else { return }
        sendData(size: size, offset: 0, sequence: sendUnacknowledged, push: false, ctx: ctx)
    }
}

extension TCPFlow {
    /// Appends bytes produced locally (DNS-over-TCP responses) to the guest-bound stream and sends what fits.
    /// Returns `false` when the guest-bound buffer has no room.
    func enqueueLocalResponse(_ bytes: ByteView, ctx: UserNetContext<some UserNetHost>) -> Bool {
        guard state == .established || state == .closeWait || state == .synReceived else { return false }
        let ring = toGuest ?? ctx.sendRings.acquire()
        toGuest = ring
        guard ring.append(bytes) else { return false }
        bytesToGuest += UInt64(bytes.count)
        pump(ctx: ctx)
        return true
    }
}
