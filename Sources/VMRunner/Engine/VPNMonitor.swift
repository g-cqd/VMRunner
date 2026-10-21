import Network
import Observation

/// What the host's network stack says about VPN use.
enum VPNState: Hashable, Sendable {
    /// A tunnel interface that looks like a real VPN is up.
    case active
    /// No such interface was seen.
    case inactive
    /// Not determined yet (no sample received) or ambiguous (a tunnel exists but has no address yet).
    case unknown
}

/// One network interface as the classifier needs it. A plain value so classification is testable without a network.
struct InterfaceSnapshot: Hashable, Sendable {
    /// BSD name, such as `en0` or `utun3`.
    var name: String
    /// Whether the interface is up and usable for traffic.
    var isUp: Bool
    /// Addresses assigned to the interface, or `nil` when the source cannot say (``VPNMonitor/systemSource``).
    var addresses: [IPAddress]?
}

extension VPNState {
    /// Name prefixes of tunnel-style interfaces: `utun` (most VPNs, WireGuard, IKEv2 on macOS), `ipsec`, `ppp`, `tun`, `tap`.
    private static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]

    /// Classifies a snapshot of the host's interfaces. Pure.
    ///
    /// An interface counts as a VPN when it is up, is named like a tunnel (a known prefix followed by digits), and
    /// - the source gave no addresses (`nil`: the OS listed it as a usable network path), or
    /// - it carries at least one address that is not link-local, loopback, unspecified, or multicast.
    ///
    /// The address test is what separates a VPN from the system's own tunnels: macOS keeps several `utun`
    /// interfaces up all the time (on this project's development Mac, `utun0`...`utun4` each hold only an `fe80::`
    /// link-local address). A tunnel that is up with *no* address at all is ambiguous (a VPN still connecting) and
    /// yields ``unknown`` unless another interface is definitely a VPN.
    ///
    /// The default route is deliberately not used: those same system tunnels hold scoped IPv6 default routes.
    ///
    /// - Limits: it cannot tell iCloud Private Relay or a developer tool's tunnel from a VPN if they present as a
    ///   routable `utun`; and "active" means a tunnel is up, not that guest traffic uses it (split tunneling).
    static func classify(_ interfaces: [InterfaceSnapshot]) -> VPNState {
        var sawUnaddressedTunnel = false
        for interface in interfaces where interface.isUp && isTunnelName(interface.name) {
            guard let addresses = interface.addresses else { return .active }
            if addresses.contains(where: isRoutable) { return .active }
            if addresses.isEmpty { sawUnaddressedTunnel = true }
        }
        return sawUnaddressedTunnel ? .unknown : .inactive
    }

    private static func isTunnelName(_ name: String) -> Bool {
        tunnelPrefixes.contains { prefix in
            let suffix = name.dropFirst(prefix.count)
            return name.hasPrefix(prefix) && !suffix.isEmpty && suffix.utf8.allSatisfy { (0x30...0x39).contains($0) }
        }
    }

    private static func isRoutable(_ address: IPAddress) -> Bool {
        switch ReservedRanges.kind(of: address) {
        case .linkLocal, .cloudMetadata, .loopback, .unspecified, .multicast: false
        default: true
        }
    }
}

extension VPNRequirement {
    /// Whether the guest may have network access given the host's VPN state. Pure.
    ///
    /// | requirement | `.active` | `.inactive` | `.unknown` |
    /// |---|---|---|---|
    /// | `.ignore`    | yes | yes | yes |
    /// | `.required`  | yes | no  | no  |
    /// | `.forbidden` | no  | yes | no  |
    ///
    /// **Unknown fails closed for both requirements.** Each is a promise about the network the guest's traffic
    /// takes; with no evidence the promise cannot be kept. The cost is bounded: `.unknown` only occurs before the
    /// first path update (milliseconds after ``VPNMonitor/start()``) or while a tunnel is half-configured.
    func allowsNetwork(vpn state: VPNState) -> Bool {
        switch (self, state) {
        case (.ignore, _), (.required, .active), (.forbidden, .inactive): true
        default: false
        }
    }
}

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
                guard let self else { return }
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
