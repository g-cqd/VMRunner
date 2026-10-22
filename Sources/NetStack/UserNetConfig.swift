import Foundation
import NetPolicy

/// What the stack does with a TCP connection attempt the policy denies.
package enum DenyAction: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// Answer with RST: the guest sees "connection refused" immediately. The default; fails fast.
    case reset
    /// Say nothing: the guest sees a timeout. Reveals less, and hangs the guest's connect attempt.
    case drop

    package var id: Self { self }
}

/// The DNS response code for a name the policy blocks.
enum DNSBlockResponse: Sendable, Hashable {
    /// NXDOMAIN: "no such name". Cached by resolvers and understood by every client. The default.
    case nameError
    /// REFUSED: "the server will not answer". Some clients retry or fall back to another resolver.
    case refused
}

/// What happens to flows that are already open when something about the world changes.
package enum ExistingFlowAction: Sendable, Hashable {
    /// Leave them alone.
    case keep
    /// Tear them down (TCP gets RST so the guest reconnects; UDP and ICMP flows are forgotten).
    case terminate
}

/// Everything configurable about one user-mode network. Plain values with sensible defaults.
///
/// ## Address plan
/// The guest lives on `198.18.0.0/24`: gateway (and DNS) `198.18.0.1`, guest `198.18.0.2`. That block is the
/// RFC 2544 benchmarking range, which is not routed on the Internet and is not used by consumer or corporate LANs
/// or the usual router defaults (`192.168.0.x`, `192.168.1.x`, `10.0.0.x`, `192.168.100.x` on some cable modems),
/// by Virtualization.framework's own NAT (`192.168.64.0/24`), by Docker (`172.17.0.0/16`), or by Tailscale
/// (`100.64.0.0/10`). A collision would only matter for destinations *inside* the guest subnet, which the guest
/// would try to ARP for instead of sending to the gateway. Change the addresses here if your guest needs that block.
package struct UserNetConfig: Sendable {
    var gatewayAddress = IPv4.make(198, 18, 0, 1)
    var guestAddress = IPv4.make(198, 18, 0, 2)
    var prefixLength = 24
    /// The gateway's Ethernet address: locally administered (bit 1 of the first octet), unicast.
    var gatewayMAC = MACAddress(rawValue: 0x0200_C612_0001)
    /// Largest IP packet in either direction. Virtualization.framework accepts 1500...65535.
    package var mtu = 1500
    var leaseDuration: TimeInterval = 86_400
    package var denyAction = DenyAction.reset
    /// Redirect every guest DNS query (UDP or TCP, port 53, any destination) to the built-in proxy so domain rules
    /// cannot be bypassed by pointing the guest at another resolver. DoH and DoT look like HTTPS and cannot be
    /// intercepted; block those destinations by address or port instead.
    var interceptAllDNS = true
    var dnsBlockResponse = DNSBlockResponse.nameError
    /// Built-in ranges that are always denied (``ReservedRangeKind/isFloor``) and are not, for this stack. Empty, and
    /// nothing in the app sets it: it exists so that integration tests can reach the loopback servers they start. No
    /// policy value reaches it, so a saved or edited policy can never lift the floor.
    var exemptedFloorKinds: Set<ReservedRangeKind> = []
    /// Where TCP initial sequence numbers start; tests pin it for deterministic frames.
    var initialSequenceSeed = UInt32.random(in: 0...UInt32.max)
    var vpnDetection = GuestVPNDetector.Configuration()
    package var maxTCPFlows = 1024
    package var maxUDPFlows = 1024
    /// DNS-over-TCP sessions open at once. Far fewer than ``maxTCPFlows``: a resolver needs one or two.
    package var maxDNSTCPFlows = 32
    /// New UDP and ICMP flows the guest may open at once, then ``datagramFlowsPerSecond``. Each one is a host socket, and
    /// a guest that sends to a new destination with every datagram would otherwise open (and, at the limit, close
    /// another to make room for) a socket per packet.
    package var datagramFlowBurst = 256
    package var datagramFlowsPerSecond = 128.0
    var tcpIdleTimeout: TimeInterval = 1_800
    var tcpConnectTimeout: TimeInterval = 20
    var udpIdleTimeout: TimeInterval = 60
    var icmpIdleTimeout: TimeInterval = 10
    var dnsTimeout: TimeInterval = 5
    /// Verify TCP/UDP/ICMP checksums of guest packets. Off by default: a guest NIC with checksum offload may
    /// legitimately hand over a partial checksum, and the link cannot corrupt data. The IPv4 header checksum is
    /// always verified.
    var verifyTransportChecksums = false
    /// Bytes of host-to-guest data kept per TCP flow until the guest acknowledges it (also bounds data in flight).
    var tcpSendBuffer = 128 * 1_024
    /// Bytes of guest-to-host data kept per TCP flow while the host socket is not writable. Also the largest
    /// receive window advertised.
    var tcpReceiveBuffer = 128 * 1_024

    package init() {}

    /// Whether `address` is on the guest's subnet.
    func isOnLink(_ address: UInt32) -> Bool {
        address & IPv4.mask(prefixLength: prefixLength) == gatewayAddress & IPv4.mask(prefixLength: prefixLength)
    }

    /// Why a configuration cannot work, or `nil` if it can.
    var problem: String? {
        if !(1_500...65_535).contains(mtu) { return "mtu must be within 1500...65535" }
        if !(8...30).contains(prefixLength) { return "prefixLength must be within 8...30" }
        if gatewayAddress == guestAddress { return "gateway and guest addresses must differ" }
        if !isOnLink(guestAddress) { return "guest address is not on the gateway's subnet" }
        if tcpSendBuffer < 16_384 || tcpReceiveBuffer < 16_384 { return "TCP buffers must be at least 16 KiB" }
        return nil
    }
}
