import Foundation

extension HostFacts {
    /// What this Mac reports now. `network` is the latest path sample, which the caller keeps as the path changes.
    static func current(network: HostNetworkPath?) -> HostFacts {
        let info = ProcessInfo.processInfo
        return HostFacts(
            lowPowerMode: info.isLowPowerModeEnabled, thermal: Thermal(info.thermalState), network: network,
            timeZone: TimeZone.current.identifier)
    }
}

extension HostFacts.Thermal {
    /// The four levels macOS reports; a level added later reads as the most severe.
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }
}
