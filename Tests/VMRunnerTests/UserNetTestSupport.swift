import Foundation
import Synchronization
import Testing

@testable import VMRunner

// MARK: Reference wire encoding (independent of the production encoder: plain arrays and a naive checksum)

enum Wire {
    static let gatewayMAC = MACAddress(rawValue: 0x0200_C612_0001)
    static let guestMAC = MACAddress(rawValue: 0x0200_0000_0A0B)
    static let gateway = IPv4.make(198, 18, 0, 1)
    static let guest = IPv4.make(198, 18, 0, 2)

    static func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
    static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
    static func mac(_ address: MACAddress) -> [UInt8] { (0..<6).map { UInt8((address.rawValue >> (40 - 8 * UInt64($0))) & 0xFF) } }

    /// The textbook checksum: sum big-endian words, fold, complement.
    static func checksum(_ bytes: [UInt8], seed: UInt32 = 0) -> UInt16 {
        var sum = UInt64(seed)
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt64(bytes[index]) << 8 | UInt64(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt64(bytes[index]) << 8 }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    static func pseudoSeed(_ source: UInt32, _ destination: UInt32, _ proto: UInt8, _ length: Int) -> UInt32 {
        var sum: UInt32 = 0
        for word in [source >> 16, source & 0xFFFF, destination >> 16, destination & 0xFFFF, UInt32(proto), UInt32(length)] { sum += word }
        return sum
    }

    static func ipv4(
        from source: UInt32, to destination: UInt32, proto: UInt8, _ payload: [UInt8], identification: Int = 1,
        fragmentField: Int = 0x4000, headerChecksum: Bool = true
    ) -> [UInt8] {
        var header: [UInt8] = [0x45, 0] + be16(20 + payload.count) + be16(identification) + be16(fragmentField) + [64, proto, 0, 0]
        header += be32(source) + be32(destination)
        if headerChecksum {
            let value = checksum(header)
            header[10] = UInt8(value >> 8)
            header[11] = UInt8(value & 0xFF)
        }
        return header + payload
    }

    static func ethernet(to destination: MACAddress, from source: MACAddress, type: UInt16, _ payload: [UInt8]) -> [UInt8] {
        mac(destination) + mac(source) + be16(Int(type)) + payload
    }

    /// An Ethernet frame from the guest to the gateway carrying `ip`.
    static func guestFrame(_ ip: [UInt8]) -> [UInt8] {
        ethernet(to: gatewayMAC, from: guestMAC, type: EtherType.ipv4, ip)
    }

    static func tcp(
        from source: (UInt32, UInt16), to destination: (UInt32, UInt16), sequence: UInt32, acknowledgement: UInt32 = 0,
        flags: TCPFlags, window: Int = 65_535, mss: Int? = nil, windowScale: UInt8? = nil, payload: [UInt8] = []
    ) -> [UInt8] {
        var options: [UInt8] = []
        if let mss { options += [2, 4] + be16(mss) }
        if let windowScale { options += [1, 3, 3, windowScale] }
        while !options.count.isMultiple(of: 4) { options.append(0) }
        var segment = be16(Int(source.1)) + be16(Int(destination.1)) + be32(sequence) + be32(acknowledgement)
        segment += [UInt8((20 + options.count) / 4) << 4, flags.rawValue] + be16(window) + [0, 0, 0, 0] + options + payload
        let value = checksum(segment, seed: pseudoSeed(source.0, destination.0, IPProtocol.tcp, segment.count))
        segment[16] = UInt8(value >> 8)
        segment[17] = UInt8(value & 0xFF)
        return segment
    }

    static func udp(from source: (UInt32, UInt16), to destination: (UInt32, UInt16), _ payload: [UInt8]) -> [UInt8] {
        var datagram = be16(Int(source.1)) + be16(Int(destination.1)) + be16(8 + payload.count) + [0, 0] + payload
        let value = checksum(datagram, seed: pseudoSeed(source.0, destination.0, IPProtocol.udp, datagram.count))
        datagram[6] = UInt8((value == 0 ? 0xFFFF : value) >> 8)
        datagram[7] = UInt8((value == 0 ? 0xFFFF : value) & 0xFF)
        return datagram
    }

    static func icmpEcho(type: UInt8 = 8, identifier: Int, sequence: Int, data: [UInt8] = Array("ping".utf8)) -> [UInt8] {
        var message: [UInt8] = [type, 0, 0, 0] + be16(identifier) + be16(sequence) + data
        let value = checksum(message)
        message[2] = UInt8(value >> 8)
        message[3] = UInt8(value & 0xFF)
        return message
    }

    static func arpRequest(senderMAC: MACAddress, senderIP: UInt32, targetIP: UInt32) -> [UInt8] {
        let packet = be16(1) + be16(0x0800) + [6, 4] + be16(1) + mac(senderMAC) + be32(senderIP) + [0, 0, 0, 0, 0, 0] + be32(targetIP)
        return ethernet(to: .broadcast, from: senderMAC, type: EtherType.arp, packet)
    }

    /// A BOOTP/DHCP payload from a client.
    static func dhcp(
        type: UInt8, client: MACAddress = guestMAC, transaction: UInt32 = 0xCAFE_F00D, requested: UInt32? = nil,
        server: UInt32? = nil, clientAddress: UInt32 = 0, broadcast: Bool = true
    ) -> [UInt8] {
        var message: [UInt8] = [1, 1, 6, 0] + be32(transaction) + be16(0) + be16(broadcast ? 0x8000 : 0)
        message += be32(clientAddress) + be32(0) + be32(0) + be32(0)
        message += mac(client) + [UInt8](repeating: 0, count: 10 + 64 + 128) + [0x63, 0x82, 0x53, 0x63]
        message += [53, 1, type]
        if let requested { message += [50, 4] + be32(requested) }
        if let server { message += [54, 4] + be32(server) }
        return message + [255]
    }

    static func dnsQuery(id: Int, name: String, type: Int = 1) -> [UInt8] {
        var message = be16(id) + be16(0x0100) + be16(1) + be16(0) + be16(0) + be16(0)
        for label in name.split(separator: ".") { message += [UInt8(label.utf8.count)] + Array(label.utf8) }
        return message + [0] + be16(type) + be16(1)
    }

    /// The full Ethernet frame for a guest UDP datagram to `destination`.
    static func guestUDP(to destination: (UInt32, UInt16), from port: UInt16 = 40_000, _ payload: [UInt8]) -> [UInt8] {
        guestFrame(ipv4(from: guest, to: destination.0, proto: IPProtocol.udp, udp(from: (guest, port), to: destination, payload)))
    }
}

// MARK: Decoding what the stack sends (independent of the production parser)

struct DecodedFrame {
    var destination = MACAddress(rawValue: 0)
    var source = MACAddress(rawValue: 0)
    var etherType: UInt16 = 0
    var ipSource: UInt32?
    var ipDestination: UInt32?
    var proto: UInt8?
    var ipChecksumValid = false
    var fragmentField = 0
    /// Everything after the IPv4 header, before any transport decoding (for reassembling fragments).
    var ipPayload: [UInt8] = []
    var transportChecksumValid = false
    var sourcePort: UInt16 = 0
    var destinationPort: UInt16 = 0
    var sequence: UInt32 = 0
    var acknowledgement: UInt32 = 0
    var flags = TCPFlags()
    var window = 0
    var mss: Int?
    var windowScale: UInt8?
    /// TCP or UDP payload, or the ICMP message, or the ARP packet.
    var payload: [UInt8] = []
    var icmpType: UInt8?
    var arpOperation: Int?
    var arpSenderMAC: MACAddress?
    var arpSenderIP: UInt32?

    init(_ bytes: [UInt8]) {
        guard bytes.count >= 14 else { return }
        func word(_ array: [UInt8], _ at: Int) -> Int { Int(array[at]) << 8 | Int(array[at + 1]) }
        func mac(_ at: Int) -> MACAddress {
            MACAddress(rawValue: bytes[at..<(at + 6)].reduce(0) { ($0 << 8) | UInt64($1) })
        }
        destination = mac(0)
        source = mac(6)
        etherType = UInt16(word(bytes, 12))
        if etherType == EtherType.arp, bytes.count >= 42 {
            arpOperation = word(bytes, 20)
            arpSenderMAC = mac(22)
            arpSenderIP = bytes[28..<32].reduce(0) { ($0 << 8) | UInt32($1) }
            payload = Array(bytes[14...])
            return
        }
        guard etherType == EtherType.ipv4, bytes.count >= 34 else { return }
        let ip = Array(bytes[14...])
        let headerLength = Int(ip[0] & 0x0F) * 4
        ipChecksumValid = Wire.checksum(Array(ip[..<headerLength])) == 0
        let total = word(ip, 2)
        fragmentField = word(ip, 6)
        proto = ip[9]
        ipSource = ip[12..<16].reduce(0) { ($0 << 8) | UInt32($1) }
        ipDestination = ip[16..<20].reduce(0) { ($0 << 8) | UInt32($1) }
        let body = Array(ip[headerLength..<min(total, ip.count)])
        ipPayload = body
        guard fragmentField & 0x3FFF == 0 else { return }  // a fragment's bytes are not a transport header
        decodeTransport(body)
    }

    private mutating func decodeTransport(_ body: [UInt8]) {
        func word(_ at: Int) -> Int { Int(body[at]) << 8 | Int(body[at + 1]) }
        guard let proto, let source = ipSource, let destination = ipDestination else { return }
        switch proto {
        case IPProtocol.tcp where body.count >= 20:
            sourcePort = UInt16(word(0))
            destinationPort = UInt16(word(2))
            sequence = body[4..<8].reduce(0) { ($0 << 8) | UInt32($1) }
            acknowledgement = body[8..<12].reduce(0) { ($0 << 8) | UInt32($1) }
            let offset = Int(body[12] >> 4) * 4
            flags = TCPFlags(rawValue: body[13] & 0x1F)
            window = word(14)
            decodeOptions(Array(body[20..<offset]))
            payload = Array(body[offset...])
            transportChecksumValid = Wire.checksum(body, seed: Wire.pseudoSeed(source, destination, proto, body.count)) == 0
        case IPProtocol.udp where body.count >= 8:
            sourcePort = UInt16(word(0))
            destinationPort = UInt16(word(2))
            payload = Array(body[8...])
            transportChecksumValid = Wire.checksum(body, seed: Wire.pseudoSeed(source, destination, proto, body.count)) == 0
        case IPProtocol.icmp where body.count >= 4:
            icmpType = body[0]
            payload = body
            transportChecksumValid = Wire.checksum(body) == 0
        default:
            payload = body
        }
    }

    private mutating func decodeOptions(_ options: [UInt8]) {
        var index = 0
        while index < options.count {
            let kind = options[index]
            if kind == 0 { break }
            if kind == 1 {
                index += 1
                continue
            }
            let length = Int(options[index + 1])
            if kind == 2 { mss = Int(options[index + 2]) << 8 | Int(options[index + 3]) }
            if kind == 3 { windowScale = options[index + 2] }
            index += length
        }
    }
}

// MARK: Deterministic time

/// A clock that only moves when told to; every deadline in the core is measured against it.
final class ManualClock: Clock, @unchecked Sendable {  // all state behind `time`'s Mutex
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
        func duration(to other: Self) -> Duration { other.offset - offset }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
    }

    private let time = Mutex(Duration.zero)

    var now: Instant { Instant(offset: time.withLock { $0 }) }
    var minimumResolution: Duration { .nanoseconds(1) }

    func advance(by seconds: Double) {
        time.withLock { $0 += .seconds(seconds) }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        throw CancellationError()  // tests drive time with advance(by:); nothing sleeps on this clock
    }
}

// MARK: A recording host for driving the core without sockets

final class FakeHost: UserNetHost {
    struct Stream {
        var address: UInt32
        var port: UInt16
        var incoming: [UInt8] = []
        var incomingEnds = false
        var failure: Int32?
        var written: [UInt8] = []
        /// How many separate write calls delivered `written`.
        var writeCalls = 0
        /// Bytes the "socket" will still accept before reporting would-block.
        var capacity = Int.max
        var readInterest = false
        var writeInterest = false
        var shutDown = false
        var closed: Closure?
    }

    enum Closure {
        case graceful, aborted
    }

    struct Resolution {
        var token: UInt64
        var name: String
        var type: UInt16
    }

    struct Datagram {
        var kind: DatagramKind
        var address: UInt32
        var port: UInt16
        var incoming: [[UInt8]] = []
        var written: [[UInt8]] = []
        var closed = false
    }

    var frames: [[UInt8]] = []
    var events: [FlowEvent] = []
    var vpnStates: [GuestVPNState] = []
    var streams: [UInt64: Stream] = [:]
    var streamOrder: [UInt64] = []
    var datagrams: [UInt64: Datagram] = [:]
    var resolutions: [Resolution] = []
    var refuseDatagrams = false

    func sendToGuest(_ frame: ByteView) { frames.append(frame.array()) }

    func openStream(token: UInt64, address: UInt32, port: UInt16) {
        streams[token] = Stream(address: address, port: port)
        streamOrder.append(token)
    }

    func writeStream(token: UInt64, _ bytes: ByteView) -> HostIOResult {
        guard var stream = streams[token] else { return .failed(EBADF) }
        let taken = min(bytes.count, stream.capacity)
        guard taken > 0 else { return .wouldBlock }
        stream.written += bytes.prefix(taken).array()
        stream.writeCalls += 1
        stream.capacity = stream.capacity == .max ? .max : stream.capacity - taken
        streams[token] = stream
        return .transferred(taken)
    }

    func readStream(token: UInt64, into buffer: MutableByteView) -> HostIOResult {
        guard var stream = streams[token] else { return .failed(EBADF) }
        if let failure = stream.failure { return .failed(failure) }
        guard !stream.incoming.isEmpty else { return stream.incomingEnds ? .endOfStream : .wouldBlock }
        let count = min(buffer.count, stream.incoming.count)
        ByteView.withBytes(of: Array(stream.incoming[..<count])) { _ = buffer.copy($0, to: 0) }
        stream.incoming.removeFirst(count)
        streams[token] = stream
        return .transferred(count)
    }

    func shutdownStreamWrite(token: UInt64) { streams[token]?.shutDown = true }
    func closeStream(token: UInt64, abort: Bool) { streams[token]?.closed = abort ? .aborted : .graceful }

    func setStreamInterest(token: UInt64, read: Bool, write: Bool) {
        streams[token]?.readInterest = read
        streams[token]?.writeInterest = write
    }

    func openDatagram(token: UInt64, kind: DatagramKind, address: UInt32, port: UInt16) -> Bool {
        guard !refuseDatagrams else { return false }
        datagrams[token] = Datagram(kind: kind, address: address, port: port)
        return true
    }

    func writeDatagram(token: UInt64, _ bytes: ByteView) -> HostIOResult {
        datagrams[token]?.written.append(bytes.array())
        return .transferred(max(bytes.count, 1))
    }

    func readDatagram(token: UInt64, into buffer: MutableByteView) -> HostIOResult {
        guard var datagram = datagrams[token], !datagram.incoming.isEmpty else { return .wouldBlock }
        let next = datagram.incoming.removeFirst()
        datagrams[token] = datagram
        ByteView.withBytes(of: next) { _ = buffer.copy($0, to: 0) }
        return .transferred(next.count)
    }

    func closeDatagram(token: UInt64) { datagrams[token]?.closed = true }
    func resolve(token: UInt64, name: String, recordType: UInt16) {
        resolutions.append(Resolution(token: token, name: name, type: recordType))
    }
    func publish(_ event: FlowEvent) { events.append(event) }
    func publish(vpnState: GuestVPNState) { vpnStates.append(vpnState) }

    /// The frames sent since the last call, decoded.
    func takeFrames() -> [DecodedFrame] {
        defer { frames.removeAll() }
        return frames.map(DecodedFrame.init)
    }
}

/// The core wired to a fake host and a manual clock, with a small TCP client for the guest side.
final class CoreRig {
    let host = FakeHost()
    let clock = ManualClock()
    let core: UserNetCore<FakeHost, ManualClock>

    init(policy: NetworkPolicy = CoreRig.openPolicy, configure: (inout UserNetConfig) -> Void = { _ in }) {
        var config = UserNetConfig()
        config.initialSequenceSeed = 1_000_000
        configure(&config)
        core = UserNetCore(config: config, policy: policy, host: host, clock: clock)
    }

    /// A policy that allows loopback and private targets, which the default blocks. Test-only: the default policy
    /// denies 127.0.0.0/8, which is where the test servers live.
    static var openPolicy: NetworkPolicy {
        var policy = NetworkPolicy()
        policy.blockPrivateRanges = false
        return policy
    }

    func send(_ frame: [UInt8]) {
        ByteView.withBytes(of: frame) { core.receiveFrame($0) }
        core.endOfBatch()
    }

    func advance(_ seconds: Double) {
        clock.advance(by: seconds)
        core.tick()
    }

    @discardableResult
    func learnGuest() -> [DecodedFrame] {
        send(Wire.arpRequest(senderMAC: Wire.guestMAC, senderIP: Wire.guest, targetIP: Wire.gateway))
        return host.takeFrames()
    }
}

// MARK: Helpers

func ipv4(_ text: String) -> UInt32 {
    let parts = text.split(separator: ".").compactMap { UInt8($0) }
    return parts.count == 4 ? IPv4.make(parts[0], parts[1], parts[2], parts[3]) : 0
}

/// Pattern bytes that make misordered or corrupted relays visible.
func pattern(_ count: Int, seed: Int = 0) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31) &+ ($0 >> 8) &+ seed) }
}
