import Foundation
package import NetPolicy
import Synchronization

// DESIGN NOTE: the user-mode network stack
//
// WHY. Virtualization.framework's NAT attachment is a black box: no filtering, no visibility. Bridged and vmnet
// attachments need restricted entitlements. Owning the datapath fixes both: the guest gets a virtio NIC whose Ethernet
// frames arrive on a datagram socket we read, and we implement the network behind it with ordinary host sockets. That
// buys four things at once:
//   1. enforceable allow/deny rules (NetworkPolicy) on IPs, ports, connections and domains, applied per flow;
//   2. passive detection of VPNs running inside the guest (GuestVPNDetector);
//   3. guest traffic leaves through whatever network the Mac is using right now, because the kernel routes each new
//      host socket: Wi-Fi, Ethernet or a VPN's default route, with no guest-visible change;
//   4. a structured event for every flow (FlowEvent) and cheap counters (UserNetStats).
//
// LAYERS.
//   UserNetCore    pure, synchronous, deterministic: Ethernet/ARP/IPv4/ICMP/UDP/TCP, DHCP server, DNS proxy, NAT tables,
//                  policy gate, VPN fingerprinting. Talks to the world only through the UserNetHost protocol and an
//                  injected Clock. This is what the unit tests drive with crafted frames and a fake host.
//   UserNetBridge  UserNetHost over BSD sockets (non-blocking) registered with a kqueue.
//   UserNetLoop    one dedicated thread owning the core, the bridge and the guest socket. All stack state is touched
//                  from that thread only; commands (policy, stop, path change, resolver answers) arrive through a
//                  mutex-guarded inbox plus a kqueue wakeup. Readers of stats and VPN state use Mutex-guarded copies.
//   UserNetStack   the public handle: lifecycle, policy updates, and event streams. The app adds the VZFileHandle factory
//                  (Engine/UserNetStack+Virtualization.swift).
//
// WHAT IS COVERED. IPv4 only. The guest is told (DHCP) that the gateway 198.18.0.1 is its router and DNS server. ARP
// for the gateway; TCP (relayed, with window flow control, MSS, FIN/RST/half-close, idle timeouts and retransmission);
// UDP per 5-tuple; ICMP echo through an unprivileged ICMP datagram socket; DNS over UDP and TCP to the gateway, or to any
// server when interceptAllDNS is on. A TCP handshake completes with the guest only after the host connection succeeded.
//
// PERFORMANCE. Frames are parsed in place from a receive buffer and built in a transmit buffer owned by the context;
// flows are keyed by a fixed-size value; payload moves between preallocated rings and sockets with at most one copy
// each way; the guest bytes of a burst of segments are written to the host socket with one call. Per-packet work on
// established flows, ARP, DHCP, ICMP echo and the whole loop thread's wake cycle does not allocate, even in an
// unoptimized build (UserNetAllocationTests measures it); flow setup, DNS and flow events do. Hot loops are `while`
// loops on purpose: an unoptimized `for ... in` over a range or array boxes an iterator on every pass.
// Measured (UserNetThroughputTests, release build, Apple silicon, one TCP stream over loopback with a scripted guest
// in the same process, 256 MiB): MTU 1500 uploads ~820 MiB/s and downloads ~690 MiB/s; MTU 9000 ~1.9 and ~2.6 GiB/s.
// A real guest adds Virtualization.framework's own per-frame cost and the guest kernel, so expect less, but far more
// than typical downloads, git and package installs need. A larger MTU (UserNetConfig.mtu, up to 65535, announced by
// DHCP option 26) helps most; guests that ignore the option stay at 1500.
//
// KNOWN GAPS.
//   - IPv6 is not advertised (no router advertisements) and IPv6 frames are dropped; guests fall back to IPv4. AAAA
//     questions are answered with an empty NOERROR.
//   - IPv4 fragments from the guest are dropped (and counted), not reassembled. Replies larger than the MTU to the
//     guest are fragmented.
//   - The MTU is whatever UserNetConfig.mtu says (default 1500); there is no path-MTU discovery towards the host
//     network, and no ICMP errors are generated (no traceroute, no "fragmentation needed").
//   - No multicast or broadcast beyond DHCP and ARP: mDNS, SSDP, NetBIOS, LLMNR are dropped.
//   - ESP, AH, GRE and other IP protocols cannot be NATed without raw sockets: IPsec and PPTP tunnels inside the guest
//     will not work (and are reported by the VPN detector).
//   - UDP NAT is port-restricted: only the destination the guest first sent to can answer.
//   - TCP: no SACK, no timestamps, no congestion control, out-of-order guest segments are dropped (the guest
//     retransmits). Urgent data is delivered in-band.
//   - Throughput is bounded by one thread and one syscall per frame: a kernel NAT or the system NAT attachment can be faster.
//
// IN-FLIGHT FLOWS AND HOST PATH CHANGES. A BSD socket stays on the interface it was bound to when it connected. If the
// Mac changes network (Wi-Fi to Ethernet, a VPN connects) the old flows either stall or keep using the old path. The
// stack watches the path (NWPathMonitor) and, by default, resets every open flow when it changes (`pathChangeAction`):
// TCP gets RST so the guest reconnects immediately over the new path, UDP flows are forgotten. The trade-off: a
// harmless change (a second interface appearing) also drops long-lived connections such as an SSH session; the
// alternative (`.keep`) leaves them to time out on the old path. NEW flows always use the current path, with no reset.

/// Why a stack could not be created.
package enum UserNetError: Error, Hashable, Sendable {
    /// The configuration cannot work; the text says why.
    case invalidConfiguration(String)
    /// A system call failed with this `errno`.
    case systemCall(Int32)
}

/// One-shot "the loop thread has finished" signal that any number of tasks may await.
private final class ExitSignal: Sendable {
    private struct State {
        var done = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func signal() {
        let waiters = state.withLock { current -> [CheckedContinuation<Void, Never>] in
            current.done = true
            defer { current.waiters = [] }
            return current.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let finished = state.withLock { current -> Bool in
                if current.done { return true }
                current.waiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
    }
}

/// A running (or ready to run) user-mode network for one guest. See the design note at the top of this file.
///
/// All methods are safe to call from any thread. Create with
/// ``make(config:policy:resolver:pathChangeAction:pathChanges:logger:)`` (or the Virtualization.framework factory the app
/// adds in `Engine/UserNetStack+Virtualization.swift`), call ``start()``, and ``stop()`` when the virtual machine ends.
package final class UserNetStack: Sendable {
    private enum Lifecycle {
        case ready, running, stopped
    }

    /// One event per flow lifecycle step and per DNS answer. Buffers the newest 4096 events if nobody is reading.
    package let flowEvents: AsyncStream<FlowEvent>
    /// Emits whenever the VPN detector's verdict changes (kind or confidence). Same buffering as ``flowEvents``.
    package let vpnChanges: AsyncStream<GuestVPNState>
    let config: UserNetConfig

    private let lifecycle = Mutex(Lifecycle.ready)
    private let shared = UserNetSharedState()
    private let inbox: UserNetInbox
    private let handle: KQueueHandle
    private let hostDescriptor: Int32
    private let policy: Mutex<NetworkPolicy>
    private let resolver: any HostNameResolver
    private let logger: any UserNetLogger
    private let pathChanges: @Sendable () -> AsyncStream<Void>
    private let flowContinuation: AsyncStream<FlowEvent>.Continuation
    private let vpnContinuation: AsyncStream<GuestVPNState>.Continuation
    private let exitSignal = ExitSignal()
    private let pathWatcher = Mutex<Task<Void, Never>?>(nil)

    /// What happens to open flows when the host's network path changes.
    let pathChangeAction: ExistingFlowAction

    /// Takes ownership of `hostDescriptor`, the host end of the datagram socket pair.
    private init(
        hostDescriptor: Int32, handle: KQueueHandle, config: UserNetConfig, policy: NetworkPolicy,
        resolver: any HostNameResolver, logger: any UserNetLogger, pathChangeAction: ExistingFlowAction,
        pathChanges: @escaping @Sendable () -> AsyncStream<Void>
    ) {
        self.hostDescriptor = hostDescriptor
        self.handle = handle
        self.config = config
        self.policy = Mutex(policy)
        self.resolver = resolver
        self.logger = logger
        self.pathChangeAction = pathChangeAction
        self.pathChanges = pathChanges
        inbox = UserNetInbox(handle: handle)
        (flowEvents, flowContinuation) = AsyncStream.makeStream(of: FlowEvent.self, bufferingPolicy: .bufferingNewest(4_096))
        (vpnChanges, vpnContinuation) = AsyncStream.makeStream(of: GuestVPNState.self, bufferingPolicy: .bufferingNewest(64))
    }

    /// Creates the datagram socket pair and a stack on its host end.
    ///
    /// - Returns: the descriptor to hand to the guest's NIC (a connected `AF_UNIX` datagram socket; the caller owns
    ///   it), and the stack.
    /// - Throws: ``UserNetError``.
    package static func make(
        config: UserNetConfig = UserNetConfig(), policy: NetworkPolicy = NetworkPolicy(),
        resolver: any HostNameResolver = SystemNameResolver(), pathChangeAction: ExistingFlowAction = .terminate,
        pathChanges: @escaping @Sendable () -> AsyncStream<Void> = HostPathMonitor.changes,
        logger: any UserNetLogger = SilentUserNetLogger()
    ) throws(UserNetError) -> (guestDescriptor: Int32, stack: UserNetStack) {
        if let problem = config.problem { throw .invalidConfiguration(problem) }
        SocketCalls.raiseDescriptorLimit()  // each flow holds a host socket; the default of 256 is too low for 1000 flows
        guard let pair = SocketCalls.datagramPair(bufferSize: max(1 << 20, config.mtu * 64)) else { throw .systemCall(errno) }
        guard let handle = KQueueHandle() else {
            let failure = errno
            SocketCalls.close(pair.guestSide)
            SocketCalls.close(pair.hostSide)
            throw .systemCall(failure)
        }
        let stack = UserNetStack(
            hostDescriptor: pair.hostSide, handle: handle, config: config, policy: policy, resolver: resolver,
            logger: logger, pathChangeAction: pathChangeAction, pathChanges: pathChanges)
        return (pair.guestSide, stack)
    }

    deinit {
        let wasRunning = lifecycle.withLock { $0 == .running }
        if wasRunning {
            inbox.post(.stop)  // the loop thread closes its descriptors and finishes the streams on its way out
        } else if lifecycle.withLock({ $0 != .stopped }) {
            SocketCalls.close(hostDescriptor)
            flowContinuation.finish()
            vpnContinuation.finish()
        }
        pathWatcher.withLock { $0?.cancel() }
    }

    // MARK: Lifecycle

    /// Starts the loop thread and the host path watcher. Idempotent; a stopped stack stays stopped.
    package func start() {
        let shouldStart = lifecycle.withLock { state -> Bool in
            guard state == .ready else { return false }
            state = .running
            return true
        }
        guard shouldStart else { return }
        logger.stackStarting(mtu: config.mtu)
        launchLoop()
        let changes = pathChanges
        let inbox = inbox
        let action = pathChangeAction
        let watcher = Task {
            for await _ in changes() { inbox.post(.hostPathChanged(action)) }
        }
        pathWatcher.withLock { $0 = watcher }
    }

    private func launchLoop() {
        let loopInputs = (
            config: config, policy: policy.withLock { $0 }, descriptor: hostDescriptor, handle: handle, inbox: inbox, shared: shared,
            events: flowContinuation, vpn: vpnContinuation, resolver: resolver, logger: logger, exit: exitSignal
        )
        let thread = Thread {
            let loop = UserNetLoop(
                config: loopInputs.config, policy: loopInputs.policy, guestDescriptor: loopInputs.descriptor,
                handle: loopInputs.handle, inbox: loopInputs.inbox, shared: loopInputs.shared, flowEvents: loopInputs.events,
                vpnChanges: loopInputs.vpn, resolver: loopInputs.resolver, logger: loopInputs.logger)
            loop.run()
            loopInputs.events.finish()
            loopInputs.vpn.finish()
            loopInputs.exit.signal()
        }
        thread.name = "VMRunner.UserNetStack"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Stops the stack and waits until its thread has closed every socket and finished the event streams. Open
    /// flows are reported closed with ``FlowCloseReason/stackStopped``. Idempotent.
    package func stop() async {
        pathWatcher.withLock { $0?.cancel() }
        let previous = lifecycle.withLock { state -> Lifecycle in
            defer { state = .stopped }
            return state
        }
        switch previous {
        case .running:
            inbox.post(.stop)
            await exitSignal.wait()
        case .ready:
            SocketCalls.close(hostDescriptor)
            flowContinuation.finish()
            vpnContinuation.finish()
            exitSignal.signal()
        case .stopped:
            await exitSignal.wait()
        }
    }

    // MARK: Control and observation

    /// Replaces the policy. New flows are judged by it immediately (the loop applies it before reading the next
    /// frame). `existingFlows` decides what happens to flows already open: `.terminate` (the default) tears down
    /// those the new policy no longer allows, so a tightened rule is actually enforced; `.keep` lets them run.
    package func updatePolicy(_ newPolicy: NetworkPolicy, existingFlows: ExistingFlowAction = .terminate) {
        policy.withLock { $0 = newPolicy }
        inbox.post(.setPolicy(newPolicy, existingFlows))
    }

    /// A snapshot of the counters, refreshed after every loop iteration.
    var stats: UserNetStats { shared.stats.withLock { $0 } }

    /// The current VPN verdict.
    var vpnState: GuestVPNState { shared.vpnState.withLock { $0 } }
}
