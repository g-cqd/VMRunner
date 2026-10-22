import AsyncAlgorithms
import Foundation
import NetPolicy
import NetStack
import Observation

/// The live side of one run of a filtered network: a bounded log of recent connections, the guest and host VPN signals,
/// and the way edits to the policy reach the running stack.
///
/// One instance serves one stack for one run of the machine. The stack's two event streams are only read here, so
/// nothing is lost if the log is never shown: counting and the bounded log are cheap.
///
/// Flow events are gathered off the main actor and applied in batches, so a guest that opens connections or looks up names
/// by the thousand costs the main thread one short update every ``batchInterval`` rather than one per event, and cannot
/// delay the keyboard and mouse events that share that thread.
///
/// The stack is reached through three closures (start, policy update, shutdown), so tests drive this class with plain streams and no sockets.
@MainActor @Observable
final class NetworkActivity {
    private enum Phase { case ready, running, stopped }

    /// How long flow events are gathered before the log is updated.
    static let batchInterval = Duration.milliseconds(200)
    /// The most flow events one update takes; a busier moment makes several updates.
    static let batchLimit = 1_024

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
    /// Starts reading `events` in batches; the task ends with the stream or when cancelled.
    @ObservationIgnored private let readFlows: @MainActor (NetworkActivity, AsyncStream<FlowEvent>) -> Task<Void, Never>
    @ObservationIgnored private var phase = Phase.ready
    @ObservationIgnored private var readers: [Task<Void, Never>] = []
    @ObservationIgnored private var nextID = 0

    /// Times the batches with `clock`; a test passes its own.
    init<C: Clock>(
        policy: NetworkPolicy, events: AsyncStream<FlowEvent>, vpnChanges: AsyncStream<GuestVPNState>,
        hostMonitor: VPNMonitor = VPNMonitor(), clock: C = ContinuousClock(),
        begin: @escaping () -> Void, forward: @escaping (NetworkPolicy, ExistingFlowAction) -> Void,
        shutdown: @escaping @Sendable () async -> Void
    ) where C.Duration == Duration {
        self.policy = policy
        self.events = events
        self.vpnChanges = vpnChanges
        self.hostMonitor = hostMonitor
        self.begin = begin
        self.forward = forward
        self.shutdown = shutdown
        readFlows = { activity, events in
            let batches = events.chunks(ofCount: Self.batchLimit, or: AsyncTimerSequence.repeating(every: Self.batchInterval, clock: clock))
            return Task { [weak activity] in
                for await batch in batches { activity?.record(batch) }
            }
        }
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
        let vpnChanges = vpnChanges
        readers = [
            readFlows(self, events),
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

    /// Counts a batch and logs its newest connections, in one update of the observed state. Events that have no line
    /// (a connection ending normally) are skipped; of the rest only the newest ``EditorLimits/recentFlowLimit`` are turned
    /// into lines, because the older ones would fall off the log at once. A folded denial counts for every attempt it stands for.
    private func record(_ batch: [FlowEvent]) {
        let work = InputPath.begin("flow log batch")
        defer { InputPath.end(work) }
        let logged = batch.filter { FlowLogEntry.outcome(of: $0.phase) != nil }
        guard !logged.isEmpty else { return }
        let firstID = nextID
        nextID += logged.count
        let entries = logged.enumerated().suffix(EditorLimits.recentFlowLimit).compactMap { offset, event in
            FlowLogEntry(event: event, id: firstID + offset)
        }
        for event in logged {
            switch FlowLogEntry.outcome(of: event.phase) {
            case .allowed?: allowedCount += 1
            case .denied?: deniedCount += FlowLogEntry.attempts(of: event)
            case nil: break
            }
        }
        flows.insert(contentsOf: entries.reversed(), at: 0)
        if flows.count > EditorLimits.recentFlowLimit { flows.removeLast(flows.count - EditorLimits.recentFlowLimit) }
    }
}
