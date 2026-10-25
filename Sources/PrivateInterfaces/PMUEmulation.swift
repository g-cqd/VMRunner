package import Virtualization

/// Performance-monitoring emulation for a guest: the generic platform configuration's switch, which Windows on ARM is reported to
/// need and the framework does not document. Every use goes through the capability's checks (`CapabilityEntry.status`) and
/// fails closed: when a check fails nothing is called and the status says why.
package enum PMUEmulation {
    private static let className = "VZGenericPlatformConfiguration"

    /// Verified on macOS 27.0.1 (build 26A434): the setter's encoding is `v20@0:8B16`, the getter's `B16@0:8`. The builds are
    /// those of Darwin 26, which is macOS 27; a build outside them is off until it is probed and this range is widened.
    package static let entry = CapabilityEntry(
        id: .performanceMonitoringEmulation,
        builds: OSBuild(major: 26, letter: "A", count: 0)...OSBuild(major: 26, letter: "Z", count: 99_999),
        setter: MethodContract(
            className: className, selector: "_setPerformanceMonitoringUnitEmulationEnabled:", encoding: "v@:B"),
        getter: MethodContract(className: className, selector: "_performanceMonitoringUnitEmulationEnabled", encoding: "B@:"))

    /// Whether the switch can be used on this Mac with these settings. Nothing is called and no configuration is touched.
    package static func status(
        in context: PrivateCapabilityContext = .current(), registry: CapabilityRegistry = .standard
    ) -> PrivateCapabilityStatus {
        guard let registered = registry.entries[entry.id] else { return .unavailable(.notRegistered) }
        return registered.status(in: context)
    }

    /// Turns the emulation on for `configuration` and reads it back. Any failed check, or a value that was not kept, leaves the
    /// configuration as it was and returns the reason.
    package static func apply(
        to configuration: VZGenericPlatformConfiguration, in context: PrivateCapabilityContext = .current(),
        registry: CapabilityRegistry = .standard
    ) -> PrivateCapabilityStatus {
        guard let registered = registry.entries[entry.id] else { return .unavailable(.notRegistered) }
        return registered.apply(true, to: configuration, in: context)
    }
}
