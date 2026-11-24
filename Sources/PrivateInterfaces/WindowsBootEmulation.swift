import Foundation
package import Virtualization

/// ADR-0060: only for the verified framebuffer-assisted boot path. This does NOT clear the standalone PMU guard.
/// The caller must prepare the owned EFI bootstrap and RAM display before applying this pair, and discard the platform
/// on any failure. A selector probe alone is insufficient: the pair without the framebuffer also crashed on 26A434.
package enum WindowsBootEmulation {
    private static let build = OSBuild(major: 26, letter: "A", count: 434)

    package static let traps = CapabilityEntry(
        id: .fineGrainedTrapsEmulation, builds: build...build,
        setter: MethodContract(
            className: "VZGenericPlatformConfiguration", selector: "_setFineGrainedTrapsEmulationEnabled:", encoding: "v@:B"),
        getter: MethodContract(
            className: "VZGenericPlatformConfiguration", selector: "_fineGrainTrapsEmulationEnabled", encoding: "B@:"))

    /// A separately scoped PMU contract, allowed only as part of the framebuffer boot pair on the observed build.
    static let monitoring = CapabilityEntry(
        id: .performanceMonitoringEmulation, builds: build...build,
        setter: PMUEmulation.entry.setter, getter: PMUEmulation.entry.getter)

    package static func apply(
        to configuration: VZGenericPlatformConfiguration, in context: PrivateCapabilityContext = .current()
    ) -> PrivateCapabilityStatus {
        applyPair(to: configuration, in: context, first: monitoring, second: traps)
    }

    /// Both contracts are preflighted before either setter. On failure, restore the first switch's original value;
    /// regardless of restoration success, the caller must never use the failed configuration to create a machine.
    static func applyPair(
        to object: NSObject, in context: PrivateCapabilityContext, first: CapabilityEntry, second: CapabilityEntry
    ) -> PrivateCapabilityStatus {
        for entry in [first, second] {
            let status = entry.status(in: context)
            guard status.isAvailable else { return status }
        }
        var original = false
        let firstStatus = first.apply(true, to: object, in: context, originalValue: { original = $0 })
        guard firstStatus.isAvailable else { return firstStatus }
        let secondStatus = second.apply(true, to: object, in: context)
        if !secondStatus.isAvailable {
            _ = first.apply(original, to: object, in: context)
        }
        return secondStatus
    }
}
