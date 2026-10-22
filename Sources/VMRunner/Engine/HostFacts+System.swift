import Foundation
import IOKit.ps

extension HostFacts {
    /// What this Mac reports now. `network` is the latest path sample, which the caller keeps as the path changes.
    static func current(network: HostNetworkPath?) -> HostFacts {
        let info = ProcessInfo.processInfo
        let power = powerReading()
        return HostFacts(
            batteryPercent: power.percent, powerSource: power.source, lowPowerMode: info.isLowPowerModeEnabled,
            thermal: Thermal(info.thermalState), network: network, timeZone: TimeZone.current.identifier)
    }

    /// The internal battery's charge and what powers the Mac, from IOKit's list of power sources. A Mac without a battery
    /// reports no charge, and the source the system says it draws from.
    private static func powerReading() -> (percent: Int?, source: PowerSource) {
        // IOKit hands back unmanaged references: what a Copy function returns is owned, and `takeRetainedValue()` releases
        // it; what a Get function returns belongs to `blob`, which lives until this function returns.
        guard let blob = unsafe IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (nil, .unknown) }
        let providingType: CFString? = unsafe IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue()
        let providing = providingType.map { $0 as String }
        let source: PowerSource =
            providing == kIOPSACPowerValue ? .ac : providing == kIOPSBatteryPowerValue ? .battery : .unknown
        let list = unsafe IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for item in list {
            guard let description = unsafe IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            return (min(100, max(0, current * 100 / maximum)), source)
        }
        return (nil, source)
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
