import Foundation
import Observation

/// The live side of one run of a filtered network: a bounded log of recent connections, the guest and host VPN signals,
/// and the way edits to the policy reach the running stack.
///
/// One instance serves one stack for one run of the machine. The stack's two event streams are only read here, so
/// nothing is lost if the log is never shown: counting and the bounded log are cheap.
///
/// The stack is reached through three closures (start, policy update, shutdown), so tests drive this class with plain streams and no sockets.
@MainActor @Observable
final class NetworkActivity {
    private enum Phase { case ready, running, stopped }

    /// Newest first, at most ``EditorLimits/recentFlowLimit``.
    private(set) var flows: [FlowLogEntry] = []
    private(set) var allowedCount = 0
    private(set) var deniedCount = 0
    private(set) var guestVPN = GuestVPNState.none
    /// The policy the running stack is enforcing.
    private(set) var policy: NetworkPolicy

    /// The guest signal and the Mac's VPN state together.
    var vpn: VPNIndicator { VPNIndicator(host: hostMonitor.state, guest: guestVPN) }

    @ObservationIgnored private let events: AsyncStream<FlowEvent>
    @ObservationIgnored private let vpnChanges: AsyncStream<GuestVPNState>
    @ObservationIgnored private let hostMonitor: VPNMonitor
    @ObservationIgnored private let begin: () -> Void
    @ObservationIgnored private let forward: (NetworkPolicy, ExistingFlowAction) -> Void
    @ObservationIgnored private let shutdown: @Sendable () async -> Void
    @ObservationIgnored private var phase = Phase.ready
    @ObservationIgnored private var readers: [Task<Void, Never>] = []
    @ObservationIgnored private var nextID = 0

    init(
        policy: NetworkPolicy, events: AsyncStream<FlowEvent>, vpnChanges: AsyncStream<GuestVPNState>,
        hostMonitor: VPNMonitor = VPNMonitor(),
        begin: @escaping () -> Void, forward: @escaping (NetworkPolicy, ExistingFlowAction) -> Void,
        shutdown: @escaping @Sendable () async -> Void
    ) {
        self.policy = policy
        self.events = events
        self.vpnChanges = vpnChanges
        self.hostMonitor = hostMonitor
        self.begin = begin
        self.forward = forward
        self.shutdown = shutdown
    }

    /// Serves `stack`, which must be new and not started yet.
    convenience init(stack: UserNetStack, policy: NetworkPolicy) {
        self.init(
            policy: policy, events: stack.flowEvents, vpnChanges: stack.vpnChanges,
            begin: { stack.start() }, forward: { stack.updatePolicy($0, existingFlows: $1) }, shutdown: { await stack.stop() })
    }

    var isRunning: Bool { phase == .running }

    /// Starts the stack and begins reading its streams. Call before the virtual machine starts.
    func start() {
        guard phase == .ready else { return }
        phase = .running
        begin()
        hostMonitor.start()
        let events = events
        let vpnChanges = vpnChanges
        readers = [
            Task { [weak self] in
                for await event in events { self?.record(event) }
            },
            Task { [weak self] in
                for await state in vpnChanges { self?.guestVPN = state }
            },
        ]
    }

    /// Hands an edited policy to the running stack. Open connections the new policy no longer allows are torn down.
    /// Does nothing when the machine isn't running or the policy didn't change.
    @discardableResult
    func apply(_ newPolicy: NetworkPolicy) -> Bool {
        guard phase == .running, newPolicy != policy else { return false }
        policy = newPolicy
        forward(newPolicy, .terminate)
        return true
    }

    /// Stops reading and shuts the stack down in the background. Safe to call again, and before ``start()``.
    func stop() {
        guard phase != .stopped else { return }
        phase = .stopped
        for reader in readers { reader.cancel() }
        readers = []
        hostMonitor.stop()
        let shutdown = shutdown
        Task { await shutdown() }
    }

    private func record(_ event: FlowEvent) {
        guard let entry = FlowLogEntry(event: event, id: nextID) else { return }
        nextID += 1
        switch entry.outcome {
        case .allowed: allowedCount += 1
        case .denied: deniedCount += 1
        }
        flows.insert(entry, at: 0)
        if flows.count > EditorLimits.recentFlowLimit { flows.removeLast(flows.count - EditorLimits.recentFlowLimit) }
    }
}
