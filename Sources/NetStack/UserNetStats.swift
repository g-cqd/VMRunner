/// Cheap monotonic counters. Updated on the stack's single thread; snapshots are plain copies.
package struct UserNetStats: Sendable, Hashable {
    package var framesFromGuest: UInt64 = 0
    package var framesToGuest: UInt64 = 0
    package var bytesFromGuest: UInt64 = 0
    package var bytesToGuest: UInt64 = 0
    /// Frames dropped because they could not be parsed.
    package var malformedFrames: UInt64 = 0
    package var droppedIPv6Frames: UInt64 = 0
    package var droppedFragments: UInt64 = 0
    /// IP protocols with no NAT (ESP, GRE, IGMP, ...), and broadcast/multicast datagrams other than DHCP.
    package var droppedUnsupported: UInt64 = 0
    /// Frames the host could not hand to the guest (its socket buffer was full and the queue overflowed).
    package var framesLostToGuest: UInt64 = 0
    /// Flow events that could not be queued for the reader because it fell behind (the stream keeps the newest).
    package var flowEventsDropped: UInt64 = 0
    /// Refusals counted but not published, because an equal one went out recently (see ``DenialSuppression``).
    package var deniedEventsSuppressed: UInt64 = 0
    package var tcpFlowsOpened: UInt64 = 0
    package var tcpFlowsDenied: UInt64 = 0
    package var tcpFlowsFailed: UInt64 = 0
    package var tcpRetransmits: UInt64 = 0
    /// Datagram flows closed to make room, and the passes that did it (a pass closes a batch, so passes are far fewer).
    package var datagramFlowsEvicted: UInt64 = 0
    package var datagramEvictionPasses: UInt64 = 0
    package var udpFlowsOpened: UInt64 = 0
    package var udpFlowsDenied: UInt64 = 0
    package var icmpEchoes: UInt64 = 0
    package var dnsQueries: UInt64 = 0
    package var dnsBlocked: UInt64 = 0
    /// DNS-over-TCP answers that found the guest-bound buffer full (the guest stopped reading); each one reset its session.
    package var dnsAnswersLost: UInt64 = 0
    package var dhcpAcks: UInt64 = 0
    package var activeTCPFlows = 0
    package var activeUDPFlows = 0
}
