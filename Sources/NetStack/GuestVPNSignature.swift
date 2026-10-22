import Foundation

/// A packet shape the detector recognizes. Each carries its weight in the confidence score.
///
/// Weights: 3 for a header with several independently checked fields (a handshake), 2 for looser shapes and the IPsec
/// data plane, 1 for single-field or data-plane shapes that many unrelated protocols could imitate.
enum GuestVPNSignature: String, Sendable, Hashable, CaseIterable {
    case wireGuardInitiation
    case wireGuardResponse
    case wireGuardCookieReply
    case wireGuardKeepalive
    case wireGuardData
    /// Unauthenticated `P_CONTROL_HARD_RESET_CLIENT_V2` with exactly the 14 bytes OpenVPN sends.
    case openVPNClientReset
    /// Unauthenticated `P_CONTROL_HARD_RESET_SERVER_V2` with exactly the 26 bytes OpenVPN sends.
    case openVPNServerReset
    /// A reset opcode with the right key id and a session id, but an unknown tail (`--tls-auth`).
    case openVPNClientResetAuthenticated
    case openVPNServerResetAuthenticated
    /// Control/ack/data opcodes: counted only on port 1194 or toward a peer that already showed a reset.
    case openVPNSession
    case ikeV2
    case ikeV1
    case ikeNATTKeepalive
    /// ESP inside UDP 4500: counted only toward a peer that already showed IKE.
    case espInUDP
    case esp
    case ah
    case l2tpControl
    case l2tpData
    case pptpControl
    case greEnhanced
    case dnsHint

    var kind: GuestVPNKind {
        switch self {
        case .wireGuardInitiation, .wireGuardResponse, .wireGuardCookieReply, .wireGuardKeepalive, .wireGuardData: .wireGuard
        case .openVPNClientReset, .openVPNServerReset, .openVPNClientResetAuthenticated, .openVPNServerResetAuthenticated,
            .openVPNSession:
            .openVPN
        case .ikeV2, .ikeV1, .ikeNATTKeepalive, .espInUDP, .esp, .ah: .ipsec
        case .l2tpControl, .l2tpData: .l2tp
        case .pptpControl, .greEnhanced: .pptp
        case .dnsHint: .dnsHint
        }
    }

    /// Points added to the kind's score per matching packet, up to ``maxCount`` packets.
    var weight: Int {
        switch self {
        case .wireGuardInitiation, .wireGuardResponse, .openVPNClientReset, .openVPNServerReset, .ikeV2, .ikeV1, .l2tpControl,
            .pptpControl, .greEnhanced:
            3
        case .openVPNClientResetAuthenticated, .openVPNServerResetAuthenticated, .esp, .ah, .dnsHint: 2
        case .wireGuardCookieReply, .wireGuardKeepalive, .wireGuardData, .openVPNSession, .ikeNATTKeepalive, .espInUDP, .l2tpData: 1
        }
    }

    /// How many matching packets still add to the score.
    var maxCount: Int {
        switch self {
        case .wireGuardInitiation, .wireGuardResponse, .openVPNClientReset, .openVPNServerReset, .openVPNClientResetAuthenticated,
            .openVPNServerResetAuthenticated, .ikeV2, .ikeV1, .l2tpControl, .dnsHint:
            2
        default: 3
        }
    }

    /// Whether a match of this signature can vouch for a later data-plane match from the same peer. The loose
    /// data-plane shapes cannot: they would otherwise bootstrap each other from noise.
    var isAnchor: Bool { self != .openVPNSession && self != .espInUDP }

    var reason: String {
        switch self {
        case .wireGuardInitiation: "WireGuard handshake initiation (type 1, 148 bytes)"
        case .wireGuardResponse: "WireGuard handshake response (type 2, 92 bytes)"
        case .wireGuardCookieReply: "WireGuard cookie reply (type 3, 64 bytes)"
        case .wireGuardKeepalive: "WireGuard keepalive (type 4, 32 bytes)"
        case .wireGuardData: "WireGuard transport data (type 4, length multiple of 16)"
        case .openVPNClientReset: "OpenVPN P_CONTROL_HARD_RESET_CLIENT_V2"
        case .openVPNServerReset: "OpenVPN P_CONTROL_HARD_RESET_SERVER_V2"
        case .openVPNClientResetAuthenticated: "OpenVPN client hard reset with an authentication tail"
        case .openVPNServerResetAuthenticated: "OpenVPN server hard reset with an authentication tail"
        case .openVPNSession: "OpenVPN control or data opcode on an OpenVPN peer"
        case .ikeV2: "IKEv2 message with a valid header"
        case .ikeV1: "IKEv1 message with a valid header"
        case .ikeNATTKeepalive: "IPsec NAT-T keepalive (0xFF on UDP 4500)"
        case .espInUDP: "ESP in UDP 4500 toward an IKE peer"
        case .esp: "ESP packet (IP protocol 50)"
        case .ah: "AH packet (IP protocol 51)"
        case .l2tpControl: "L2TPv2 control message"
        case .l2tpData: "L2TPv2 data message"
        case .pptpControl: "PPTP control message (magic cookie 0x1A2B3C4D)"
        case .greEnhanced: "Enhanced GRE carrying PPP (PPTP data)"
        case .dnsHint: "The guest resolved a configured VPN hint domain"
        }
    }
}
