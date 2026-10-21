/// Cheap monotonic counters. Updated on the stack's single thread; snapshots are plain copies.
struct UserNetStats: Sendable, Hashable {
    var framesFromGuest: UInt64 = 0
    var framesToGuest: UInt64 = 0
    var bytesFromGuest: UInt64 = 0
    var bytesToGuest: UInt64 = 0
    /// Frames dropped because they could not be parsed.
    var malformedFrames: UInt64 = 0
    var droppedIPv6Frames: UInt64 = 0
    var droppedFragments: UInt64 = 0
    /// IP protocols with no NAT (ESP, GRE, IGMP, ...), and broadcast/multicast datagrams other than DHCP.
    var droppedUnsupported: UInt64 = 0
    /// Frames the host could not hand to the guest (its socket buffer was full and the queue overflowed).
    var framesLostToGuest: UInt64 = 0
    /// Flow events that could not be queued for the reader because it fell behind (the stream keeps the newest).
    var flowEventsDropped: UInt64 = 0
    /// Refusals counted but not published, because an equal one went out recently (see ``DenialSuppression``).
    var deniedEventsSuppressed: UInt64 = 0
    var tcpFlowsOpened: UInt64 = 0
    var tcpFlowsDenied: UInt64 = 0
    var tcpFlowsFailed: UInt64 = 0
    var tcpRetransmits: UInt64 = 0
    var udpFlowsOpened: UInt64 = 0
    var udpFlowsDenied: UInt64 = 0
    var icmpEchoes: UInt64 = 0
    var dnsQueries: UInt64 = 0
    var dnsBlocked: UInt64 = 0
    var dhcpAcks: UInt64 = 0
    var activeTCPFlows = 0
    var activeUDPFlows = 0
}
