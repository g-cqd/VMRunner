import Foundation
import Testing

@testable import NetStack

/// The guest side of one TCP connection, driving a ``CoreRig`` frame by frame. Deliberately simple: it sends what the
/// test tells it to and records what the stack sends back; it never retransmits or acknowledges on its own.
struct GuestConnection {
    let rig: CoreRig
    let remote: (address: UInt32, port: UInt16)
    let port: UInt16
    var sequence: UInt32
    /// The next server sequence number the guest expects.
    var expected: UInt32 = 0
    var serverISN: UInt32 = 0
    var token: UInt64 = 0
    var window = 65_535
    var received: [UInt8] = []
    var sawFIN = false
    var sawRST = false
    var segmentSizes: [Int] = []
    /// Data segments that restated bytes the guest already had.
    var retransmissions = 0
    /// Window the stack last advertised (unscaled by the test: window scale is not negotiated unless `scale` is set).
    var advertised = 0
    var lastAcknowledgement: UInt32 = 0

    init(rig: CoreRig, to remote: (UInt32, UInt16), from port: UInt16 = 50_000, isn: UInt32 = 5_000) {
        self.rig = rig
        self.remote = (remote.0, remote.1)
        self.port = port
        sequence = isn
    }

    @discardableResult
    mutating func sendSYN(mss: Int? = 1_460, windowScale: UInt8? = nil) -> [DecodedFrame] {
        let segment = Wire.tcp(
            from: (Wire.guest, port), to: remote, sequence: sequence, flags: .syn, window: window, mss: mss, windowScale: windowScale)
        rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: remote.address, proto: IPProtocol.tcp, segment)))
        sequence &+= 1
        return collect()
    }

    /// Opens the connection fully: SYN, host connect, SYN-ACK, ACK.
    mutating func establish(mss: Int? = 1_460, windowScale: UInt8? = nil) {
        sendSYN(mss: mss, windowScale: windowScale)
        token = rig.host.streamOrder.last ?? 0
        rig.core.streamConnected(token: token, error: nil)
        collect()
        sendACK()
    }

    @discardableResult
    mutating func send(_ flags: TCPFlags, payload: [UInt8] = [], sequence override: UInt32? = nil, acknowledgement: UInt32? = nil)
        -> [DecodedFrame]
    {
        let at = override ?? sequence
        let segment = Wire.tcp(
            from: (Wire.guest, port), to: remote, sequence: at, acknowledgement: acknowledgement ?? expected, flags: flags,
            window: window, payload: payload)
        rig.send(Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: remote.address, proto: IPProtocol.tcp, segment)))
        if override == nil {
            sequence &+= UInt32(payload.count) &+ (flags.contains(.fin) ? 1 : 0)
        }
        return collect()
    }

    @discardableResult
    mutating func sendACK() -> [DecodedFrame] { send(.ack) }

    @discardableResult
    mutating func sendData(_ payload: [UInt8]) -> [DecodedFrame] { send([.ack, .psh], payload: payload) }

    /// Reads every frame the stack sent to this connection, updating what the guest knows.
    @discardableResult
    mutating func collect() -> [DecodedFrame] {
        let raw = rig.host.frames
        rig.host.frames = []
        var mine: [DecodedFrame] = []
        for bytes in raw {
            let frame = DecodedFrame(bytes)
            if frame.proto == IPProtocol.tcp, frame.destinationPort == port, frame.sourcePort == remote.port {
                mine.append(frame)
            } else {
                rig.host.frames.append(bytes)  // another connection's frame stays queued for its own collect()
            }
        }
        for frame in mine {
            #expect(frame.ipChecksumValid && frame.transportChecksumValid, "every frame the stack sends must carry valid checksums")
            if frame.flags.contains(.syn) {
                serverISN = frame.sequence
                expected = frame.sequence &+ 1
            }
            if frame.flags.contains(.rst) {
                sawRST = true
                continue
            }
            advertised = frame.window
            if frame.flags.contains(.ack) { lastAcknowledgement = frame.acknowledgement }
            if !frame.payload.isEmpty {
                if frame.sequence == expected {
                    received += frame.payload
                    expected &+= UInt32(frame.payload.count)
                    segmentSizes.append(frame.payload.count)
                } else if TCPSequence.lessThan(frame.sequence, expected) {
                    retransmissions += 1
                } else {
                    Issue.record("server data skipped ahead: sequence \(frame.sequence), expected \(expected)")
                }
            }
            if frame.flags.contains(.fin), frame.sequence &+ UInt32(frame.payload.count) == expected {
                expected &+= 1
                sawFIN = true
            }
        }
        return mine
    }

    /// Feeds bytes the "remote server" sent, and lets the stack read them.
    mutating func serverSends(_ bytes: [UInt8]) {
        rig.host.streams[token]?.incoming += bytes
        rig.core.streamReadable(token: token)
        collect()
    }

    mutating func serverCloses() {
        rig.host.streams[token]?.incomingEnds = true
        rig.core.streamReadable(token: token)
        collect()
    }
}

extension CoreRig {
    func events(_ phase: (FlowEvent.Phase) -> Bool) -> [FlowEvent] { host.events.filter { phase($0.phase) } }
}
