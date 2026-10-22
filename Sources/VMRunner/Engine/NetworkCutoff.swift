import NetPolicy
import Network
import Observation
import Virtualization

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
                vpn: VPNState.classify(interfaces), isExpensive: path.isExpensive, isConstrained: path.isConstrained,
                isSatisfied: up, interface: HostNetworkPath.Interface(path))
        }
    }
}

extension HostNetworkPath.Interface {
    /// The kind of link `path` uses, in the order macOS prefers them; `offline` when there is no usable path.
    init(_ path: NWPath) {
        if path.status != .satisfied {
            self = .offline
        } else if path.usesInterfaceType(.wifi) {
            self = .wifi
        } else if path.usesInterfaceType(.wiredEthernet) {
            self = .ethernet
        } else if path.usesInterfaceType(.cellular) {
            self = .cellular
        } else {
            self = .other
        }
    }
}

/// The part of a machine's network card the kill switch changes: its attachment, the cable.
@MainActor
protocol NetworkCard: AnyObject {
    var attachment: VZNetworkDeviceAttachment? { get set }
}

extension VZNetworkDevice: NetworkCard {}

/// The cable of a machine's network card as the kill switch pulls it: it keeps the attachment it took off to put the same
/// one back, and reads the card back after a pull, so a pull that did not take is reported, never assumed.
@MainActor
struct NetworkCardCable {
    private var detached: VZNetworkDeviceAttachment?

    /// Takes the attachment off `card` (`connected` false) or puts back the one it had (`true`). Returns false when the card
    /// still has an attachment after it was set to nil: the change was refused, and the guest is still connected.
    mutating func set(_ card: some NetworkCard, connected: Bool) -> Bool {
        if connected {
            guard let attachment = detached else { return true }
            card.attachment = attachment
            detached = nil
            return true
        }
        guard let attachment = card.attachment else { return true }
        detached = attachment
        card.attachment = nil
        return card.attachment == nil
    }
}
