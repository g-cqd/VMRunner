import Network
import Observation

/// Host-side VPN detection, published for the UI and the kill-switch logic.
///
/// ## What this does and does not tell you
/// - It looks at the **host**. Guests on NAT networking send their traffic through the host's routes, so a VPN on the
///   host usually carries guest traffic too. That is a statement about the host's configuration, not a proof about
///   any packet.
/// - It **cannot see a VPN running inside the guest**: that traffic is encrypted before it reaches the host and looks
///   like ordinary NAT traffic. Use ``NetworkPolicy`` to constrain destinations; this cannot forbid in-guest VPNs.
/// - It can be **wrong with split tunneling**: a tunnel that is up for corporate subnets reads as `.active` even
///   though internet-bound guest traffic bypasses it; conversely a VPN that routes through a non-tunnel interface
///   reads as `.inactive`.
/// - macOS-internal tunnels are filtered by address, not by name (see ``VPNState/classify(_:)``); a third-party
///   tunnel (Private Relay, developer tools) that exposes a routable `utun` is indistinguishable from a VPN.
///
/// The default source is `NWPathMonitor` consumed as an `AsyncSequence`, which hands over the interfaces the OS
/// considers usable for the current network path. It exposes no addresses, so snapshots carry `addresses == nil`
/// and any usable tunnel-named interface counts. If a finer signal is ever needed, inject another ``Source``.
@MainActor @Observable
final class VPNMonitor {
    /// Produces a fresh stream of interface snapshots each time monitoring starts.
    typealias Source = @Sendable () -> any AsyncSequence<[InterfaceSnapshot], Never>

    /// The latest classification; `.unknown` until the first sample arrives and again after ``stop()``.
    private(set) var state = VPNState.unknown

    @ObservationIgnored private let source: Source
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameter source: Where snapshots come from; defaults to ``systemSource``.
    init(source: @escaping Source = VPNMonitor.systemSource) {
        self.source = source
    }

    isolated deinit {
        task?.cancel()
    }

    /// Begins observing. Idempotent. Each snapshot replaces ``state``.
    func start() {
        guard task == nil else { return }
        let makeSnapshots = source
        task = Task { [weak self] in
            for await interfaces in makeSnapshots() {
                guard let self, !Task.isCancelled else { return }
                self.state = VPNState.classify(interfaces)
            }
        }
    }

    /// Stops observing and returns ``state`` to `.unknown`, so a stopped monitor never vouches for the network.
    func stop() {
        task?.cancel()
        task = nil
        state = .unknown
    }

    /// Snapshots derived from `NWPathMonitor`: the path's available interfaces, up only while the path is satisfied.
    nonisolated static let systemSource: Source = {
        NWPathMonitor().map { path in
            var seen = Set<String>()
            let up = path.status == .satisfied
            return path.availableInterfaces.compactMap { interface in
                seen.insert(interface.name).inserted ? InterfaceSnapshot(name: interface.name, isUp: up, addresses: nil) : nil
            }
        }
    }
}
