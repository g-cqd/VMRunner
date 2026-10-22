/// An ARP packet for Ethernet and IPv4 (RFC 826), the only kind that exists on this link.
struct ARPPacket {
    static let length = 28
    static let request: UInt16 = 1
    static let reply: UInt16 = 2

    let operation: UInt16
    let senderMAC: MACAddress
    let senderIP: UInt32
    let targetMAC: MACAddress
    let targetIP: UInt32

    init(operation: UInt16, senderMAC: MACAddress, senderIP: UInt32, targetMAC: MACAddress, targetIP: UInt32) {
        self.operation = operation
        self.senderMAC = senderMAC
        self.senderIP = senderIP
        self.targetMAC = targetMAC
        self.targetIP = targetIP
    }

    /// - Throws: ``PacketError/truncated``; ``PacketError/unsupported`` for any hardware or protocol type other than
    ///   Ethernet and IPv4.
    init(parsing payload: ByteView) throws(PacketError) {
        guard try payload.be16(at: 0) == 1, try payload.be16(at: 2) == EtherType.ipv4,
            try payload.u8(at: 4) == 6, try payload.u8(at: 5) == 4
        else { throw .unsupported }
        operation = try payload.be16(at: 6)
        senderMAC = MACAddress(rawValue: try payload.be48(at: 8))
        senderIP = try payload.be32(at: 14)
        targetMAC = MACAddress(rawValue: try payload.be48(at: 18))
        targetIP = try payload.be32(at: 24)
    }

    func write(into writer: inout FrameWriter) {
        writer.be16(1)
        writer.be16(EtherType.ipv4)
        writer.u8(6)
        writer.u8(4)
        writer.be16(operation)
        writer.be48(senderMAC.rawValue)
        writer.be32(senderIP)
        writer.be48(targetMAC.rawValue)
        writer.be32(targetIP)
    }
}
