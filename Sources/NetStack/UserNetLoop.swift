import Foundation
import NetPolicy
import Synchronization

/// State the loop thread publishes for readers on other threads.
final class UserNetSharedState: Sendable {
    let stats = Mutex(UserNetStats())
    let vpnState = Mutex(GuestVPNState.none)
}

/// The I/O shell's event loop. Runs on one dedicated thread that owns the core, every host socket, and the guest
/// socket, so none of the stack's state needs a lock; the only shared pieces are the command inbox and the
/// published stats.
final class UserNetLoop {
    private static let tickInterval = Duration.milliseconds(100)
    private static let framesPerWake = 128

    private let bridge: UserNetBridge
    private let core: UserNetCore<UserNetBridge, SuspendingClock>
    private let poller: KQueuePoller
    private let inbox: UserNetInbox
    private let shared: UserNetSharedState
    private let receiveBuffer = RawBuffer(capacity: 65_600)
    private var events: [ReadinessEvent] = []
    private var commands: [UserNetCommand] = []
    private var stopping = false

    init(
        config: UserNetConfig, policy: NetworkPolicy, guestDescriptor: Int32, handle: KQueueHandle, inbox: UserNetInbox,
        shared: UserNetSharedState, flowEvents: AsyncStream<FlowEvent>.Continuation,
        vpnChanges: AsyncStream<GuestVPNState>.Continuation, resolver: any HostNameResolver,
        logger: any UserNetLogger = SilentUserNetLogger()
    ) {
        self.inbox = inbox
        self.shared = shared
        poller = KQueuePoller(handle: handle)
        let published = shared
        bridge = UserNetBridge(
            guestDescriptor: guestDescriptor, mtu: config.mtu, flowEvents: flowEvents,
            vpnSink: { state in
                published.vpnState.withLock { $0 = state }
                vpnChanges.yield(state)
            }, resolver: resolver, inbox: inbox, logger: logger)
        // SuspendingClock: it stops while the Mac sleeps, as the paused guest does, so no flow "idles out" across a sleep.
        core = UserNetCore(config: config, policy: policy, host: bridge, clock: SuspendingClock())
        events.reserveCapacity(256)
        commands.reserveCapacity(16)
    }

    /// Runs until a `stop` command arrives, then releases every descriptor.
    func run() {
        var lastTick = SuspendingClock.now
        while !stopping {
            let busy = core.stats.activeTCPFlows + core.stats.activeUDPFlows + core.dns.pendingCount > 0
            poller.wait(changes: &bridge.pendingChanges, events: &events, timeout: busy ? 0.1 : 1)
            processCommands()  // before I/O, so a policy posted before a frame was sent is in force when it is read
            var index = 0
            while index < events.count, !stopping {  // not `for ... in`: see KQueuePoller.wait
                handle(events[index])
                index += 1
            }
            deliverDeferredFailures()
            let now = SuspendingClock.now
            if now - lastTick >= Self.tickInterval {
                core.tick()
                lastTick = now
            }
            publishStats()
        }
        core.shutdown()
        bridge.closeAll()
        SocketCalls.close(bridge.guestDescriptor)
        publishStats()
    }

    private func handle(_ event: ReadinessEvent) {
        switch event.kind {
        case .wakeup:
            break
        case .readable:
            if event.descriptor == bridge.guestDescriptor {
                drainGuest()
            } else if bridge.hasStream(token: event.token) {
                core.streamReadable(token: event.token)
            } else if bridge.hasDatagram(token: event.token) {
                core.datagramReadable(token: event.token)
            }
        case .writable:
            if event.descriptor == bridge.guestDescriptor {
                bridge.flushTransmitQueue()
            } else if bridge.isConnecting(token: event.token) {
                core.streamConnected(token: event.token, error: bridge.completeConnect(token: event.token))
            } else if bridge.hasStream(token: event.token) {
                core.streamWritable(token: event.token)
            }
        }
    }

    private func drainGuest() {
        var frames = 0
        while frames < Self.framesPerWake {
            // A command posted before this frame was sent (a tightened policy, say) must be in force when it is read.
            if inbox.hasPending { processCommands() }
            guard case .transferred(let count) = SocketCalls.receive(bridge.guestDescriptor, into: receiveBuffer.mutableView) else {
                break
            }
            core.receiveFrame(receiveBuffer.view(length: count))
            frames += 1
        }
        core.endOfBatch()
    }

    private func deliverDeferredFailures() {
        guard !bridge.deferredConnectFailures.isEmpty else { return }
        let failures = bridge.deferredConnectFailures
        bridge.deferredConnectFailures.removeAll(keepingCapacity: true)
        for failure in failures { core.streamConnected(token: failure.token, error: failure.error) }
    }

    private func processCommands() {
        inbox.drain(into: &commands)
        var index = 0
        while index < commands.count {
            let command = commands[index]
            index += 1
            switch command {
            case .stop: stopping = true
            case .setPolicy(let policy, let action): core.updatePolicy(policy, existingFlows: action)
            case .hostPathChanged(let action): core.hostPathChanged(existingFlows: action)
            case .nameResolved(let token, let result):
                bridge.resolutionDelivered(token: token)
                core.nameResolved(token: token, result: result)
            }
        }
    }

    private func publishStats() {
        var snapshot = core.stats
        snapshot.framesLostToGuest += bridge.framesLostToGuest
        snapshot.flowEventsDropped += bridge.flowEventsDropped
        shared.stats.withLock { $0 = snapshot }
    }
}
