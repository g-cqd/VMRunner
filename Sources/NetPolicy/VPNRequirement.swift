/// Whether the host's VPN state must (or must not) be present for a guest to have network access.
/// The decision itself is ``VPNRequirement/allowsNetwork(vpn:)``, below.
package enum VPNRequirement: String, Hashable, Sendable, Codable, CaseIterable {
    case ignore, required, forbidden
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
    /// first path update (milliseconds after the host monitor starts) or while a tunnel is half-configured.
    func allowsNetwork(vpn state: VPNState) -> Bool {
        switch (self, state) {
        case (.ignore, _), (.required, .active), (.forbidden, .inactive): true
        default: false
        }
    }
}
