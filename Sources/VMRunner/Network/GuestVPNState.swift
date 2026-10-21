import Foundation

/// What the detector sees of one packet crossing the user-mode network stack.
///
/// The stack builds one per IPv4 packet, on the stack, without allocating. Only the first ~150 bytes of `payload`
/// are ever inspected and nothing is retained after the call, so passing the whole transport payload view is fine.
/// Not `Sendable`: the payload view is only valid during the call that receives it.
struct GuestPacketObservation {
    enum Direction: Sendable, Hashable {
        case fromGuest
        case toGuest
    }

    enum Transport: Sendable, Hashable {
        case tcp(sourcePort: UInt16, destinationPort: UInt16)
        case udp(sourcePort: UInt16, destinationPort: UInt16)
        /// Any other IP protocol: 47 GRE, 50 ESP, 51 AH, ... The payload then starts right after the IP header.
        case ipProtocol(UInt8)
    }

    var direction: Direction
    /// The remote (non-guest) address of the flow.
    var peer: IPAddress
    var transport: Transport
    /// The transport payload (TCP/UDP), or the bytes after the IP header for other protocols.
    var payload: ByteView
    /// Length of the whole IP packet in bytes.
    var wireLength: Int
}

/// The family of VPN a fingerprint belongs to.
enum GuestVPNKind: String, Sendable, Hashable, CaseIterable {
    case wireGuard
    case openVPN
    /// IKEv1/IKEv2 negotiation, NAT-T keepalives, and the ESP/AH data plane.
    case ipsec
    case l2tp
    case pptp
    /// Only a configured DNS hint matched (see ``GuestVPNDetector/Configuration/hintDomains``); the transport is unknown.
    case dnsHint
}

/// How sure the detector is. `low` means "worth a look", `high` means a clean handshake from both sides was seen.
///
/// Thresholds are scores summed over the evidence (see ``GuestVPNDetector/Configuration``): `low` from 4, `medium`
/// from 6, `high` from 8 by default. A DNS hint never exceeds `low`.
enum GuestVPNConfidence: Int, Sendable, Hashable, Comparable {
    case low = 1
    case medium = 2
    case high = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One thing the detector saw, aggregated over repetitions of the same signature to the same peer.
struct GuestVPNEvidence: Sendable, Hashable {
    let signature: GuestVPNSignature
    /// The remote address, or `nil` for DNS hints.
    let peer: IPAddress?
    let direction: GuestPacketObservation.Direction
    /// How many packets matched (uncapped).
    var count: Int
    let firstSeen: TimeInterval
    var lastSeen: TimeInterval
    /// Extra context, such as the hinted DNS name.
    var detail: String?

    var kind: GuestVPNKind { signature.kind }

    /// What the score received from this evidence: the signature's weight times `min(count, maxCount)`, so a
    /// repeated packet cannot buy unlimited confidence.
    var weight: Int { signature.weight * min(count, signature.maxCount) }

    /// A human-readable explanation, suitable for a UI or a log (it may contain a DNS name: treat it as private).
    var reason: String {
        detail.map { "\(signature.reason) (\($0))" } ?? signature.reason
    }
}

/// The detector's verdict. It is a heuristic over what is visible on the wire, not proof.
///
/// ## What the detector cannot see
/// - **Tunnels inside TLS** (OpenVPN-over-TLS on 443, SSTP, WireGuard wrapped in TCP such as udp2raw, Cloudflare WARP
///   over MASQUE/HTTP3, Tailscale DERP relays, any HTTPS-proxy-based VPN): these are ordinary TLS or QUIC.
/// - **Obfuscated or encrypted-header VPNs**: WireGuard with obfuscation patches, OpenVPN with `--tls-crypt` or XOR
///   scramble (only its looser reset shape is matched, and only if the first byte is intact), obfs4, Shadowsocks,
///   V2Ray, and other protocols designed to look like noise.
/// - **Tor** and other onion/mixnet transports over TLS.
/// - **IPsec inside other tunnels** (L2TP/IPsec shows up as ESP or IKE, never as L2TP, because L2TP is encrypted).
/// - **Plain GRE/IP-in-IP** tunnels without encryption, which are not VPNs by themselves.
/// - Anything on a port or with a header the signatures do not know, and any flow whose first packets began before the
///   detector started watching (data packets alone give only `low` confidence).
///
/// False positives are possible: a game or application that happens to send WireGuard-shaped UDP (`04 00 00 00`,
/// length a multiple of 16) can reach `low`; an application that speaks IKE or WireGuard to a server really is
/// tunnelling, but the detector cannot tell a VPN for the whole machine from one app's own tunnel.
enum GuestVPNState: Sendable, Hashable {
    case none
    /// `since` is when this kind first qualified (monotonic seconds); `evidence` is the strongest evidence for it,
    /// at most eight entries, sorted by weight.
    case suspected(kind: GuestVPNKind, confidence: GuestVPNConfidence, since: TimeInterval, evidence: [GuestVPNEvidence])

    var kind: GuestVPNKind? {
        if case .suspected(let kind, _, _, _) = self { kind } else { nil }
    }

    var confidence: GuestVPNConfidence? {
        if case .suspected(_, let confidence, _, _) = self { confidence } else { nil }
    }
}
