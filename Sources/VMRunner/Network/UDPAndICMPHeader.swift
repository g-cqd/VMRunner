/// A parsed UDP header and a view of its payload.
struct UDPHeader {
    static let length = 8

    let sourcePort: UInt16
    let destinationPort: UInt16
    let payload: ByteView

    /// - Parameters:
    ///   - datagram: The IP payload.
    ///   - pseudoSum: When non-`nil`, verify the checksum (a zero checksum field means "none" and passes).
    /// - Throws: ``PacketError/truncated``, ``PacketError/malformed`` for a length field outside 8...datagram size,
    ///   ``PacketError/checksum``.
    init(parsing datagram: ByteView, verifyingWith pseudoSum: UInt64? = nil) throws(PacketError) {
        sourcePort = try datagram.be16(at: 0)
        destinationPort = try datagram.be16(at: 2)
        let total = Int(try datagram.be16(at: 4))
        guard total >= Self.length, total <= datagram.count else { throw .malformed }
        if let pseudoSum, try datagram.be16(at: 6) != 0,
            InternetChecksum.finish(pseudoSum &+ datagram.prefix(total).onesComplementSum()) != 0
        {
            throw .checksum
        }
        guard let body = datagram.slice(from: Self.length, length: total - Self.length) else { throw .truncated }
        payload = body
    }

    /// Writes a UDP header; `payloadLength` bytes must follow, then ``finishChecksum(source:destination:start:writer:)``.
    static func writeHeader(sourcePort: UInt16, destinationPort: UInt16, payloadLength: Int, into writer: inout FrameWriter) {
        writer.be16(sourcePort)
        writer.be16(destinationPort)
        writer.be16(UInt16(truncatingIfNeeded: length + payloadLength))
        writer.be16(0)
    }

    /// Appends a complete datagram (header, payload, checksum) and returns the offset where it starts.
    @discardableResult
    static func append(
        from source: (address: UInt32, port: UInt16), to destination: (address: UInt32, port: UInt16), payload: ByteView,
        into writer: inout FrameWriter
    ) -> Int {
        let start = writer.count
        writeHeader(sourcePort: source.port, destinationPort: destination.port, payloadLength: payload.count, into: &writer)
        writer.bytes(payload)
        finishChecksum(source: source.address, destination: destination.address, start: start, writer: &writer)
        return start
    }

    /// Computes and stores the checksum of the datagram that starts at `start` and ends at the writer's end.
    static func finishChecksum(source: UInt32, destination: UInt32, start: Int, writer: inout FrameWriter) {
        let pseudo = InternetChecksum.pseudoHeaderSum(
            source: source, destination: destination, proto: IPProtocol.udp, length: writer.count - start)
        let value = InternetChecksum.finish(pseudo &+ writer.sum(from: start))
        writer.patchBE16(value == 0 ? 0xFFFF : value, at: start + 6)
    }
}

/// A parsed ICMP header (echo layout) and a view of the data after the 8-byte header.
struct ICMPHeader {
    static let echoRequest: UInt8 = 8
    static let echoReply: UInt8 = 0
    static let length = 8

    let type: UInt8
    let code: UInt8
    /// Identifier of an echo message (first half of "rest of header").
    let identifier: UInt16
    let sequence: UInt16
    let payload: ByteView

    /// - Throws: ``PacketError/truncated``, ``PacketError/checksum`` when `verifyChecksum` and the sum fails.
    init(parsing message: ByteView, verifyChecksum: Bool = true) throws(PacketError) {
        type = try message.u8(at: 0)
        code = try message.u8(at: 1)
        identifier = try message.be16(at: 4)
        sequence = try message.be16(at: 6)
        if verifyChecksum, InternetChecksum.checksum(message) != 0 { throw .checksum }
        guard let body = message.suffix(from: Self.length) else { throw .truncated }
        payload = body
    }
}
