/// TCP flag bits.
struct TCPFlags: OptionSet, Sendable {
    let rawValue: UInt8

    static let fin = Self(rawValue: 0x01)
    static let syn = Self(rawValue: 0x02)
    static let rst = Self(rawValue: 0x04)
    static let psh = Self(rawValue: 0x08)
    static let ack = Self(rawValue: 0x10)

    // Combinations as constants: an `OptionSet` array literal allocates in an unoptimized build, and these are used
    // on the per-packet path.
    static let finAck = Self(rawValue: 0x11)
    static let synAck = Self(rawValue: 0x12)
    static let rstAck = Self(rawValue: 0x14)
    static let pushAck = Self(rawValue: 0x18)
}

/// A parsed TCP header, the options this stack uses, and a view of the payload.
struct TCPHeader {
    static let minimumLength = 20

    let sourcePort: UInt16
    let destinationPort: UInt16
    let sequence: UInt32
    let acknowledgement: UInt32
    let flags: TCPFlags
    /// The raw 16-bit window field (not yet scaled).
    let window: UInt16
    /// MSS option, if present.
    let mss: UInt16?
    /// Window-scale shift option, if present (clamped to 14 as RFC 7323 requires).
    let windowScale: UInt8?
    let payload: ByteView

    /// - Parameters:
    ///   - segment: The IP payload.
    ///   - pseudoSum: When non-`nil`, the pseudo-header sum to verify the checksum against.
    /// - Throws: ``PacketError/truncated``, ``PacketError/malformed`` (bad data offset or option length),
    ///   ``PacketError/checksum``.
    init(parsing segment: ByteView, verifyingWith pseudoSum: UInt64? = nil) throws(PacketError) {
        sourcePort = try segment.be16(at: 0)
        destinationPort = try segment.be16(at: 2)
        sequence = try segment.be32(at: 4)
        acknowledgement = try segment.be32(at: 8)
        let headerLength = Int(try segment.u8(at: 12) >> 4) * 4
        guard headerLength >= Self.minimumLength else { throw .malformed }
        guard headerLength <= segment.count else { throw .truncated }
        flags = TCPFlags(rawValue: try segment.u8(at: 13) & 0x1F)
        window = try segment.be16(at: 14)
        if let pseudoSum, InternetChecksum.finish(pseudoSum &+ segment.onesComplementSum()) != 0 { throw .checksum }
        var parsedMSS: UInt16?
        var parsedScale: UInt8?
        var offset = Self.minimumLength
        while offset < headerLength {
            let kind = try segment.u8(at: offset)
            if kind == 0 { break }
            if kind == 1 {
                offset += 1
                continue
            }
            let length = Int(try segment.u8(at: offset + 1))
            guard length >= 2, offset + length <= headerLength else { throw .malformed }
            if kind == 2, length == 4 { parsedMSS = try segment.be16(at: offset + 2) }
            if kind == 3, length == 3 { parsedScale = min(try segment.u8(at: offset + 2), 14) }
            offset += length
        }
        mss = parsedMSS
        windowScale = parsedScale
        guard let body = segment.suffix(from: headerLength) else { throw .truncated }
        payload = body
    }

    /// Sequence space this segment occupies: payload bytes plus one each for SYN and FIN.
    var sequenceLength: UInt32 {
        UInt32(truncatingIfNeeded: payload.count) &+ (flags.contains(.syn) ? 1 : 0) &+ (flags.contains(.fin) ? 1 : 0)
    }
}

/// Options on a segment we send. Only SYN-ACKs carry any.
struct TCPSendOptions {
    var mss: UInt16?
    var windowScale: UInt8?

    static let none = Self()

    /// Length of the option block, padded to a multiple of four.
    var encodedLength: Int {
        ((mss == nil ? 0 : 4) + (windowScale == nil ? 0 : 4) + 3) & ~3
    }

    func write(into writer: inout FrameWriter) {
        if let mss {
            writer.u8(2)
            writer.u8(4)
            writer.be16(mss)
        }
        if let windowScale {
            writer.u8(1)  // NOP pads the 3-byte option to a word
            writer.u8(3)
            writer.u8(3)
            writer.u8(windowScale)
        }
    }
}
