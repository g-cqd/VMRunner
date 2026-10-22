import Foundation

/// The real-socket implementation of ``UserNetHost``: the thin layer that turns the core's abstract requests into
/// non-blocking BSD sockets registered with the loop's kernel queue.
///
/// Because destinations are reached with ordinary host sockets, the kernel's routing table decides the path of every
/// new connection: whatever network (Wi-Fi, Ethernet, a VPN's default route) the Mac uses at the moment a flow starts
/// is the one that flow uses. Only used on the loop thread.
final class UserNetBridge: UserNetHost {
    private struct Stream {
        var descriptor: Int32
        var connecting: Bool
        var readEnabled = false
        var writeEnabled = false
    }

    private struct Datagram {
        var descriptor: Int32
        var kind: DatagramKind
    }

    let guestDescriptor: Int32
    /// Filter changes waiting for the next kernel-queue wait.
    var pendingChanges: [ReadinessChange] = []
    /// Connect failures discovered while the core was calling us; delivered once the call has returned.
    var deferredConnectFailures: [(token: UInt64, error: Int32)] = []
    private(set) var framesLostToGuest: UInt64 = 0
    /// Flow events the stream's reader had no room for (it keeps the newest 4096 and drops the oldest).
    private(set) var flowEventsDropped: UInt64 = 0
    private(set) var guestWriteEnabled = false

    private var streams: [UInt64: Stream] = [:]
    private var datagrams: [UInt64: Datagram] = [:]
    private let transmitQueue: GuestTxQueue
    private let flowEvents: AsyncStream<FlowEvent>.Continuation
    private let vpnSink: @Sendable (GuestVPNState) -> Void
    private let resolver: any HostNameResolver
    private let inbox: UserNetInbox
    private var resolutions: [UInt64: Task<Void, Never>] = [:]
    private var logLines = FlowLogThrottle()
    private let logger: any UserNetLogger

    init(
        guestDescriptor: Int32, mtu: Int, flowEvents: AsyncStream<FlowEvent>.Continuation,
        vpnSink: @escaping @Sendable (GuestVPNState) -> Void, resolver: any HostNameResolver, inbox: UserNetInbox,
        logger: any UserNetLogger = SilentUserNetLogger()
    ) {
        self.guestDescriptor = guestDescriptor
        self.flowEvents = flowEvents
        self.vpnSink = vpnSink
        self.resolver = resolver
        self.inbox = inbox
        self.logger = logger
        transmitQueue = GuestTxQueue(slotCapacity: mtu + EthernetHeader.length + 64, maximumSlots: 2_048)
        pendingChanges.reserveCapacity(64)
        pendingChanges.append(ReadinessChange(descriptor: guestDescriptor, token: 0, isRead: true, enabled: true))
    }

    // MARK: Guest link

    func sendToGuest(_ frame: ByteView) {
        if transmitQueue.isEmpty {
            switch SocketCalls.send(guestDescriptor, frame) {
            case .transferred: return
            case .wouldBlock, .endOfStream: break
            case .failed:
                framesLostToGuest += 1
                return
            }
        }
        if transmitQueue.enqueue(frame) {
            setGuestWriteInterest(true)
        } else {
            framesLostToGuest += 1
        }
    }

    /// The guest socket is writable again: send queued frames until it blocks.
    func flushTransmitQueue() {
        while let frame = transmitQueue.first() {
            switch SocketCalls.send(guestDescriptor, frame) {
            case .transferred, .failed:
                transmitQueue.dropFirst()
            case .wouldBlock, .endOfStream:
                return
            }
        }
        setGuestWriteInterest(false)
    }

    private func setGuestWriteInterest(_ enabled: Bool) {
        guard enabled != guestWriteEnabled else { return }
        guestWriteEnabled = enabled
        pendingChanges.append(ReadinessChange(descriptor: guestDescriptor, token: 0, isRead: false, enabled: enabled))
    }

    // MARK: Streams

    func openStream(token: UInt64, address: UInt32, port: UInt16) {
        guard let descriptor = SocketCalls.makeSocket(type: SOCK_STREAM) else {
            deferredConnectFailures.append((token, errno))
            return
        }
        SocketCalls.setFlag(descriptor, Int32(IPPROTO_TCP), TCP_NODELAY)
        let result = SocketCalls.connect(descriptor, address: address, port: port)
        guard result == 0 || result == EINPROGRESS else {
            SocketCalls.close(descriptor)
            deferredConnectFailures.append((token, result))
            return
        }
        streams[token] = Stream(descriptor: descriptor, connecting: true, writeEnabled: true)
        pendingChanges.append(ReadinessChange(descriptor: descriptor, token: token, isRead: false, enabled: true))
    }

    /// The kernel reported the connect finished: returns its error (`nil` on success) and leaves the stream ready for
    /// the interest the core sets next.
    func completeConnect(token: UInt64) -> Int32? {
        guard var stream = streams[token], stream.connecting else { return nil }
        let error = SocketCalls.pendingError(stream.descriptor)
        stream.connecting = false
        stream.writeEnabled = false
        streams[token] = stream
        pendingChanges.append(ReadinessChange(descriptor: stream.descriptor, token: token, isRead: false, enabled: false))
        return error == 0 ? nil : error
    }

    func isConnecting(token: UInt64) -> Bool { streams[token]?.connecting ?? false }
    func hasStream(token: UInt64) -> Bool { streams[token] != nil }
    func hasDatagram(token: UInt64) -> Bool { datagrams[token] != nil }

    func writeStream(token: UInt64, _ bytes: ByteView) -> HostIOResult {
        guard let stream = streams[token] else { return .failed(EBADF) }
        return SocketCalls.send(stream.descriptor, bytes)
    }

    func readStream(token: UInt64, into buffer: MutableByteView) -> HostIOResult {
        guard let stream = streams[token] else { return .failed(EBADF) }
        return SocketCalls.receive(stream.descriptor, into: buffer)
    }

    func shutdownStreamWrite(token: UInt64) {
        if let stream = streams[token] { SocketCalls.shutdownWrite(stream.descriptor) }
    }

    func closeStream(token: UInt64, abort: Bool) {
        guard let stream = streams.removeValue(forKey: token) else { return }
        pendingChanges.removeAll { $0.descriptor == stream.descriptor }
        SocketCalls.close(stream.descriptor, reset: abort)
    }

    func setStreamInterest(token: UInt64, read: Bool, write: Bool) {
        guard var stream = streams[token], !stream.connecting else { return }
        if read != stream.readEnabled {
            stream.readEnabled = read
            pendingChanges.append(ReadinessChange(descriptor: stream.descriptor, token: token, isRead: true, enabled: read))
        }
        if write != stream.writeEnabled {
            stream.writeEnabled = write
            pendingChanges.append(ReadinessChange(descriptor: stream.descriptor, token: token, isRead: false, enabled: write))
        }
        streams[token] = stream
    }

    // MARK: Datagrams

    func openDatagram(token: UInt64, kind: DatagramKind, address: UInt32, port: UInt16) -> Bool {
        let descriptor: Int32?
        switch kind {
        case .udp: descriptor = SocketCalls.makeSocket(type: SOCK_DGRAM)
        case .icmpEcho: descriptor = SocketCalls.makeSocket(type: SOCK_DGRAM, protocolNumber: Int32(IPPROTO_ICMP))
        }
        guard let descriptor else { return false }
        guard SocketCalls.connect(descriptor, address: address, port: kind == .udp ? port : 0) == 0 else {
            SocketCalls.close(descriptor)
            return false
        }
        datagrams[token] = Datagram(descriptor: descriptor, kind: kind)
        pendingChanges.append(ReadinessChange(descriptor: descriptor, token: token, isRead: true, enabled: true))
        return true
    }

    func writeDatagram(token: UInt64, _ bytes: ByteView) -> HostIOResult {
        guard let datagram = datagrams[token] else { return .failed(EBADF) }
        return SocketCalls.send(datagram.descriptor, bytes)
    }

    func readDatagram(token: UInt64, into buffer: MutableByteView) -> HostIOResult {
        guard let datagram = datagrams[token] else { return .failed(EBADF) }
        let result = SocketCalls.receive(datagram.descriptor, into: buffer)
        guard datagram.kind == .icmpEcho, case .transferred(let count) = result else { return result }
        // macOS hands back the IP header with the ICMP message; keep only the message.
        guard let offset = SocketCalls.icmpMessageOffset(in: buffer.readable.prefix(count)),
            let message = buffer.readable.slice(from: offset, length: count - offset), !message.isEmpty
        else { return .wouldBlock }
        buffer.copy(message, to: 0)
        return .transferred(message.count)
    }

    func closeDatagram(token: UInt64) {
        guard let datagram = datagrams.removeValue(forKey: token) else { return }
        pendingChanges.removeAll { $0.descriptor == datagram.descriptor }
        SocketCalls.close(datagram.descriptor)
    }

    // MARK: Names and observation

    func resolve(token: UInt64, name: String, recordType: UInt16) {
        let resolver = resolver
        let inbox = inbox
        resolutions[token] = Task {
            let result = await resolver.lookup(name: name, recordType: recordType)
            inbox.post(.nameResolved(token: token, result: result))
        }
    }

    func resolutionDelivered(token: UInt64) {
        resolutions[token] = nil
    }

    func publish(_ event: FlowEvent) {
        if case .dropped = flowEvents.yield(event) { flowEventsDropped += 1 }
        logFailure(of: event)
    }

    /// Logs denials and abnormal endings, one line per destination and reason per interval (``FlowLogThrottle``).
    /// Destinations are private data: address, port and name are redacted in collected logs; only the kind of event,
    /// the outcome, the reason and the count of held-back lines are public (the logger decides how each is written).
    private func logFailure(of event: FlowEvent) {
        guard let line = logLines.line(for: event) else { return }
        logger.flowFailed(summary: line.summary, held: line.held, destination: line.destination)
    }

    func publish(vpnState: GuestVPNState) {
        vpnSink(vpnState)
    }

    // MARK: Shutdown

    /// Closes every host descriptor and cancels pending lookups. The guest descriptor is closed by the loop.
    func closeAll() {
        for stream in streams.values { SocketCalls.close(stream.descriptor, reset: true) }
        for datagram in datagrams.values { SocketCalls.close(datagram.descriptor) }
        streams.removeAll()
        datagrams.removeAll()
        for task in resolutions.values { task.cancel() }
        resolutions.removeAll()
        transmitQueue.removeAll()
    }
}
