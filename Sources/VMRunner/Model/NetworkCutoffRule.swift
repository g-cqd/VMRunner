import NetPolicy

/// What the kill switch reads from the Mac's network path. A plain value, so the rules can be tested without a network.
struct HostNetworkPath: Equatable, Sendable {
    /// Whether a VPN is up on the Mac, classified as the Mac VPN indicator does (`VPNState.classify`).
    var vpn = VPNState.unknown
    /// macOS marks the path as expensive: a phone's hotspot or a cellular link.
    var isExpensive = false
    /// Low Data Mode is on for the path.
    var isConstrained = false
    /// The path can carry traffic. Read by the host-information share.
    var isSatisfied = false
    /// The kind of link the path uses. Read by the host-information share.
    var interface = Interface.offline

    /// The kinds of link the host-information share names.
    enum Interface: String, Sendable { case wifi, ethernet, cellular, other, offline }
}

/// Why the kill switch has disconnected the guest's network card.
enum NetworkCutoffReason: Equatable, Sendable {
    /// The machine needs a VPN on the Mac, and none is up (or none is known to be up yet).
    case vpnRequired
    /// The machine must not use the Mac's VPN, and one is up (or the state is not known yet).
    case vpnForbidden
    /// The Mac's path is metered or in Low Data Mode, and the machine's switch says to cut then.
    case meteredPath

    /// The toolbar's tooltip.
    var text: String {
        switch self {
        case .vpnRequired: "Network cut: this machine needs a VPN on your Mac, and none is up."
        case .vpnForbidden: "Network cut: this machine must not use your Mac's VPN, and one is up or not ruled out."
        case .meteredPath: "Network cut: your Mac's connection is metered or in Low Data Mode."
        }
    }
}

extension VMConfig {
    /// Whether the kill switch has a rule to watch for this machine: a network card, and a VPN rule or the metered switch.
    var hasNetworkCutoff: Bool {
        networkMode.hasNetworkDevice && (networkPolicy.vpn != .ignore || networkCutsOnMeteredPath)
    }

    /// Why the network card must be disconnected on `path`, or nil when it may stay connected. The VPN rule comes first,
    /// and an unknown VPN state breaks both VPN rules (`VPNRequirement.allowsNetwork(vpn:)`).
    func networkCutoffReason(on path: HostNetworkPath) -> NetworkCutoffReason? {
        guard networkMode.hasNetworkDevice else { return nil }
        let vpnRule = networkPolicy.vpn
        if !vpnRule.allowsNetwork(vpn: path.vpn) { return vpnRule == .required ? .vpnRequired : .vpnForbidden }
        return networkCutsOnMeteredPath && (path.isExpensive || path.isConstrained) ? .meteredPath : nil
    }
}
