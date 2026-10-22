import Foundation

/// A recognized shape, and whether it only counts toward a peer that already showed an anchor signature.
struct GuestVPNMatch: Sendable, Hashable {
    let signature: GuestVPNSignature
    let needsAnchor: Bool
}

/// Bounds-checked big-endian reads over a payload view. Every read returns `nil` instead of trapping.
struct GuestVPNBytes {
    private let view: ByteView

    init(_ view: ByteView) { self.view = view }

    var count: Int { view.count }

    func byte(_ offset: Int) -> UInt8? { view[offset] }

    func u16(_ offset: Int) -> UInt16? { try? view.be16(at: offset) }

    func u32(_ offset: Int) -> UInt32? { try? view.be32(at: offset) }

    /// Whether the `length` bytes at `offset` exist and are not all zero.
    func hasNonZero(at offset: Int, length: Int) -> Bool {
        guard length > 0, offset >= 0, offset + length <= view.count else { return false }
        for index in offset..<(offset + length) where (view[index] ?? 0) != 0 { return true }
        return false
    }

    func dropping(_ prefix: Int) -> Self {
        Self(view.suffix(from: min(max(prefix, 0), view.count)) ?? .empty)
    }
}

/// Pure packet-shape recognition for ``GuestVPNDetector``. Each recognizer checks several independent header fields
/// so that random or unrelated traffic rarely matches; none of them keeps state.
enum GuestVPNMatcher {
    /// The signature a packet matches, if any. At most one matches; transports are tried in a fixed order.
    static func match(_ packet: GuestPacketObservation) -> GuestVPNMatch? {
        let bytes = GuestVPNBytes(packet.payload)
        switch packet.transport {
        case .udp(let source, let destination):
            return matchUDP(bytes, source: source, destination: destination)
        case .tcp(let source, let destination):
            if source == 1723 || destination == 1723 { return pptpControl(bytes).map { GuestVPNMatch(signature: $0, needsAnchor: false) } }
            return openVPN(bytes.stripTCPFraming(), port1194: source == 1194 || destination == 1194)
        case .ipProtocol(let number):
            return matchIPProtocol(bytes, number: number)
        }
    }

    private static func matchUDP(_ bytes: GuestVPNBytes, source: UInt16, destination: UInt16) -> GuestVPNMatch? {
        // No array of ports: this runs for every guest UDP datagram and must not allocate.
        func involves(_ port: UInt16) -> Bool { source == port || destination == port }
        if involves(500) || involves(4500) {
            if let ike = ike(bytes, onNATTPort: involves(4500)) { return ike }
        }
        if involves(1701), let signature = l2tp(bytes) { return GuestVPNMatch(signature: signature, needsAnchor: false) }
        if let signature = wireGuard(bytes) { return GuestVPNMatch(signature: signature, needsAnchor: false) }
        return openVPN(bytes, port1194: involves(1194))
    }

    private static func matchIPProtocol(_ bytes: GuestVPNBytes, number: UInt8) -> GuestVPNMatch? {
        let signature: GuestVPNSignature?
        switch number {
        case 50: signature = bytes.count >= 8 && bytes.hasNonZero(at: 0, length: 4) ? .esp : nil
        case 51: signature = bytes.count >= 12 && bytes.hasNonZero(at: 4, length: 4) ? .ah : nil
        case 47: signature = enhancedGRE(bytes) ? .greEnhanced : nil
        default: signature = nil
        }
        return signature.map { GuestVPNMatch(signature: $0, needsAnchor: false) }
    }
}

extension GuestVPNBytes {
    /// OpenVPN over TCP prefixes each packet with its 2-byte length. Only a segment that is exactly one packet is
    /// recognized (what the first control packet of a connection looks like); anything else yields no bytes.
    fileprivate func stripTCPFraming() -> Self {
        guard let length = u16(0), Int(length) == count - 2 else { return dropping(count) }
        return dropping(2)
    }
}

extension GuestVPNMatcher {
    /// WireGuard messages start with a type byte 1...4 and three zero reserved bytes; the sizes of types 1-3 are fixed
    /// and a transport message (type 4) is a 32-byte header-plus-tag around a payload padded to 16 bytes.
    fileprivate static func wireGuard(_ bytes: GuestVPNBytes) -> GuestVPNSignature? {
        guard let type = bytes.byte(0), bytes.u32(0).map({ $0 & 0x00FF_FFFF }) == 0 else { return nil }
        switch (type, bytes.count) {
        case (1, 148): return .wireGuardInitiation
        case (2, 92): return .wireGuardResponse
        case (3, 64): return .wireGuardCookieReply
        case (4, 32): return .wireGuardKeepalive
        case (4, let length) where length > 32 && length.isMultiple(of: 16): return .wireGuardData
        default: return nil
        }
    }

    /// Enhanced GRE (version 1, protocol type 0x880B = PPP) as used by PPTP. Plain GRE (version 0) is not matched.
    fileprivate static func enhancedGRE(_ bytes: GuestVPNBytes) -> Bool {
        guard let flags = bytes.byte(1), flags & 0x07 == 1 else { return false }
        return bytes.u16(2) == 0x880B
    }

    /// PPTP control connection message: length, message type 1 (control), then the magic cookie.
    fileprivate static func pptpControl(_ bytes: GuestVPNBytes) -> GuestVPNSignature? {
        guard let length = bytes.u16(0), length >= 12, Int(length) <= bytes.count, bytes.u16(2) == 1, bytes.u32(4) == 0x1A2B_3C4D
        else { return nil }
        return .pptpControl
    }

    /// L2TPv2 header: flags (T, L, S, O, P bits; the other bits reserved zero), then version 2. Control messages must
    /// carry a length equal to the datagram size and a sequence number.
    fileprivate static func l2tp(_ bytes: GuestVPNBytes) -> GuestVPNSignature? {
        guard let flags = bytes.byte(0), bytes.byte(1) == 2, flags & 0x34 == 0 else { return nil }
        let isControl = flags & 0x80 != 0
        let hasLength = flags & 0x40 != 0
        if hasLength, bytes.u16(2).map(Int.init) != bytes.count { return nil }
        if isControl { return hasLength && flags & 0x08 != 0 && bytes.count >= 12 ? .l2tpControl : nil }
        return bytes.count >= 8 ? .l2tpData : nil
    }
}

extension GuestVPNMatcher {
    /// OpenVPN's first byte is `opcode << 3 | keyID`. Hard resets are recognized by opcode 7 (client) and 8 (server) with
    /// key id 0 and a non-zero session id; the exact unauthenticated layouts (14 and 26 bytes, packet ids 0) are
    /// a stronger match than the same opcode with an unknown `--tls-auth` tail. Other opcodes are only a weak
    /// session signal, and only count toward a peer that already showed a reset, unless the port is 1194.
    fileprivate static func openVPN(_ bytes: GuestVPNBytes, port1194: Bool) -> GuestVPNMatch? {
        guard let first = bytes.byte(0) else { return nil }
        switch first >> 3 {
        case 7:
            guard first & 7 == 0, bytes.hasNonZero(at: 1, length: 8) else { return nil }
            if bytes.count == 14, bytes.byte(9) == 0, bytes.u32(10) == 0 { return anchored(.openVPNClientReset) }
            return (14...128).contains(bytes.count) ? anchored(.openVPNClientResetAuthenticated) : nil
        case 8:
            guard first & 7 == 0, bytes.hasNonZero(at: 1, length: 8) else { return nil }
            if bytes.count == 26, bytes.byte(9) == 1, bytes.u32(10) == 0, bytes.hasNonZero(at: 14, length: 8), bytes.u32(22) == 0 {
                return anchored(.openVPNServerReset)
            }
            return (26...140).contains(bytes.count) ? anchored(.openVPNServerResetAuthenticated) : nil
        case 4, 5, 6, 9:
            return bytes.count >= 2 ? GuestVPNMatch(signature: .openVPNSession, needsAnchor: !port1194) : nil
        default:
            return nil
        }
    }

    private static func anchored(_ signature: GuestVPNSignature) -> GuestVPNMatch {
        GuestVPNMatch(signature: signature, needsAnchor: false)
    }

    /// IKE header: SPIs (initiator non-zero), version 0x20 (v2) or 0x10 (v1), exchange type, and a length field equal
    /// to the datagram size. On UDP 4500 a 4-byte zero non-ESP marker precedes it; a lone `0xFF` is the NAT-T keepalive;
    /// a non-zero first word is ESP in UDP.
    fileprivate static func ike(_ bytes: GuestVPNBytes, onNATTPort: Bool) -> GuestVPNMatch? {
        var view = bytes
        if onNATTPort {
            if bytes.count == 1, bytes.byte(0) == 0xFF { return anchored(.ikeNATTKeepalive) }
            if bytes.u32(0) == 0 {
                view = bytes.dropping(4)
            } else if bytes.count >= 12, bytes.hasNonZero(at: 0, length: 4) {
                return GuestVPNMatch(signature: .espInUDP, needsAnchor: true)
            }
        }
        guard view.count >= 28, view.hasNonZero(at: 0, length: 8), view.u32(24).map(Int.init) == view.count,
            let version = view.byte(17), let exchange = view.byte(18)
        else { return nil }
        switch (version, exchange) {
        case (0x20, 34...37): return anchored(.ikeV2)
        case (0x10, 1...5), (0x10, 32...33): return anchored(.ikeV1)
        default: return nil
        }
    }
}
