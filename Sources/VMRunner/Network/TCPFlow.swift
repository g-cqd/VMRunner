import Foundation

/// One guest TCP connection, terminated here and relayed to a host socket (or, for DNS over TCP to the gateway, to the
/// built-in resolver).
///
/// ## Role
/// The stack plays the server to the guest's client, speaking as the destination address the guest chose. The
/// guest handshake completes only after the host connection has succeeded, so a refused or unreachable destination
/// shows up to the guest as RST, not as a connection that opens and then dies.
///
/// ## Reliability model
/// The guest link is a local datagram socket: it does not reorder, and it loses frames only when a socket buffer
/// overflows. So the receive side accepts in-order data only (anything else draws a duplicate ACK and the guest
/// retransmits), and the send side keeps unacknowledged bytes in a ring and retransmits on a timeout (doubling,
/// 250 ms to 8 s) or after three duplicate ACKs. There is no congestion control and no SACK or timestamps option
/// is echoed: the path is a memory-speed link, and in-flight data is bounded by the ring and the guest's window.
///
/// ## Back-pressure
/// - Guest to host: data is written to the host socket directly; whatever the socket will not take goes to a
///   ring of `tcpReceiveBuffer` bytes, and the window advertised to the guest shrinks by exactly that much.
/// - Host to guest: socket data is read straight into a ring of `tcpSendBuffer` bytes that holds it until the guest
///   acknowledges it. When the ring is full, reading from the socket is switched off (so the kernel's buffers and
///   the peer's TCP window push back) and switched on again once a quarter is free.
///
/// Rings are borrowed from pools only while they hold data. All methods run on the core's single thread.
final class TCPFlow {
    enum State: UInt8 {
        /// SYN received; the host connection is being established. Nothing has been sent to the guest.
        case connecting
        /// SYN-ACK sent; waiting for the guest's ACK.
        case synReceived
        case established
        /// The guest sent FIN; the host may still be sending.
        case closeWait
        /// We sent FIN (host side finished) and it is not yet acknowledged.
        case finWait1
        case finWait2
        /// Both sides sent FIN; ours is not yet acknowledged.
        case closing
        case lastAck
        /// Fully finished; the flow lingers briefly to re-acknowledge a retransmitted FIN.
        case timeWait
        case closed
    }

    enum Backend {
        /// Relayed to a host socket.
        case host
        /// Terminated locally: DNS over TCP to the gateway.
        case localDNS
    }

    static let initialRetransmitTimeout: TimeInterval = 0.25
    static let maximumRetransmitTimeout: TimeInterval = 8
    static let timeWaitDuration: TimeInterval = 2
    static let maximumRetransmits = 10

    let token: UInt64
    let key: FlowKey
    let backend: Backend
    let destinationName: String?
    let openedAt: TimeInterval
    var state = State.connecting
    var lastActivity: TimeInterval

    // Negotiated at the handshake.
    let guestMSS: Int
    /// Shift applied to windows the guest advertises (0 without the window-scale option).
    let guestWindowShift: UInt8
    /// Shift we apply to the windows we advertise; `nil` when the guest did not offer window scaling.
    let ownWindowShift: UInt8?
    let receiveCapacity: Int
    let sendCapacity: Int
    let connectDeadline: TimeInterval

    // Guest to host.
    var receiveNext: UInt32
    /// Guest bytes not yet written to the host socket; for a `localDNS` flow, the bytes of queries the resolver front end
    /// has not consumed yet (at most ``dnsInboxLimit``).
    var toHost: ByteRing?
    var shutdownAfterDrain = false
    var guestFinReceived = false
    /// Both FINs are exchanged but guest data is still waiting for the host socket; finish once it drains.
    var completionPending = false
    var unacknowledgedSegments = 0
    /// Guest bytes are waiting in ``toHost`` for the end-of-batch write.
    var hostWriteStaged = false
    /// Whether the core already lists this flow for end-of-batch work (so it is listed once per batch).
    var batchEndQueued = false
    var advertisedWindow = 0

    // Host to guest.
    let initialSequence: UInt32
    var sendUnacknowledged: UInt32
    var sendNext: UInt32
    var sendWindow: Int
    var toGuest: ByteRing?
    var hostFinished = false
    var finSent = false
    var finAcknowledged = false
    var duplicateAcknowledgements = 0

    // Timers and accounting.
    var retransmitTimeout = TCPFlow.initialRetransmitTimeout
    var retransmitDeadline = TimeInterval.infinity
    var retransmits = 0
    var timeWaitDeadline = TimeInterval.infinity
    var bytesToHost: UInt64 = 0
    var bytesToGuest: UInt64 = 0
    var readInterest = false
    var writeInterest = false
    private(set) var closedReported: Bool

    init(
        token: UInt64, key: FlowKey, syn: TCPHeader, name: String?, backend: Backend, initialSequence: UInt32,
        ctx: UserNetContext<some UserNetHost>
    ) {
        self.token = token
        self.key = key
        self.backend = backend
        destinationName = name
        closedReported = backend == .localDNS  // local DNS sessions are reported as DNS events, not flows
        openedAt = ctx.now
        lastActivity = ctx.now
        self.initialSequence = initialSequence
        sendUnacknowledged = initialSequence
        sendNext = initialSequence
        receiveNext = syn.sequence &+ 1
        guestMSS = max(min(Int(syn.mss ?? 536), ctx.config.mtu - 40), 64)
        guestWindowShift = syn.windowScale ?? 0
        sendWindow = Int(syn.window)
        receiveCapacity = ctx.config.tcpReceiveBuffer
        sendCapacity = ctx.config.tcpSendBuffer
        connectDeadline = ctx.now + ctx.config.tcpConnectTimeout
        if syn.windowScale != nil {
            var shift: UInt8 = 0
            while (ctx.config.tcpReceiveBuffer >> Int(shift)) > 65_535 { shift += 1 }
            ownWindowShift = shift
        } else {
            ownWindowShift = nil
        }
    }

    // MARK: Derived values

    var isFinished: Bool { state == .closed }
    var remote: (address: UInt32, port: UInt16) { (key.remoteAddress, key.remotePort) }

    /// Bytes of host data held, sent or not.
    var heldToGuest: Int { toGuest?.count ?? 0 }
    /// Data bytes sent and not yet acknowledged (excludes a sent FIN).
    var inFlight: Int {
        let outstanding = TCPSequence.distance(from: sendUnacknowledged, to: sendNext)
        return state == .synReceived ? 0 : outstanding - (finSent && !finAcknowledged ? 1 : 0)
    }
    var unsent: Int { max(heldToGuest - inFlight, 0) }

    /// The largest DNS query message a `localDNS` flow accepts. A real query is a few hundred bytes (header, one
    /// question, perhaps an EDNS option); a longer length prefix is not a query and resets the connection.
    static let maximumDNSQuery = 4_096
    /// What a `localDNS` flow buffers: two maximal framed queries, so the guest may pipeline a little.
    static let dnsInboxLimit = 2 * (2 + maximumDNSQuery)

    /// How many more bytes the guest may send: the free part of the buffer, which for DNS is the small inbox.
    var receiveSpace: Int {
        (backend == .localDNS ? min(receiveCapacity, Self.dnsInboxLimit) : receiveCapacity) - (toHost?.count ?? 0)
    }

    /// The window field for the next segment, and the value remembered as "advertised".
    func currentWindowField() -> UInt16 {
        let scaled = receiveSpace >> Int(ownWindowShift ?? 0)
        return UInt16(clamping: min(max(scaled, 0), 65_535))
    }

    // MARK: Sending helpers

    func sendControl(_ flags: TCPFlags, sequence: UInt32? = nil, ctx: UserNetContext<some UserNetHost>) {
        let field = currentWindowField()
        advertisedWindow = Int(field) << Int(ownWindowShift ?? 0)
        ctx.sendTCP(
            remote: remote, guestPort: key.guestPort, sequence: sequence ?? sendNext, acknowledgement: receiveNext, flags: flags,
            window: field)
    }

    func sendAcknowledgement(ctx: UserNetContext<some UserNetHost>) {
        unacknowledgedSegments = 0
        sendControl(.ack, ctx: ctx)
    }

    /// Sends a reset to the guest in the sequence space of this connection.
    func sendReset(ctx: UserNetContext<some UserNetHost>) {
        ctx.sendTCP(
            remote: remote, guestPort: key.guestPort, sequence: sendNext, acknowledgement: receiveNext, flags: .rstAck, window: 0)
    }

    func sendSynAck(ctx: UserNetContext<some UserNetHost>) {
        let field = currentWindowField()
        advertisedWindow = Int(field) << Int(ownWindowShift ?? 0)
        ctx.sendTCP(
            remote: remote, guestPort: key.guestPort, sequence: initialSequence, acknowledgement: receiveNext, flags: .synAck,
            window: field, options: TCPSendOptions(mss: UInt16(ctx.config.mtu - 40), windowScale: ownWindowShift))
    }

    // MARK: Interest bookkeeping

    func setInterest(read: Bool, write: Bool, ctx: UserNetContext<some UserNetHost>) {
        guard backend == .host, state != .closed, state != .timeWait else { return }
        guard read != readInterest || write != writeInterest else { return }
        readInterest = read
        writeInterest = write
        ctx.host.setStreamInterest(token: token, read: read, write: write)
    }

    // MARK: Lifecycle

    /// Publishes the one `closed` event of this flow.
    func reportClosed(_ reason: FlowCloseReason, ctx: UserNetContext<some UserNetHost>) {
        guard !closedReported else { return }
        closedReported = true
        ctx.host.publish(
            FlowEvent(
                flowID: token, transport: .tcp, phase: .closed(reason), remote: remote, name: destinationName, time: ctx.now,
                bytesToHost: bytesToHost, bytesToGuest: bytesToGuest, duration: ctx.now - openedAt))
    }

    func reportOpened(ctx: UserNetContext<some UserNetHost>) {
        guard backend == .host else { return }
        ctx.host.publish(
            FlowEvent(flowID: token, transport: .tcp, phase: .opened, remote: remote, name: destinationName, time: ctx.now))
    }

    /// Ends the flow now. `resetGuest` sends RST to the guest; the host socket is aborted when `abortHost`.
    func terminate(
        _ reason: FlowCloseReason, resetGuest: Bool, abortHost: Bool = true, ctx: UserNetContext<some UserNetHost>
    ) {
        guard state != .closed else { return }
        if resetGuest { sendReset(ctx: ctx) }
        reportClosed(reason, ctx: ctx)
        releaseResources(abortHost: abortHost, ctx: ctx)
        state = .closed
    }

    /// Both FINs have been exchanged. Finishes now, unless guest data is still waiting for the host socket (a DNS flow
    /// has no host socket: what is left in its inbox is a query that never completed).
    func finishIfDrained(ctx: UserNetContext<some UserNetHost>) {
        guard backend == .localDNS || (toHost?.isEmpty ?? true) else {
            completionPending = true
            return
        }
        completionPending = false
        if state == .lastAck {
            terminate(.finished, resetGuest: false, abortHost: false, ctx: ctx)
        } else {
            completeNormally(ctx: ctx)
        }
    }

    /// Reports, frees buffers, and lingers briefly as a tombstone.
    private func completeNormally(ctx: UserNetContext<some UserNetHost>) {
        reportClosed(.finished, ctx: ctx)
        releaseResources(abortHost: false, ctx: ctx)
        state = .timeWait
        timeWaitDeadline = ctx.now + Self.timeWaitDuration
        retransmitDeadline = .infinity
    }

    private func releaseResources(abortHost: Bool, ctx: UserNetContext<some UserNetHost>) {
        if backend == .host { ctx.host.closeStream(token: token, abort: abortHost) }
        readInterest = false
        writeInterest = false
        if let ring = toGuest { ctx.sendRings.release(ring) }
        if let ring = toHost { ctx.receiveRings.release(ring) }
        toGuest = nil
        toHost = nil
        retransmitDeadline = .infinity
    }
}
