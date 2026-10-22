import NetPolicy
import Network
import Observation

/// The kill switch of one run (roadmap 0010): it follows the Mac's network path and disconnects the guest's network card
/// while the machine's rules say so (`VMConfig.networkCutoffReason(on:)`), then connects it again.
///
/// It watches the Mac, not the guest: a VPN that is up on the Mac usually carries the guest's traffic, but split
/// tunnelling can make that wrong either way (see `VPNMonitor`). Before the first sample the VPN state is unknown, so a
/// VPN rule cuts the card from the start. It stops when it is released, with the machine that owns it.
@MainActor @Observable
final class NetworkCutoff {
    /// Produces a fresh stream of path samples when the watch starts.
    typealias Source = @Sendable () -> any AsyncSequence<HostNetworkPath, Never>

    /// Why the card is disconnected now; nil while it is connected.
    private(set) var reason: NetworkCutoffReason?

    @ObservationIgnored private let config: VMConfig
    @ObservationIgnored private let source: Source
    @ObservationIgnored private var connect: ((Bool) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(config: VMConfig, source: @escaping Source = HostNetworkPath.systemPaths) {
        self.config = config
        self.source = source
    }

    isolated deinit {
        task?.cancel()
    }

    /// Applies the rules to an unknown path at once, then to every sample. `connect(false)` disconnects the card and
    /// `connect(true)` connects it again; each is called only when the answer changes. Idempotent.
    func start(connect: @escaping (Bool) -> Void) {
        guard task == nil else { return }
        self.connect = connect
        apply(HostNetworkPath())
        let makePaths = source
        task = Task { [weak self] in
            for await path in makePaths() {
                guard let self, !Task.isCancelled else { return }
                self.apply(path)
            }
        }
    }

    private func apply(_ path: HostNetworkPath) {
        let next = config.networkCutoffReason(on: path)
        guard next != reason else { return }
        let changesConnection = (next == nil) != (reason == nil)
        reason = next
        if changesConnection { connect?(next == nil) }
    }
}

extension HostNetworkPath {
    /// Samples of the Mac's network path from `NWPathMonitor`, a fresh stream per call: the VPN state of the path's usable
    /// interfaces (read as `VPNMonitor` reads them), and whether the path is expensive or constrained.
    static let systemPaths: @Sendable () -> any AsyncSequence<HostNetworkPath, Never> = {
        NWPathMonitor().map { path in
            let up = path.status == .satisfied
            let interfaces = path.availableInterfaces.map { InterfaceSnapshot(name: $0.name, isUp: up, addresses: nil) }
            return HostNetworkPath(
                vpn: VPNState.classify(interfaces), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        }
    }
}
