import Foundation
import Testing

@testable import NetStack

/// The guest end of the datagram socket pair: sends and receives whole Ethernet frames with timeouts.
struct GuestLink {
    let descriptor: Int32
    private let buffer = RawBuffer(capacity: 65_600)

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func send(_ frame: [UInt8]) {
        ByteView.withBytes(of: frame) { view in
            while true {
                switch SocketCalls.send(descriptor, view) {
                case .wouldBlock: _ = waitReadable(timeout: 0.001, forWriting: true)
                default: return
                }
            }
        }
    }

    /// The next frame, or `nil` if none arrives within `timeout` seconds.
    func receive(timeout: TimeInterval) -> [UInt8]? {
        guard waitReadable(timeout: timeout, forWriting: false) else { return nil }
        guard case .transferred(let count) = SocketCalls.receive(descriptor, into: buffer.mutableView) else { return nil }
        return buffer.view(length: count).array()
    }

    /// Waits until a frame can be read (without reading it).
    func waitUntilReadable(timeout: TimeInterval) -> Bool {
        waitReadable(timeout: timeout, forWriting: false)
    }

    private func waitReadable(timeout: TimeInterval, forWriting: Bool) -> Bool {
        var request = pollfd(fd: descriptor, events: Int16(forWriting ? POLLOUT : POLLIN), revents: 0)
        let ready = unsafe poll(&request, 1, Int32(max(timeout, 0) * 1_000))
        return ready > 0
    }
}

/// One guest TCP connection's state. Plain data; the harness drives it.
final class GuestTCP {
    let localPort: UInt16
    let remote: (address: UInt32, port: UInt16)
    var sequence: UInt32
    var unacknowledged: UInt32
    var expected: UInt32 = 0
    var peerWindow = 65_535
    var peerShift = 0
    var mss = 1_460
    var received: [UInt8] = []
    var consumed = 0
    var connected = false
    var finReceived = false
    var finSent = false
    var finAcknowledged = false
    var reset = false
    var pendingAcknowledgements = 0

    init(localPort: UInt16, remote: (UInt32, UInt16), isn: UInt32) {
        self.localPort = localPort
        self.remote = (remote.0, remote.1)
        sequence = isn
        unacknowledged = isn
    }

    var available: Int { received.count - consumed }
}

/// A scripted guest: does DHCP and ARP, then TCP, UDP, ICMP and DNS over the datagram link to a real stack. Single
/// threaded and synchronous; every wait is bounded by a timeout, none is a fixed sleep.
final class GuestHarness {
    let link: GuestLink
    var address: UInt32 = 0
    var sockets: [UInt16: GuestTCP] = [:]
    var udpInbox: [UInt16: [DecodedFrame]] = [:]
    var icmpInbox: [DecodedFrame] = []
    var dhcpInbox: [DecodedFrame] = []
    var framesSeen = 0
    private var nextPort: UInt16 = 42_000
    private var nextIdentification = 1
    private var nextISN: UInt32 = 100_000

    init(link: GuestLink) {
        self.link = link
    }

    // MARK: Frame pump

    /// Processes at most one incoming frame. Flushes delayed ACKs before blocking.
    @discardableResult
    func pump(timeout: TimeInterval) -> Bool {
        var frame = link.receive(timeout: 0)
        if frame == nil {
            flushAcknowledgements()
            frame = link.receive(timeout: timeout)
        }
        guard let frame else { return false }
        framesSeen += 1
        dispatch(DecodedFrame(frame))
        return true
    }

    /// Pumps until `condition` holds or `timeout` passes. Returns whether it held.
    @discardableResult
    func pump(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            pump(timeout: min(remaining, 0.05))
        }
        return true
    }

    private func dispatch(_ frame: DecodedFrame) {
        guard frame.etherType == EtherType.ipv4, let proto = frame.proto else { return }
        switch proto {
        case IPProtocol.tcp: receiveTCP(frame)
        case IPProtocol.udp:
            if frame.destinationPort == 68 { dhcpInbox.append(frame) } else { udpInbox[frame.destinationPort, default: []].append(frame) }
        case IPProtocol.icmp: icmpInbox.append(frame)
        default: break
        }
    }

    func flushAcknowledgements() {
        for socket in sockets.values where socket.pendingAcknowledgements > 0 { sendSegment(socket, .ack) }
    }

    // MARK: Addressing

    func acquireLease() throws {
        let discover = Wire.dhcp(type: 1)
        sendBroadcastUDP(discover)
        let offer = try #require(waitForDHCP(), "no DHCP offer")
        let offered = offer.payload[16..<20].reduce(0) { ($0 << 8) | UInt32($1) }
        sendBroadcastUDP(Wire.dhcp(type: 3, requested: offered, server: Wire.gateway))
        let ack = try #require(waitForDHCP(), "no DHCP ack")
        #expect(ack.payload[240 + 2] == 5 || ack.payload.contains(5))
        address = offered
    }

    private func waitForDHCP() -> DecodedFrame? {
        pump(timeout: 2) { !dhcpInbox.isEmpty }
        return dhcpInbox.isEmpty ? nil : dhcpInbox.removeFirst()
    }

    private func sendBroadcastUDP(_ payload: [UInt8]) {
        let udp = Wire.udp(from: (0, 68), to: (IPv4.broadcast, 67), payload)
        let ip = Wire.ipv4(from: 0, to: IPv4.broadcast, proto: IPProtocol.udp, udp)
        link.send(Wire.ethernet(to: .broadcast, from: Wire.guestMAC, type: EtherType.ipv4, ip))
    }

    func resolveGateway() throws {
        link.send(Wire.arpRequest(senderMAC: Wire.guestMAC, senderIP: address, targetIP: Wire.gateway))
        var reply: DecodedFrame?
        let deadline = Date.now.addingTimeInterval(2)
        while reply == nil, Date.now < deadline, let raw = link.receive(timeout: 0.05) {
            let decoded = DecodedFrame(raw)
            if decoded.etherType == EtherType.arp { reply = decoded }
        }
        let arp = try #require(reply, "no ARP reply")
        #expect(arp.arpSenderMAC == Wire.gatewayMAC)
    }

    /// DHCP then ARP, as a booting guest would.
    func boot() throws {
        try acquireLease()
        try resolveGateway()
    }

    // MARK: IP sending

    private func sendIP(to destination: UInt32, proto: UInt8, _ payload: [UInt8]) {
        nextIdentification += 1
        link.send(Wire.guestFrame(Wire.ipv4(from: address, to: destination, proto: proto, payload, identification: nextIdentification)))
    }

    // MARK: UDP and ICMP

    func sendUDP(to destination: (UInt32, UInt16), from port: UInt16 = 40_000, _ payload: [UInt8]) {
        sendIP(to: destination.0, proto: IPProtocol.udp, Wire.udp(from: (address, port), to: destination, payload))
    }

    func receiveUDP(on port: UInt16, timeout: TimeInterval = 3) -> DecodedFrame? {
        pump(timeout: timeout) { !(udpInbox[port] ?? []).isEmpty }
        return (udpInbox[port] ?? []).isEmpty ? nil : udpInbox[port]?.removeFirst()
    }

    func ping(_ destination: UInt32, identifier: Int, sequence: Int = 1) {
        sendIP(to: destination, proto: IPProtocol.icmp, Wire.icmpEcho(identifier: identifier, sequence: sequence))
    }

    func receivePingReply(timeout: TimeInterval = 3) -> DecodedFrame? {
        pump(timeout: timeout) { !icmpInbox.isEmpty }
        return icmpInbox.isEmpty ? nil : icmpInbox.removeFirst()
    }

    /// Asks `server` (the gateway by default) for `name`; returns the response code and A records.
    func resolve(_ name: String, type: Int = 1, server: UInt32 = Wire.gateway, timeout: TimeInterval = 3) -> (
        code: Int, addresses: [UInt32]
    )? {
        nextPort += 1
        let port = nextPort
        sendUDP(to: (server, 53), from: port, Wire.dnsQuery(id: Int(port), name: name, type: type))
        guard let reply = receiveUDP(on: port, timeout: timeout), reply.payload.count >= 12 else { return nil }
        let answers = Int(reply.payload[6]) << 8 | Int(reply.payload[7])
        var addresses: [UInt32] = []
        if answers > 0, reply.payload.count >= 4 * answers {
            addresses = [reply.payload.suffix(4).reduce(0) { ($0 << 8) | UInt32($1) }]
        }
        return (Int(reply.payload[3] & 0x0F), addresses)
    }

    /// Like ``resolve(_:type:server:timeout:)`` but fails the test when no answer arrives.
    func mustResolve(_ name: String, type: Int = 1, server: UInt32 = Wire.gateway) throws -> (code: Int, addresses: [UInt32]) {
        try #require(resolve(name, type: type, server: server), "no DNS answer for \(name)")
    }

    // MARK: TCP

    /// Opens a connection. `nil` if the stack refuses it (RST) or does not answer in time.
    func connect(to remote: (UInt32, UInt16), mss: Int = 1_460, timeout: TimeInterval = 3) -> GuestTCP? {
        nextPort += 1
        nextISN &+= 500_000
        let socket = GuestTCP(localPort: nextPort, remote: remote, isn: nextISN)
        sockets[socket.localPort] = socket
        sendSegment(socket, .syn, mss: mss, windowScale: 7)
        socket.sequence &+= 1
        pump(timeout: timeout) { socket.connected || socket.reset }
        guard socket.connected else {
            sockets[socket.localPort] = nil
            return nil
        }
        return socket
    }

    func sendSegment(
        _ socket: GuestTCP, _ flags: TCPFlags, payload: [UInt8] = [], mss: Int? = nil, windowScale: UInt8? = nil,
        sequence override: UInt32? = nil
    ) {
        let segment = Wire.tcp(
            from: (address, socket.localPort), to: socket.remote, sequence: override ?? socket.sequence,
            acknowledgement: socket.expected, flags: flags.union(socket.connected || !flags.contains(.syn) ? .ack : []), window: 65_535,
            mss: mss, windowScale: windowScale, payload: payload)
        socket.pendingAcknowledgements = 0
        sendIP(to: socket.remote.address, proto: IPProtocol.tcp, flags.contains(.syn) ? withoutAck(segment) : segment)
    }

    private func withoutAck(_ segment: [UInt8]) -> [UInt8] { segment }

    private func receiveTCP(_ frame: DecodedFrame) {
        guard let socket = sockets[frame.destinationPort], frame.sourcePort == socket.remote.port else { return }
        if frame.flags.contains(.rst) {
            socket.reset = true
            return
        }
        if frame.flags.contains(.syn) {
            socket.expected = frame.sequence &+ 1
            socket.peerShift = Int(frame.windowScale ?? 0)
            socket.mss = min(frame.mss ?? 536, 65_000)
            socket.unacknowledged = frame.acknowledgement
            socket.peerWindow = frame.window
            socket.connected = true
            sendSegment(socket, .ack)
            return
        }
        if frame.flags.contains(.ack), TCPSequence.greaterThan(frame.acknowledgement, socket.unacknowledged) {
            socket.unacknowledged = frame.acknowledgement
            if socket.finSent, frame.acknowledgement == socket.sequence { socket.finAcknowledged = true }
        }
        socket.peerWindow = frame.window << socket.peerShift
        guard !frame.payload.isEmpty || frame.flags.contains(.fin) else { return }
        if frame.sequence == socket.expected {
            socket.received += frame.payload
            socket.expected &+= UInt32(frame.payload.count)
            if frame.flags.contains(.fin) {
                socket.expected &+= 1
                socket.finReceived = true
                sendSegment(socket, .ack)
                return
            }
            socket.pendingAcknowledgements += 1
            if socket.pendingAcknowledgements >= 2 { sendSegment(socket, .ack) }
        } else {
            sendSegment(socket, .ack)  // duplicate or out of order: re-state what we have
        }
    }

    /// Sends all of `bytes`, respecting the stack's window. `false` on reset or timeout.
    @discardableResult
    func send(_ socket: GuestTCP, _ bytes: [UInt8], timeout: TimeInterval = 20) -> Bool {
        var offset = 0
        let deadline = Date.now.addingTimeInterval(timeout)
        while offset < bytes.count {
            if socket.reset || Date.now > deadline { return false }
            let inFlight = TCPSequence.distance(from: socket.unacknowledged, to: socket.sequence)
            let room = socket.peerWindow - inFlight
            guard room > 0 else {
                pump(timeout: 0.05)
                continue
            }
            let size = min(room, socket.mss, bytes.count - offset)
            sendSegment(socket, [.ack, .psh], payload: Array(bytes[offset..<(offset + size)]))
            socket.sequence &+= UInt32(size)
            offset += size
            while link.receive(timeout: 0).map({ dispatch(DecodedFrame($0)) }) != nil {}
        }
        return true
    }

    /// Waits for `count` bytes (or end of stream, or reset) and returns what has arrived, consuming it.
    func receive(_ socket: GuestTCP, count: Int, timeout: TimeInterval = 10) -> [UInt8] {
        pump(timeout: timeout) { socket.available >= count || socket.finReceived || socket.reset }
        let end = min(socket.consumed + count, socket.received.count)
        defer { socket.consumed = end }
        return Array(socket.received[socket.consumed..<end])
    }

    /// Reads until the stack closes the connection (FIN) or resets it.
    func receiveToEnd(_ socket: GuestTCP, timeout: TimeInterval = 15) -> [UInt8] {
        pump(timeout: timeout) { socket.finReceived || socket.reset }
        defer { socket.consumed = socket.received.count }
        return Array(socket.received[socket.consumed...])
    }

    /// Half-close: sends FIN and waits for its acknowledgement.
    func shutdownWrite(_ socket: GuestTCP, timeout: TimeInterval = 5) {
        guard !socket.finSent else { return }
        sendSegment(socket, [.fin, .ack])
        socket.sequence &+= 1
        socket.finSent = true
        pump(timeout: timeout) { socket.finAcknowledged || socket.reset }
    }

    func abort(_ socket: GuestTCP) {
        sendSegment(socket, [.rst, .ack])
        socket.reset = true
    }
}
