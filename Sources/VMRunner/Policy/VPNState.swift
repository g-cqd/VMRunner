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
    /// Addresses assigned to the interface, or `nil` when the source cannot say (the host's network path monitor gives none).
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
