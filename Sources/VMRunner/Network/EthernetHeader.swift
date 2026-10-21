/// A 48-bit Ethernet address.
struct MACAddress: Hashable, Sendable, CustomStringConvertible {
    /// The address in the low 48 bits.
    let rawValue: UInt64

    static let broadcast = Self(rawValue: 0xFFFF_FFFF_FFFF)

    init(rawValue: UInt64) {
        self.rawValue = rawValue & 0xFFFF_FFFF_FFFF
    }

    /// Whether the group bit (least significant bit of the first octet) is set: broadcast or multicast.
    var isGroup: Bool { (rawValue >> 40) & 1 == 1 }

    var description: String {
        (0..<6).map { index in
            let byte = UInt8(truncatingIfNeeded: rawValue >> (40 - 8 * UInt64(index)))
            return (byte < 16 ? "0" : "") + String(byte, radix: 16)
        }.joined(separator: ":")
    }
}

/// The EtherType values this stack distinguishes.
enum EtherType {
    static let ipv4: UInt16 = 0x0800
    static let arp: UInt16 = 0x0806
    static let ipv6: UInt16 = 0x86DD
}

/// An Ethernet II header and a view of what follows it. No VLAN tags (a tagged frame reads as an unknown EtherType).
struct EthernetHeader {
    static let length = 14

    let destination: MACAddress
    let source: MACAddress
    let etherType: UInt16
    /// Everything after the header, including any padding to the 60-byte minimum.
    let payload: ByteView

    /// - Throws: ``PacketError/truncated`` for fewer than 14 bytes.
    init(parsing frame: ByteView) throws(PacketError) {
        destination = MACAddress(rawValue: try frame.be48(at: 0))
        source = MACAddress(rawValue: try frame.be48(at: 6))
        etherType = try frame.be16(at: 12)
        guard let rest = frame.suffix(from: Self.length) else { throw .truncated }
        payload = rest
    }

    static func write(destination: MACAddress, source: MACAddress, etherType: UInt16, into writer: inout FrameWriter) {
        writer.be48(destination.rawValue)
        writer.be48(source.rawValue)
        writer.be16(etherType)
    }
}
