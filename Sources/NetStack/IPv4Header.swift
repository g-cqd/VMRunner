/// IP protocol numbers this stack looks at.
enum IPProtocol {
    static let icmp: UInt8 = 1
    static let tcp: UInt8 = 6
    static let udp: UInt8 = 17
    static let esp: UInt8 = 50
    static let ah: UInt8 = 51
}

/// Helpers for IPv4 addresses held as a host-order `UInt32` (`192.168.1.2` is `0xC0A8_0102`).
package enum IPv4 {
    static let broadcast: UInt32 = 0xFFFF_FFFF

    static func make(_ first: UInt8, _ second: UInt8, _ third: UInt8, _ fourth: UInt8) -> UInt32 {
        (UInt32(first) << 24) | (UInt32(second) << 16) | (UInt32(third) << 8) | UInt32(fourth)
    }

    static func isMulticast(_ address: UInt32) -> Bool { address >> 28 == 0xE }

    static func mask(prefixLength: Int) -> UInt32 {
        prefixLength <= 0 ? 0 : UInt32.max << UInt32(32 - min(prefixLength, 32))
    }
}

/// A parsed IPv4 header and a view of its payload.
///
/// Fragmentation policy: this stack does **not** reassemble. A fragment (more-fragments flag or a non-zero offset)
/// parses successfully with ``isFragment`` set and the caller drops it and counts it. Guests rarely fragment (TCP
/// honours the MSS we advertise, and most UDP payloads are under the MTU), and reassembly buffers are a classic
/// memory-exhaustion vector. Datagrams *to* the guest that exceed its MTU are fragmented on the way out
/// (see ``UserNetContext``).
struct IPv4Header {
    static let minimumLength = 20

    let source: UInt32
    let destination: UInt32
    let proto: UInt8
    let ttl: UInt8
    let identification: UInt16
    let dontFragment: Bool
    let isFragment: Bool
    /// The payload, cut to the header's total length (Ethernet padding removed).
    let payload: ByteView
    /// Total packet length from the header.
    let totalLength: Int

    /// Parses and validates the header.
    ///
    /// - Parameters:
    ///   - packet: The bytes after the Ethernet header.
    ///   - verifyChecksum: Whether to verify the header checksum (always cheap).
    /// - Throws: ``PacketError/truncated``, ``PacketError/unsupported`` for a version other than 4,
    ///   ``PacketError/malformed`` for impossible lengths, ``PacketError/checksum``.
    init(parsing packet: ByteView, verifyChecksum: Bool = true) throws(PacketError) {
        let versionAndLength = try packet.u8(at: 0)
        guard versionAndLength >> 4 == 4 else { throw .unsupported }
        let headerLength = Int(versionAndLength & 0x0F) * 4
        guard headerLength >= Self.minimumLength else { throw .malformed }
        let total = Int(try packet.be16(at: 2))
        guard total >= headerLength else { throw .malformed }
        guard total <= packet.count, headerLength <= packet.count else { throw .truncated }
        if verifyChecksum, let header = packet.slice(from: 0, length: headerLength), InternetChecksum.checksum(header) != 0 {
            throw .checksum
        }
        let flagsAndOffset = try packet.be16(at: 6)
        identification = try packet.be16(at: 4)
        ttl = try packet.u8(at: 8)
        proto = try packet.u8(at: 9)
        source = try packet.be32(at: 12)
        destination = try packet.be32(at: 16)
        dontFragment = flagsAndOffset & 0x4000 != 0
        isFragment = flagsAndOffset & 0x3FFF != 0
        totalLength = total
        guard let body = packet.slice(from: headerLength, length: total - headerLength) else { throw .truncated }
        payload = body
    }

    /// Writes a 20-byte header (no options) with its checksum.
    ///
    /// - Parameters:
    ///   - source: Source address.
    ///   - destination: Destination address.
    ///   - proto: The IP protocol number of the payload.
    ///   - payloadLength: Bytes that will follow the header.
    ///   - identification: The IP identification field (shared by all fragments of one packet).
    ///   - fragmentField: Flags and 13-bit offset word (`0x4000` for don't-fragment, `0x2000 | offset/8` for a
    ///     non-final fragment).
    ///   - ttl: Time to live.
    ///   - writer: Receives the 20 header bytes.
    static func write(
        source: UInt32, destination: UInt32, proto: UInt8, payloadLength: Int, identification: UInt16,
        fragmentField: UInt16 = 0x4000, ttl: UInt8 = 64, into writer: inout FrameWriter
    ) {
        let start = writer.count
        writer.u8(0x45)
        writer.u8(0)
        writer.be16(UInt16(truncatingIfNeeded: minimumLength + payloadLength))
        writer.be16(identification)
        writer.be16(fragmentField)
        writer.u8(ttl)
        writer.u8(proto)
        writer.be16(0)
        writer.be32(source)
        writer.be32(destination)
        writer.patchBE16(InternetChecksum.finish(writer.sum(from: start)), at: start + 10)
    }
}
