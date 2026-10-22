import Foundation
import NetPolicy

/// The user-mode network: everything between the guest's Ethernet frames and abstract host I/O, as a synchronous
/// state machine with no threads, sockets, or timers of its own.
///
/// ## Driving it
/// One thread owns the core and calls it with events: guest frames (``receiveFrame(_:)``), host socket readiness
/// (``streamReadable(token:)`` and friends), resolver answers (``nameResolved(token:result:)``), and the passage
/// of time (``tick()``, a few times a second). Output goes through the ``UserNetHost`` the core was built with.
/// Time comes from the injected `Clock`, so a test clock makes every timeout deterministic.
///
/// ## Allocation
/// Per-packet work on established flows, ARP, DHCP and ICMP echo allocates nothing: frames are parsed in place
/// from the caller's buffer and built in a buffer owned by ``UserNetContext``, flows are keyed by a fixed-size
/// value, and payload moves between preallocated rings and sockets. Setting up a flow (policy evaluation, a
/// token, buffers on first use), DNS, and flow events allocate.
final class UserNetCore<Host: UserNetHost, ClockType: Clock> where ClockType.Duration == Duration {
    let ctx: UserNetContext<Host>
    var gate: PolicyGate
    let dhcp = DHCPServer()
    let dns = DNSProxy()
    var tcpFlows: [FlowKey: TCPFlow] = [:]
    var tcpByToken: [UInt64: TCPFlow] = [:]
    /// How many of ``tcpFlows`` are DNS-over-TCP sessions (`maxDNSTCPFlows` bounds them).
    var localDNSFlows = 0
    var udpFlows: [FlowKey: DatagramFlow] = [:]
    var icmpFlows: [FlowKey: DatagramFlow] = [:]
    var datagramByToken: [UInt64: DatagramFlow] = [:]
    /// Refusals published recently, so a guest hammering a denied destination yields one event, not thousands.
    var denials = DenialSuppression()
    /// Answers published recently, so a guest that asks the same question in a loop yields one event, not thousands.
    var answers = AnswerFolding()
    /// Opening a UDP or ICMP flow costs a host socket, so how fast the guest may open them is limited.
    var datagramFlowBudget: TokenBucket
    var pendingBatchEnd: [TCPFlow] = []
    var scratchKeys: [FlowKey] = []
    var nextSequence: UInt32
    var lastHousekeeping: TimeInterval = 0

    private let clock: ClockType
    private let origin: ClockType.Instant

    /// - Throws: Nothing; an invalid configuration is a programming error caught by ``UserNetConfig/problem``
    ///   before this is called.
    init(config: UserNetConfig, policy: NetworkPolicy, host: Host, clock: ClockType) {
        ctx = UserNetContext(config: config, host: host)
        gate = PolicyGate(policy: policy, floorExemptions: config.exemptedFloorKinds)
        datagramFlowBudget = TokenBucket(burst: config.datagramFlowBurst, perSecond: config.datagramFlowsPerSecond)
        self.clock = clock
        origin = clock.now
        nextSequence = config.initialSequenceSeed
        tcpFlows.reserveCapacity(config.maxTCPFlows)
        tcpByToken.reserveCapacity(config.maxTCPFlows)
        udpFlows.reserveCapacity(config.maxUDPFlows)
        datagramByToken.reserveCapacity(config.maxUDPFlows)
        pendingBatchEnd.reserveCapacity(64)
        scratchKeys.reserveCapacity(64)
    }

    var stats: UserNetStats {
        var snapshot = ctx.stats
        snapshot.activeTCPFlows = tcpFlows.count
        snapshot.activeUDPFlows = udpFlows.count + icmpFlows.count
        return snapshot
    }

    /// The current time on the core's clock, in seconds since the core was created.
    func currentTime() -> TimeInterval {
        let parts = origin.duration(to: clock.now).components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
    }

    func makeSequence() -> UInt32 {
        nextSequence &+= 64_000
        return nextSequence
    }

    // MARK: Guest frames

    /// Handles one Ethernet frame from the guest. The view is only used during the call.
    func receiveFrame(_ frame: ByteView) {
        ctx.now = currentTime()
        ctx.stats.framesFromGuest += 1
        ctx.stats.bytesFromGuest += UInt64(frame.count)
        let ethernet: EthernetHeader
        do {
            ethernet = try EthernetHeader(parsing: frame)
        } catch {
            ctx.stats.malformedFrames += 1
            return
        }
        guard ethernet.destination == ctx.config.gatewayMAC || ethernet.destination == .broadcast else { return }
        if !ethernet.source.isGroup { ctx.guestMAC = ethernet.source }
        switch ethernet.etherType {
        case EtherType.arp: handleARP(ethernet.payload)
        case EtherType.ipv4: handleIPv4(ethernet.payload)
        case EtherType.ipv6: ctx.stats.droppedIPv6Frames += 1
        default: ctx.stats.droppedUnsupported += 1
        }
    }

    /// Call after a burst of frames. Writes the guest bytes the burst staged for each flow with one call per flow, then
    /// sends the acknowledgements held back so that one ACK can cover several segments (and carries the window
    /// that the write just reopened).
    func endOfBatch() {
        var index = 0
        while index < pendingBatchEnd.count {
            let flow = pendingBatchEnd[index]
            flow.batchEndQueued = false
            if flow.hostWriteStaged { flow.flushToHost(ctx: ctx) }
            if flow.unacknowledgedSegments > 0, !flow.isFinished { flow.sendAcknowledgement(ctx: ctx) }
            if flow.isFinished { removeTCPFlow(flow) }
            index += 1
        }
        pendingBatchEnd.removeAll(keepingCapacity: true)
    }

    private func handleARP(_ payload: ByteView) {
        guard let arp = try? ARPPacket(parsing: payload), arp.operation == ARPPacket.request,
            arp.targetIP == ctx.config.gatewayAddress
        else { return }
        let reply = ARPPacket(
            operation: ARPPacket.reply, senderMAC: ctx.config.gatewayMAC, senderIP: ctx.config.gatewayAddress,
            targetMAC: arp.senderMAC, targetIP: arp.senderIP)
        ctx.sendARP(reply, to: arp.senderMAC)
    }
}
